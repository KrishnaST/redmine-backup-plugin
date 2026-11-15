# frozen_string_literal: true

require 'ipaddr'
require 'net/http'
require 'uri'

module RedmineBackup
  class ManagedIdentityService
    def initialize(environment: ENV, transport: nil)
      @environment, @transport = environment, transport || method(:get)
    end

    def acquire(target)
      endpoint = @environment['IDENTITY_ENDPOINT'].to_s
      app_service = !endpoint.empty?
      endpoint = 'http://169.254.169.254/metadata/identity/oauth2/token' unless app_service
      uri = URI(endpoint)
      address = IPAddr.new(uri.hostname) unless uri.hostname == 'localhost'
      local = uri.hostname == 'localhost' || address&.loopback? || IPAddr.new('169.254.0.0/16').include?(address)
      allowed = uri.scheme == 'http' && !uri.userinfo && !uri.fragment && local
      raise Error, 'UNTRUSTED_MANAGED_IDENTITY_ENDPOINT' unless allowed
      query = URI.decode_www_form(uri.query.to_s).to_h.merge('resource' => 'https://graph.microsoft.com',
                                                          'api-version' => app_service ? '2019-08-01' : '2018-02-01')
      query['client_id'] = target['client_id'] unless target['client_id'].to_s.empty?
      uri.query = URI.encode_www_form(query)
      headers = app_service ? { 'X-IDENTITY-HEADER' => @environment.fetch('IDENTITY_HEADER') } : { 'Metadata' => 'true' }
      @transport.call(uri, headers)
    rescue KeyError
      raise Error, 'MANAGED_IDENTITY_ENVIRONMENT_INCOMPLETE'
    rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
      raise Error, 'UNTRUSTED_MANAGED_IDENTITY_ENDPOINT'
    end

    private

    def get(uri, headers)
      # Metadata traffic must not inherit an HTTP proxy or follow redirects.
      client = Net::HTTP.new(uri.hostname, uri.port, nil)
      client.open_timeout = 3
      client.read_timeout = 5
      client.write_timeout = 5
      payload = +''
      client.start do |http|
        http.request(Net::HTTP::Get.new(uri, headers)) do |response|
          raise Error, 'MANAGED_IDENTITY_UNAVAILABLE' unless response.code.to_i == 200
          response.read_body do |chunk|
            raise Error, 'MANAGED_IDENTITY_RESPONSE_TOO_LARGE' if payload.bytesize + chunk.bytesize > 131_072
            payload << chunk
          end
        end
      end
      JSON.parse(payload)
    rescue JSON::ParserError
      raise Error, 'INVALID_MANAGED_IDENTITY_RESPONSE'
    end
  end
end
