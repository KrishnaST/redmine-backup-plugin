# frozen_string_literal: true

module RedmineBackup
  module CloudIdentity
    GOOGLE = 'google_drive'
    MICROSOFT = %w[onedrive onedrive_personal sharepoint].freeze
    PROVIDERS = [GOOGLE, *MICROSOFT].freeze
    APPLICATION_METHODS = %w[client_secret certificate workload_identity managed_identity].freeze
    TOKEN_FIELDS = %w[access_token refresh_token expires_at].freeze

    def self.google?(target)
      target['provider'] == GOOGLE
    end

    def self.method(target)
      target['auth_method'].to_s.empty? ? 'oauth2' : target['auth_method']
    end

    def self.tenant(target, application: false)
      value = target['tenant_id'].to_s
      value = target['provider'] == 'onedrive_personal' ? 'consumers' : 'organizations' if value.empty?
      valid = value.match?(/\A(?:organizations|common|consumers|[a-fA-F0-9-]{36}|[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,})\z/)
      raise Error, 'INVALID_TENANT' unless valid
      raise Error, 'PERSONAL_ACCOUNT_REQUIRES_CONSUMERS_TENANT' if target['provider'] == 'onedrive_personal' && value != 'consumers'
      raise Error, 'APPLICATION_AUTH_REQUIRES_SPECIFIC_TENANT' if application && %w[common consumers organizations].include?(value)
      value
    end

    def self.token_url(target, application: false)
      google?(target) ? 'https://oauth2.googleapis.com/token' : "https://login.microsoftonline.com/#{tenant(target, application: application)}/oauth2/v2.0/token"
    end

    def self.scope(target, application: false)
      return 'https://www.googleapis.com/auth/drive.file' if google?(target)
      return 'https://graph.microsoft.com/.default' if application
      permissions = target['provider'] == 'sharepoint' ? 'Files.ReadWrite.All' : 'Files.ReadWrite'
      "offline_access #{permissions}"
    end

    def self.validate!(target)
      raise Error, 'CLOUD_PROVIDER_REQUIRED' unless PROVIDERS.include?(target['provider'])
      method = self.method(target)
      raise Error, 'AUTHENTICATION_METHOD_NOT_SUPPORTED' unless ProviderSettingsService::METHODS.fetch(target['provider']).include?(method)
      if target['provider'] == 'onedrive_personal' && APPLICATION_METHODS.include?(method)
        raise Error, 'PERSONAL_ONEDRIVE_HAS_NO_APPLICATION_AUTH'
      end
      if google?(target) && method == 'device_code'
        raise Error, 'GOOGLE_DEVICE_FLOW_REQUIRES_LIMITED_INPUT_DEVICE'
      end
      if (target['provider'] == 'sharepoint' || APPLICATION_METHODS.include?(method)) &&
         target['drive_id'].to_s.empty? && target['site_id'].to_s.empty?
        raise Error, 'DRIVE_ID_OR_SHAREPOINT_SITE_ID_REQUIRED'
      end
      unless google?(target)
        tenant(target, application: APPLICATION_METHODS.include?(method) && method != 'managed_identity')
      end
      true
    end
  end
end
