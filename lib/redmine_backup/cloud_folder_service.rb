# frozen_string_literal: true

module RedmineBackup
  class CloudFolderService
    def initialize(target, http:, authorization:)
      @target, @http, @authorization = target, http, authorization
    end

    def prepare(name, reference = nil)
      BackupLayout.validate_folder!(name)
      return assert!(reference, name) if reference
      matches = children(@target.fetch('folder_id')).select { |item| item['name'] == name && folder?(item) }
      raise Error, 'DUPLICATE_BACKUP_FOLDERS' if matches.length > 1
      item = matches.first
      unless item
        body = if google?
                 { name: name, mimeType: 'application/vnd.google-apps.folder', parents: [@target.fetch('folder_id')] }
               else
                 { name: name, folder: {}, '@microsoft.graph.conflictBehavior' => 'fail' }
               end
        url = google? ? 'https://www.googleapis.com/drive/v3/files?supportsAllDrives=true&fields=id,name,mimeType,parents,driveId' : "#{graph}/items/#{segment(@target.fetch('folder_id'))}/children"
        response = @http.request('post', url, headers: headers.merge('Content-Type' => 'application/json'), body: JSON.generate(body))
        item = @http.json!(response)
      end
      reference = { 'id' => item.fetch('id'), 'name' => name }
      validate!(item, name)
      reference
    end

    def assert!(reference, name)
      BackupLayout.validate_folder!(name)
      validate!(metadata(reference.fetch('id')), name)
      raise Error, 'FOREIGN_BACKUP_FOLDER' unless reference.fetch('name') == name
      reference
    end

    def metadata(identifier)
      url = google? ? "https://www.googleapis.com/drive/v3/files/#{segment(identifier)}?fields=id,name,mimeType,parents,driveId&supportsAllDrives=true" : "#{graph}/items/#{segment(identifier)}?$select=id,name,folder,parentReference"
      @http.json!(@http.request('get', url, headers: headers))
    end

    def children(identifier)
      if google?
        raise Error, 'INVALID_DRIVE_FOLDER' unless identifier.to_s.match?(/\A[a-zA-Z0-9_-]+\z/)
        parameters = { q: "'#{identifier}' in parents and trashed = false", fields: 'files(id,name,mimeType,parents,driveId),nextPageToken',
                       pageSize: 1000, supportsAllDrives: true, includeItemsFromAllDrives: true }
        parameters.merge!(corpora: 'drive', driveId: @target['shared_drive_id']) unless @target['shared_drive_id'].to_s.empty?
        url = "https://www.googleapis.com/drive/v3/files?#{URI.encode_www_form(parameters)}"
      else
        url = "#{graph}/items/#{segment(identifier)}/children?$select=id,name,folder,parentReference&$top=200"
      end
      items = []
      while url
        data = @http.json!(@http.request('get', url, headers: headers))
        items.concat(data.fetch(google? ? 'files' : 'value'))
        url = data['@odata.nextLink']
        url = "https://www.googleapis.com/drive/v3/files?#{URI.encode_www_form(parameters.merge(pageToken: data['nextPageToken']))}" if google? && data['nextPageToken']
      end
      items
    end

    def folder?(item)
      google? ? item['mimeType'] == 'application/vnd.google-apps.folder' : item['folder'].is_a?(Hash)
    end

    def delete_empty(reference)
      assert!(reference, reference.fetch('name'))
      raise Error, 'BACKUP_FOLDER_NOT_EMPTY' unless children(reference.fetch('id')).empty?
      url = google? ? "https://www.googleapis.com/drive/v3/files/#{segment(reference.fetch('id'))}?supportsAllDrives=true" : "#{graph}/items/#{segment(reference.fetch('id'))}"
      response = @http.request('delete', url, headers: headers)
      raise Error, 'BACKUP_FOLDER_DELETE_FAILED' unless response.code.to_i == 204
    end

    private

    def validate!(item, name)
      parent = google? ? item.fetch('parents', []).include?(@target['folder_id']) : item.dig('parentReference', 'id') == @target['folder_id']
      parent &&= item.dig('parentReference', 'driveId') == @target['drive_id'] if !google? && !@target['drive_id'].to_s.empty?
      raise Error, 'FOREIGN_BACKUP_FOLDER' unless folder?(item) && item['name'] == name && parent
    end

    def segment(value)
      CloudLocationService.segment(value)
    end

    def google?
      CloudIdentity.google?(@target)
    end

    def graph
      CloudLocationService.graph_base(@target)
    end

    def headers
      @authorization.call
    end
  end
end
