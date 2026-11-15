# frozen_string_literal: true

module RedmineBackup
  class CloudLocationService
    def initialize(http: Providers::Http.new)
      @http = http
    end

    def self.graph_base(target)
      return "https://graph.microsoft.com/v1.0/drives/#{segment(target['drive_id'])}" unless target['drive_id'].to_s.empty?
      return "https://graph.microsoft.com/v1.0/sites/#{segment(target['site_id'])}/drive" unless target['site_id'].to_s.empty?
      if target['provider'] == 'sharepoint' || CloudIdentity::APPLICATION_METHODS.include?(CloudIdentity.method(target))
        raise Error, 'DRIVE_ID_OR_SHAREPOINT_SITE_ID_REQUIRED'
      end
      'https://graph.microsoft.com/v1.0/me/drive'
    end

    def self.segment(value)
      URI.encode_www_form_component(value.to_s).gsub('+', '%20')
    end

    def prepare(target)
      connected = target.dup
      return connected unless connected['folder_id'].to_s.empty?
      if CloudIdentity.google?(connected)
        service = %w[service_account domain_delegation].include?(CloudIdentity.method(connected))
        if service && connected['impersonated_user'].to_s.empty? && connected['shared_drive_id'].to_s.empty?
          raise Error, 'SERVICE_ACCOUNT_REQUIRES_SHARED_DRIVE_OR_EXISTING_FOLDER'
        end
        url = 'https://www.googleapis.com/drive/v3/files?supportsAllDrives=true&fields=id'
        data = { name: 'Redmine Backups', mimeType: 'application/vnd.google-apps.folder' }
        data[:parents] = [connected['shared_drive_id']] unless connected['shared_drive_id'].to_s.empty?
      else
        url = "#{self.class.graph_base(connected)}/root/children"
        data = { name: 'Redmine Backups', folder: {}, '@microsoft.graph.conflictBehavior' => 'rename' }
      end
      response = @http.request('post', url, headers: { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{connected.fetch('access_token')}" }, body: JSON.generate(data))
      connected['folder_id'] = @http.json!(response).fetch('id')
      connected
    end
  end
end
