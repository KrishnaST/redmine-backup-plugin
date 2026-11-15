# frozen_string_literal: true

require 'base64'
require 'openssl'

module RedmineBackup
  class JwtAssertionService
    def self.google(target, now: Time.now.to_i)
      credentials = JSON.parse(target.fetch('service_account_json'))
      raise Error, 'GOOGLE_SERVICE_ACCOUNT_REQUIRED' unless credentials['type'] == 'service_account'
      claims = { iss: credentials.fetch('client_email'), scope: CloudIdentity.scope(target),
                 aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600 }
      if CloudIdentity.method(target) == 'domain_delegation'
        subject = target['impersonated_user'].to_s
        raise Error, 'WORKSPACE_USER_EMAIL_REQUIRED' unless subject.match?(/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/)
        claims[:sub] = subject
      end
      key = OpenSSL::PKey.read(credentials.fetch('private_key'))
      sign({ alg: 'RS256', typ: 'JWT', kid: credentials['private_key_id'] }.compact, claims, key)
    rescue JSON::ParserError, KeyError, TypeError, OpenSSL::PKey::PKeyError
      raise Error, 'INVALID_SERVICE_ACCOUNT_CREDENTIALS'
    end

    def self.microsoft(target, endpoint:, now: Time.now.to_i)
      certificate = OpenSSL::X509::Certificate.new(target.fetch('certificate_pem'))
      key = OpenSSL::PKey.read(target.fetch('private_key'), target['key_passphrase'])
      raise Error, 'CERTIFICATE_KEY_MISMATCH' unless certificate.check_private_key(key)
      raise Error, 'CERTIFICATE_EXPIRED_OR_NOT_YET_VALID' unless certificate.not_before.to_i <= now && certificate.not_after.to_i > now
      header = { alg: 'PS256', typ: 'JWT', 'x5t#S256' => encode(Digest::SHA256.digest(certificate.to_der)) }
      claims = { aud: endpoint, iss: target.fetch('client_id'), sub: target.fetch('client_id'),
                 jti: SecureRandom.uuid, nbf: now - 30, iat: now, exp: now + 300 }
      sign(header, claims, key, pss: true)
    rescue KeyError, OpenSSL::X509::CertificateError, OpenSSL::PKey::PKeyError
      raise Error, 'INVALID_CERTIFICATE_CREDENTIALS'
    end

    def self.sign(header, claims, key, pss: false)
      raise Error, 'RSA_PRIVATE_KEY_REQUIRED' unless key.is_a?(OpenSSL::PKey::RSA) && key.private? && key.n.num_bits >= 2048
      message = [header, claims].map { |part| encode(JSON.generate(part)) }.join('.')
      signature = pss ? key.sign_pss('SHA256', message, salt_length: :digest, mgf1_hash: 'SHA256') : key.sign('SHA256', message)
      "#{message}.#{encode(signature)}"
    end

    def self.encode(value)
      Base64.urlsafe_encode64(value, padding: false)
    end
  end
end
