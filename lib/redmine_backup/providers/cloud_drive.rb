# frozen_string_literal: true

module RedmineBackup
  module Providers
    class Http
      GOOGLE_HOSTS = %w[www.googleapis.com oauth2.googleapis.com accounts.google.com].freeze

      def self.allowed?(url)
        uri = URI(url)
        return false unless uri.is_a?(URI::HTTPS) && uri.port == 443 && !uri.userinfo
        host = uri.host.to_s.downcase
        GOOGLE_HOSTS.include?(host) || host == 'graph.microsoft.com' || host == 'login.microsoftonline.com' ||
          host.end_with?('.up.1drv.com', '.up.1drv.ms', '.sharepoint.com', '.onedrive.com', '.storage.live.com', '.1drv.com', '.googleusercontent.com')
      end

      def request(method, url, headers: {}, body: nil, &block)
        raise Error, 'UNTRUSTED_PROVIDER_URL' unless self.class.allowed?(url)
        uri = URI(url)
        attempts = 0
        loop do
          request = Net::HTTP.const_get(method.capitalize).new(uri, headers)
          request.body = body if body
          response = nil
          Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 90, write_timeout: 90) do |http|
            http.max_retries = 0
            http.request(request) do |incoming|
              response = incoming
              if block && incoming.code.to_i.between?(200, 299)
                incoming.read_body(&block)
              else
                data = +''
                incoming.read_body do |chunk|
                  raise Error, 'PROVIDER_RESPONSE_TOO_LARGE' if data.bytesize + chunk.bytesize > 8 * 1024 * 1024
                  data << chunk
                end
                incoming.instance_variable_set(:@body, data)
              end
            end
          end
          return response unless [429, 500, 502, 503, 504].include?(response.code.to_i) && attempts < 2
          attempts += 1
          sleep([response['Retry-After'].to_i.nonzero? || (2**attempts), 30].min)
        end
      end

      def json!(response, statuses: [200, 201, 202])
        raise Error, "PROVIDER_HTTP_#{response.code}" unless statuses.include?(response.code.to_i)
        response.body.to_s.empty? ? {} : JSON.parse(response.body)
      rescue JSON::ParserError
        raise Error, 'INVALID_PROVIDER_RESPONSE'
      end
    end

    class CloudDrive < Base
      def initialize(target, checkpoint: nil)
        super
        @http = Http.new
      end

      def health!
        super
        raise Error, 'DESTINATION_FOLDER_REQUIRED' if target['folder_id'].to_s.empty?
        url = google? ? 'https://www.googleapis.com/drive/v3/about?fields=user' : graph_base
        @http.json!(@http.request('get', url, headers: authorization))
        check_folder!
        true
      end

      def prepare_run(name, reference = nil)
        @run_folder = folders.prepare(name, reference)
      end

      def assert_folder!(reference, name)
        folders.assert!(reference, name)
      end

      def delete_folder(reference)
        folders.delete_empty(reference)
      end

      def upload(path, key, session = {})
        protect!
        upload_location(key)
        state = session.dup
        size = File.size(path)
        offset = 0
        if state['url']
          probe = if google?
                    @http.request('put', state['url'], headers: authorization.merge('Content-Range' => "bytes */#{size}", 'Content-Length' => '0'))
                  else
                    @http.request('get', state['url'])
                  end
          if google? && [200, 201].include?(probe.code.to_i)
            return file_reference(@http.json!(probe).fetch('id'), key)
          elsif probe.code.to_i == 308 || (!google? && probe.code.to_i == 200)
            offset = next_offset(probe)
          elsif [404, 410].include?(probe.code.to_i)
            state = {}
          else
            raise Error, 'UPLOAD_SESSION_PROBE_FAILED'
          end
        end
        unless state['url']
          state['url'] = create_session(key, size)
          @checkpoint.call(key, state)
        end
        File.open(path, 'rb') do |file|
          file.seek(offset)
          until file.eof?
            payload = file.read(5 * 1024 * 1024) # multiple of both 256 KiB and 320 KiB
            headers = { 'Content-Type' => 'application/octet-stream', 'Content-Length' => payload.bytesize.to_s,
                        'Content-Range' => "bytes #{offset}-#{offset + payload.bytesize - 1}/#{size}" }
            headers.merge!(authorization) if google?
            response = @http.request('put', state['url'], headers: headers, body: payload)
            if [200, 201].include?(response.code.to_i)
              @checkpoint.call(key, {})
              return file_reference(@http.json!(response).fetch('id'), key)
            end
            expected = offset + payload.bytesize
            offset = next_offset(response)
            raise Error, 'UPLOAD_OFFSET_MISMATCH' unless offset == expected
            @checkpoint.call(key, state.merge('offset' => offset))
          end
        end
        raise Error, 'UPLOAD_NOT_COMPLETED'
      end

      def stream(reference, redirects = 0, &block)
        id = URI.encode_www_form_component(reference.fetch('id'))
        url = google? ? "https://www.googleapis.com/drive/v3/files/#{id}?alt=media&supportsAllDrives=true" : "#{graph_base}/items/#{id}/content"
        response = @http.request('get', url, headers: authorization, &block)
        if [301, 302, 303, 307, 308].include?(response.code.to_i)
          raise Error, 'TOO_MANY_REDIRECTS' if redirects >= 1
          # Preauthenticated download links must never receive the Graph bearer token.
          redirected = @http.request('get', response.fetch('location'), &block)
          raise Error, 'PROVIDER_DOWNLOAD_FAILED' unless redirected.code.to_i == 200
        elsif response.code.to_i != 200
          raise Error, 'PROVIDER_DOWNLOAD_FAILED'
        end
      end

      def list_markers(prefix)
        result = []
        folders.children(target.fetch('folder_id')).each do |item|
          next unless item['name'].start_with?(prefix)
          if !folders.folder?(item) && item['name'].end_with?('-complete.json')
            result << { 'id' => item.fetch('id') }
          elsif folders.folder?(item) && item['name'].delete_prefix(prefix).match?(/\A\d{8}T\d{6}Z-[a-f0-9]{12}\z/)
            folders.children(item.fetch('id')).each do |child|
              next unless child['name'] == 'complete.json' && !folders.folder?(child)
              result << { 'id' => child.fetch('id'), 'folder_id' => item.fetch('id'), 'folder_name' => item.fetch('name') }
            end
          end
        end
        result
      end

      def delete(reference)
        id = URI.encode_www_form_component(reference.fetch('id'))
        url = google? ? "https://www.googleapis.com/drive/v3/files/#{id}?supportsAllDrives=true" : "#{graph_base}/items/#{id}"
        response = @http.request('delete', url, headers: authorization)
        raise Error, 'PROVIDER_DELETE_FAILED' unless [204, 404].include?(response.code.to_i)
      end

      def assert_reference!(reference, namespace)
        item = folders.metadata(reference.fetch('id'))
        parent = reference['folder_id'] || target['folder_id']
        parent_ok = google? ? item.fetch('parents', []).include?(parent) : item.dig('parentReference', 'id') == parent
        parent_ok &&= item.dig('parentReference', 'driveId') == target['drive_id'] if !google? && !target['drive_id'].to_s.empty?
        if reference['folder_id']
          name = namespace.delete_suffix('-')
          folders.assert!({ 'id' => reference['folder_id'], 'name' => reference.fetch('folder_name') }, name)
          owned = BackupLayout::COMPONENTS.include?(item['name'])
        else
          owned = BackupLayout.owned_key?(item.fetch('name'), namespace)
        end
        raise Error, 'FOREIGN_OBJECT_REFERENCE' unless owned && parent_ok && !folders.folder?(item)
      end

      private

      def folders
        @folders ||= CloudFolderService.new(target, http: @http, authorization: -> { authorization })
      end

      def file_reference(identifier, key)
        reference = { 'id' => identifier }
        reference.merge!('folder_id' => @run_folder.fetch('id'), 'folder_name' => @run_folder.fetch('name')) if key.include?('/')
        reference
      end

      def check_folder!
        folder = CloudLocationService.segment(target['folder_id'])
        url = google? ? "https://www.googleapis.com/drive/v3/files/#{folder}?fields=id,mimeType,driveId&supportsAllDrives=true" : "#{graph_base}/items/#{folder}?$select=id,folder"
        item = @http.json!(@http.request('get', url, headers: authorization))
        valid = google? ? item['mimeType'] == 'application/vnd.google-apps.folder' : item['folder'].is_a?(Hash)
        raise Error, 'DESTINATION_MUST_BE_ACCESSIBLE_FOLDER' unless valid
        if google? && CloudIdentity.method(target) == 'service_account' && item['driveId'].to_s.empty?
          raise Error, 'SERVICE_ACCOUNT_REQUIRES_SHARED_DRIVE_FOLDER'
        end
        if google? && !target['shared_drive_id'].to_s.empty? && item['driveId'] != target['shared_drive_id']
          raise Error, 'FOLDER_NOT_IN_SELECTED_SHARED_DRIVE'
        end
      end

      def google?
        target['provider'] == 'google_drive'
      end

      def graph_base
        CloudLocationService.graph_base(target)
      end

      def authorization
        refresh! if target['expires_at'].to_i < Time.now.to_i + 120
        { 'Authorization' => "Bearer #{target.fetch('access_token')}" }
      end

      def refresh!
        tokens = CloudTokenService.new(http: @http).acquire(target, force: true)
        target.merge!(tokens)
        @checkpoint.call('oauth_tokens', tokens)
      end

      def create_session(key, size)
        parent, name = upload_location(key)
        if google?
          metadata = JSON.generate(name: name, parents: [parent])
          response = @http.request('post', 'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true',
                                   headers: authorization.merge('Content-Type' => 'application/json', 'X-Upload-Content-Length' => size.to_s), body: metadata)
          raise Error, 'UPLOAD_SESSION_FAILED' unless response.code.to_i == 200
          response.fetch('location')
        else
          folder = URI.encode_www_form_component(parent)
          encoded_name = URI.encode_www_form_component(name)
          response = @http.request('post', "#{graph_base}/items/#{folder}:/#{encoded_name}:/createUploadSession",
                                   headers: authorization.merge('Content-Type' => 'application/json'),
                                   body: JSON.generate(item: { '@microsoft.graph.conflictBehavior' => 'replace', name: name }))
          @http.json!(response).fetch('uploadUrl')
        end
      end

      def upload_location(key)
        if key.include?('/')
          folder, name = key.split('/', 2)
          raise Error, 'BACKUP_FOLDER_NOT_PREPARED' unless @run_folder && @run_folder['name'] == folder && BackupLayout::COMPONENTS.include?(name)
          [@run_folder.fetch('id'), name]
        else
          [target.fetch('folder_id'), key]
        end
      end

      def next_offset(response)
        if google?
          raise Error, 'UPLOAD_CHUNK_FAILED' unless response.code.to_i == 308
          response['Range'].to_s.empty? ? 0 : Integer(response['Range'].split('-').last) + 1
        else
          @http.json!(response).fetch('nextExpectedRanges').first.split('-').first.to_i
        end
      end
    end
  end
end
