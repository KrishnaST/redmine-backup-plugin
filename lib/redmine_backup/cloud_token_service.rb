# frozen_string_literal: true

module RedmineBackup
  class CloudTokenService
    ASSERTION_TYPE = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'

    def initialize(http: Providers::Http.new, managed_identity: ManagedIdentityService.new)
      @http, @managed_identity = http, managed_identity
    end

    def acquire(target, force: false)
      CloudIdentity.validate!(target)
      raise Error, 'INVALID_ACCESS_TOKEN' if target['access_token'].to_s.match?(/[\r\n]/)
      return target.slice(*CloudIdentity::TOKEN_FIELDS) if !force && target['access_token'].to_s != '' && target['expires_at'].to_i > Time.now.to_i + 120
      method = CloudIdentity.method(target)
      return normalize(@managed_identity.acquire(target)) if method == 'managed_identity'
      if %w[oauth2 device_code imported_token].include?(method)
        raise Error, 'RECONNECT_STORAGE_ACCOUNT' if target['refresh_token'].to_s.empty?
        form = { grant_type: 'refresh_token', refresh_token: target.fetch('refresh_token') }
      elsif %w[service_account domain_delegation].include?(method)
        form = { grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: JwtAssertionService.google(target) }
      elsif CloudIdentity::APPLICATION_METHODS.include?(method)
        form = { grant_type: 'client_credentials', scope: CloudIdentity.scope(target, application: true) }
      elsif method == 'on_behalf_of'
        form = { grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', requested_token_use: 'on_behalf_of',
                 assertion: PrivateCredentialFileService.read(target['user_assertion_path']), scope: CloudIdentity.scope(target) }
      elsif method == 'password_grant'
        raise Error, 'USERNAME_AND_PASSWORD_REQUIRED' if target['username'].to_s.empty? || target['password'].to_s.empty?
        form = { grant_type: 'password', username: target['username'], password: target['password'], scope: CloudIdentity.scope(target) }
      else
        raise Error, 'AUTHENTICATION_METHOD_NOT_SUPPORTED'
      end
      post(target, form)
    end

    def post(target, form)
      CloudIdentity.validate!(target)
      application = CloudIdentity::APPLICATION_METHODS.include?(CloudIdentity.method(target))
      endpoint = CloudIdentity.token_url(target, application: application)
      unless %w[service_account domain_delegation].include?(CloudIdentity.method(target))
        raise Error, 'CLIENT_ID_REQUIRED' if target['client_id'].to_s.empty?
        form = form.merge(client_id: target['client_id'])
        method = CloudIdentity.method(target)
        if method == 'certificate'
          form.merge!(client_assertion_type: ASSERTION_TYPE, client_assertion: JwtAssertionService.microsoft(target, endpoint: endpoint))
        elsif method == 'workload_identity'
          form.merge!(client_assertion_type: ASSERTION_TYPE, client_assertion: PrivateCredentialFileService.read(target['federated_token_path']))
        elsif method != 'device_code' && !target['client_secret'].to_s.empty?
          form[:client_secret] = target['client_secret']
        elsif %w[client_secret on_behalf_of].include?(method)
          raise Error, 'CLIENT_SECRET_REQUIRED'
        end
      end
      response = @http.request('post', endpoint, headers: { 'Content-Type' => 'application/x-www-form-urlencoded' }, body: URI.encode_www_form(form))
      unless response.code.to_i == 200
        error = JSON.parse(response.body).fetch('error', '') rescue ''
        code = { 'invalid_client' => 'OAUTH_CLIENT_CREDENTIALS_REJECTED',
                 'invalid_grant' => 'OAUTH_GRANT_REJECTED_RECONNECT_OR_CHECK_POLICY',
                 'invalid_scope' => 'OAUTH_PERMISSION_OR_SCOPE_REJECTED',
                 'interaction_required' => 'OAUTH_INTERACTIVE_SIGN_IN_REQUIRED',
                 'consent_required' => 'OAUTH_ACCOUNT_OR_ADMIN_CONSENT_REQUIRED' }.fetch(error, 'OAUTH_TOKEN_REQUEST_FAILED')
        raise Error, code
      end
      normalize(@http.json!(response), previous: target)
    end

    def normalize(data, previous: {})
      token = data['access_token'].to_s
      raise Error, 'ACCESS_TOKEN_MISSING' if token.empty? || token.match?(/[\r\n]/)
      expiry = if data['expires_in']
                 Time.now.to_i + Integer(data['expires_in'])
               elsif data['expires_on'].to_s.match?(/\A\d+\z/)
                 Integer(data['expires_on'])
               else
                 Time.parse(data.fetch('expires_on')).to_i
               end
      raise Error, 'ACCESS_TOKEN_ALREADY_EXPIRED' unless expiry > Time.now.to_i
      result = { 'access_token' => token, 'expires_at' => expiry }
      refresh = data.fetch('refresh_token', previous['refresh_token'])
      result['refresh_token'] = refresh unless refresh.to_s.empty?
      result
    rescue KeyError, ArgumentError, TypeError
      raise Error, 'INVALID_TOKEN_RESPONSE'
    end
  end
end
