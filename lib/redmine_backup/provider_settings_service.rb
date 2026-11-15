# frozen_string_literal: true

module RedmineBackup
  class ProviderSettingsService
    METHODS = {
      'google_drive' => %w[oauth2 service_account domain_delegation imported_token],
      'onedrive_personal' => %w[oauth2 device_code imported_token],
      'onedrive' => %w[oauth2 device_code client_secret certificate workload_identity managed_identity on_behalf_of password_grant imported_token],
      'sharepoint' => %w[oauth2 device_code client_secret certificate workload_identity managed_identity on_behalf_of password_grant imported_token],
      'sftp' => %w[ssh_key password], 's3' => %w[sdk_chain access_key session_token]
    }.freeze
    COMMON = %w[provider auth_method enabled mode remote_keep_dates].freeze
    FIELDS = {
      'google_drive' => %w[account_type client_id client_secret folder_id shared_drive_id service_account_json impersonated_user access_token refresh_token expires_at],
      'onedrive' => %w[client_id client_secret tenant_id folder_id drive_id site_id certificate_pem private_key key_passphrase federated_token_path user_assertion_path username password access_token refresh_token expires_at],
      'onedrive_personal' => %w[client_id client_secret folder_id access_token refresh_token expires_at],
      'sharepoint' => %w[client_id client_secret tenant_id folder_id drive_id site_id certificate_pem private_key key_passphrase federated_token_path user_assertion_path username password access_token refresh_token expires_at],
      'sftp' => %w[host port username directory known_hosts private_key_path key_passphrase password],
      's3' => %w[endpoint region bucket prefix access_key_id secret_access_key session_token versioning retention_lock lock_days]
    }.freeze
    SECRETS = %w[client_secret access_token refresh_token expires_at password key_passphrase secret_access_key session_token service_account_json certificate_pem private_key].freeze
    IDENTITY_FIELDS = %w[provider auth_method client_id tenant_id impersonated_user service_account_json certificate_pem private_key client_secret federated_token_path user_assertion_path username password].freeze
    LOCATION_IDENTITY_FIELDS = %w[provider auth_method client_id tenant_id impersonated_user service_account_json username].freeze
    CONTAINER_FIELDS = %w[shared_drive_id drive_id site_id].freeze
    PROVIDER_REFERENCES = %w[client_id tenant_id folder_id shared_drive_id drive_id site_id].freeze
    CLOUD_CREDENTIALS = %w[client_secret service_account_json certificate_pem private_key key_passphrase password access_token refresh_token expires_at].freeze
    METHOD_CREDENTIALS = {
      'oauth2' => %w[client_secret access_token refresh_token expires_at],
      'device_code' => %w[access_token refresh_token expires_at],
      'service_account' => %w[service_account_json access_token expires_at],
      'domain_delegation' => %w[service_account_json access_token expires_at],
      'client_secret' => %w[client_secret access_token expires_at],
      'certificate' => %w[certificate_pem private_key key_passphrase access_token expires_at],
      'workload_identity' => %w[access_token expires_at], 'managed_identity' => %w[access_token expires_at],
      'on_behalf_of' => %w[client_secret access_token refresh_token expires_at],
      'password_grant' => %w[client_secret password access_token refresh_token expires_at],
      'imported_token' => %w[client_secret access_token refresh_token expires_at]
    }.freeze

    def self.authentication(target)
      return target['auth_method'] unless target['auth_method'].to_s.empty?
      case target['provider']
      when 'google_drive', 'onedrive', 'onedrive_personal', 'sharepoint' then 'oauth2'
      when 'sftp' then target['private_key_path'].to_s.empty? && !target['password'].to_s.empty? ? 'password' : 'ssh_key'
      when 's3'
        return 'session_token' unless target['session_token'].to_s.empty?
        target['access_key_id'].to_s.empty? ? 'sdk_chain' : 'access_key'
      end
    end

    def self.merge(original, input)
      provider = input.fetch('provider', original['provider'])
      allowed = COMMON + FIELDS.fetch(provider, [])
      provider_changed = original['provider'] != provider
      result = original.slice(*(provider_changed ? COMMON : allowed))
      allowed.each do |key|
        next unless input.key?(key)
        next if SECRETS.include?(key) && input[key].to_s.empty?
        next if provider_changed && PROVIDER_REFERENCES.include?(key) && input[key].to_s.strip == original[key].to_s
        result[key] = SECRETS.include?(key) ? input[key].to_s : input[key].to_s.strip
      end
      %w[enabled versioning retention_lock].each { |key| result[key] = input[key] == '1' || input[key] == true }
      result['provider'] = provider
      if original['provider'] != provider && !METHODS.fetch(provider, []).include?(input['auth_method'])
        result.delete('auth_method')
      end
      result['auth_method'] = authentication(result)
      if CloudIdentity::PROVIDERS.include?(provider)
        unused = CLOUD_CREDENTIALS - METHOD_CREDENTIALS.fetch(result['auth_method'], [])
        unused.each { |key| result.delete(key) }
      end
      original_identity = original.merge('auth_method' => authentication(original))
      application_changed = %w[provider client_id tenant_id].any? { |key| result[key].to_s != original_identity[key].to_s }
      if application_changed && CloudIdentity::PROVIDERS.include?(provider)
        %w[client_secret certificate_pem private_key key_passphrase].each { |key| result.delete(key) if input[key].to_s.empty? }
      end
      location_changed = (LOCATION_IDENTITY_FIELDS + CONTAINER_FIELDS).any? { |key| result[key].to_s != original_identity[key].to_s }
      if location_changed && result['folder_id'].to_s == original['folder_id'].to_s
        result.delete('folder_id')
      end
      if !provider_changed && !location_changed && result['folder_id'] == original['folder_id'] && original['folder_origin'] == 'application'
        result['folder_origin'] = 'application'
      end
      identity_changed = IDENTITY_FIELDS.any? { |key| result[key].to_s != original_identity[key].to_s }
      if identity_changed
        %w[access_token refresh_token expires_at].each do |key|
          result.delete(key) unless result['auth_method'] == 'imported_token' && !input[key].to_s.empty?
        end
      end
      result
    end
  end
end
