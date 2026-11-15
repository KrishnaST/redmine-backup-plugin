# frozen_string_literal: true

module RedmineBackup
  class ProviderSettingsService
    METHODS = {
      'google_drive' => %w[oauth2], 'onedrive' => %w[oauth2],
      'sftp' => %w[ssh_key password], 's3' => %w[sdk_chain access_key session_token]
    }.freeze
    COMMON = %w[provider auth_method enabled mode remote_keep_dates].freeze
    FIELDS = {
      'google_drive' => %w[client_id client_secret folder_id access_token refresh_token expires_at],
      'onedrive' => %w[client_id client_secret tenant_id folder_id access_token refresh_token expires_at],
      'sftp' => %w[host port username directory known_hosts private_key_path key_passphrase password],
      's3' => %w[endpoint region bucket prefix access_key_id secret_access_key session_token versioning retention_lock lock_days]
    }.freeze
    SECRETS = %w[client_secret access_token refresh_token password key_passphrase secret_access_key session_token].freeze

    def self.authentication(target)
      return target['auth_method'] unless target['auth_method'].to_s.empty?
      case target['provider']
      when 'google_drive', 'onedrive' then 'oauth2'
      when 'sftp' then target['private_key_path'].to_s.empty? && !target['password'].to_s.empty? ? 'password' : 'ssh_key'
      when 's3'
        return 'session_token' unless target['session_token'].to_s.empty?
        target['access_key_id'].to_s.empty? ? 'sdk_chain' : 'access_key'
      end
    end

    def self.merge(original, input)
      provider = input.fetch('provider', original['provider'])
      allowed = COMMON + FIELDS.fetch(provider, [])
      result = original.slice(*allowed)
      allowed.each do |key|
        next unless input.key?(key)
        next if SECRETS.include?(key) && input[key].to_s.empty?
        result[key] = SECRETS.include?(key) ? input[key].to_s : input[key].to_s.strip
      end
      %w[enabled versioning retention_lock].each { |key| result[key] = input[key] == '1' || input[key] == true }
      result['provider'] = provider
      if original['provider'] != provider && !METHODS.fetch(provider, []).include?(input['auth_method'])
        result.delete('auth_method')
      end
      result['auth_method'] = authentication(result)
      if %w[provider client_id tenant_id].any? { |key| result[key].to_s != original[key].to_s }
        %w[access_token refresh_token expires_at].each { |key| result.delete(key) }
      end
      result
    end
  end
end
