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

      def upload(path, key, session = {})
        protect!
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
            return { 'id' => @http.json!(probe).fetch('id') }
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
              return { 'id' => @http.json!(response).fetch('id') }
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
        if google?
          folder = target.fetch('folder_id')
          raise Error, 'INVALID_DRIVE_FOLDER' unless folder.match?(/\A[a-zA-Z0-9_-]+\z/)
          query = "'#{folder}' in parents and trashed = false and name contains '#{prefix}'"
          parameters = { q: query, fields: 'files(id,name),nextPageToken', pageSize: 1000, supportsAllDrives: true, includeItemsFromAllDrives: true }
          parameters.merge!(corpora: 'drive', driveId: target['shared_drive_id']) unless target['shared_drive_id'].to_s.empty?
          url = "https://www.googleapis.com/drive/v3/files?#{URI.encode_www_form(parameters)}"
        else
          folder = URI.encode_www_form_component(target.fetch('folder_id'))
          url = "#{graph_base}/items/#{folder}/children?$select=id,name&$top=200"
        end
        result = []
        while url
          response = @http.json!(@http.request('get', url, headers: authorization))
          items = response.fetch(google? ? 'files' : 'value')
          result.concat(items.filter_map { |item| { 'id' => item['id'] } if item['name'].start_with?(prefix) && item['name'].end_with?('-complete.json') })
          url = response['@odata.nextLink']
          if google? && response['nextPageToken']
            url = "https://www.googleapis.com/drive/v3/files?#{URI.encode_www_form(parameters.merge(pageToken: response['nextPageToken']))}"
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
        id = URI.encode_www_form_component(reference.fetch('id'))
        url = google? ? "https://www.googleapis.com/drive/v3/files/#{id}?fields=name,parents&supportsAllDrives=true" : "#{graph_base}/items/#{id}?$select=name,parentReference"
        item = @http.json!(@http.request('get', url, headers: authorization))
        parent_ok = google? ? item.fetch('parents', []).include?(target['folder_id']) : item.dig('parentReference', 'id') == target['folder_id']
        parent_ok &&= item.dig('parentReference', 'driveId') == target['drive_id'] if !google? && !target['drive_id'].to_s.empty?
        raise Error, 'FOREIGN_OBJECT_REFERENCE' unless item.fetch('name').start_with?(namespace) && parent_ok
      end

      private

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
        if google?
          metadata = JSON.generate(name: key, parents: [target.fetch('folder_id')])
          response = @http.request('post', 'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true',
                                   headers: authorization.merge('Content-Type' => 'application/json', 'X-Upload-Content-Length' => size.to_s), body: metadata)
          raise Error, 'UPLOAD_SESSION_FAILED' unless response.code.to_i == 200
          response.fetch('location')
        else
          folder = URI.encode_www_form_component(target.fetch('folder_id'))
          name = URI.encode_www_form_component(key)
          response = @http.request('post', "#{graph_base}/items/#{folder}:/#{name}:/createUploadSession",
                                   headers: authorization.merge('Content-Type' => 'application/json'),
                                   body: JSON.generate(item: { '@microsoft.graph.conflictBehavior' => 'replace', name: key }))
          @http.json!(response).fetch('uploadUrl')
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
