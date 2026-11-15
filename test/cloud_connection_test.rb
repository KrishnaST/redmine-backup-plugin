# frozen_string_literal: true

require_relative 'test_helper'

class CloudConnectionTest < BackupTest
  class Runtime
    attr_reader :config, :saved
    attr_accessor :recovery

    def initialize(configuration)
      @config = configuration
    end

    def recovery?
      @recovery == true
    end

    def save!(values, actor:)
      @saved = { 'values' => values, 'actor' => actor }
    end
  end

  class Provider
    attr_accessor :valid, :closed

    def health!
      raise RedmineBackup::Error, 'DESTINATION_MUST_BE_ACCESSIBLE_FOLDER' unless valid
    end

    def close
      @closed = true
    end
  end

  def test_noninteractive_connect_checks_access_before_saving_and_closes_provider
    runtime = Runtime.new(config('primary' => { 'provider' => 'google_drive', 'auth_method' => 'service_account' }))
    oauth = Object.new
    oauth.define_singleton_method(:connect) { |target| target.merge('folder_id' => 'verified-folder', 'access_token' => 'private') }
    provider = Provider.new
    provider.valid = true
    service = RedmineBackup::CloudConnectionService.new(runtime, actor: '7', oauth: oauth, providers: ->(_target) { provider })
    service.connect('primary')
    assert_equal 'verified-folder', runtime.saved['values']['primary']['folder_id']
    assert_equal '7', runtime.saved['actor']
    assert provider.closed
  end

  def test_inaccessible_destination_does_not_publish_connected_configuration
    runtime = Runtime.new(config('primary' => { 'provider' => 'google_drive', 'auth_method' => 'service_account' }))
    oauth = Object.new
    oauth.define_singleton_method(:connect) { |target| target }
    provider = Provider.new
    service = RedmineBackup::CloudConnectionService.new(runtime, actor: '7', oauth: oauth, providers: ->(_target) { provider })
    assert_raises(RedmineBackup::Error) { service.connect('primary') }
    assert_nil runtime.saved
    assert provider.closed
  end

  def test_recovery_mode_blocks_browser_completion_and_application_connect
    runtime = Runtime.new(config)
    runtime.recovery = true
    service = RedmineBackup::CloudConnectionService.new(runtime, actor: '7', oauth: Object.new)
    assert_raises(RedmineBackup::Error) { service.connect('primary') }
    assert_raises(RedmineBackup::Error) { service.complete_browser('primary', code: 'code') }
    assert_nil runtime.saved
  end

  def test_browser_completion_delegates_code_exchange_and_saves_only_that_slot
    runtime = Runtime.new(config)
    oauth = Object.new
    oauth.define_singleton_method(:exchange) do |target, **options|
      raise 'Missing PKCE verifier' unless options[:verifier] == 'proof'
      target.merge('refresh_token' => 'private-refresh')
    end
    service = RedmineBackup::CloudConnectionService.new(runtime, actor: '7', oauth: oauth)
    service.complete_browser('primary', code: 'code', verifier: 'proof', redirect_uri: 'https://example.test/callback')
    assert_equal 'private-refresh', runtime.saved['values']['primary']['refresh_token']
    assert_equal runtime.config['secondary'], runtime.saved['values']['secondary']
  end
end
