# frozen_string_literal: true

require_relative 'test_helper'

class ProviderTest < BackupTest
  class ReadbackProvider < RedmineBackup::Providers::Base
    def stream(_reference)
      yield 'first'
      yield 'second'
    end
  end

  def test_remote_verification_checks_bytes_and_digest
    provider = ReadbackProvider.new({})
    assert provider.verify!({}, 'bytes' => 11, 'sha256' => Digest::SHA256.hexdigest('firstsecond'))
    assert_raises(RedmineBackup::Error) { provider.verify!({}, 'bytes' => 11, 'sha256' => Digest::SHA256.hexdigest('changeddata')) }
    assert_raises(RedmineBackup::Error) { provider.verify!({}, 'bytes' => 12, 'sha256' => Digest::SHA256.hexdigest('firstsecond')) }
  end

  def test_unsupported_protection_does_not_claim_success
    provider = ReadbackProvider.new({ 'versioning' => true })
    assert_raises(RedmineBackup::Error) { provider.protect! }
  end

  def test_oauth_endpoints_do_not_accept_arbitrary_or_plaintext_hosts
    %w[http://graph.microsoft.com https://graph.microsoft.com.evil.test https://127.0.0.1 https://user:pass@graph.microsoft.com https://graph.microsoft.com:8443].each do |url|
      refute RedmineBackup::Providers::Http.allowed?(url), url
    end
    assert RedmineBackup::Providers::Http.allowed?('https://graph.microsoft.com/v1.0/me')
    assert RedmineBackup::Providers::Http.allowed?('https://example.up.1drv.com/upload')
  end

  def test_unknown_provider_fails_explicitly
    assert_raises(RedmineBackup::Error) { RedmineBackup::Providers.build({ 'provider' => 'unknown' }) }
  end

  def test_locked_set_is_not_partially_deleted
    provider = ReadbackProvider.new({})
    deleted = []
    provider.define_singleton_method(:locked?) { |_reference| true }
    provider.define_singleton_method(:delete) { |reference| deleted << reference }
    assert_raises(RedmineBackup::Error) { provider.delete_set!('marker' => { 'id' => 'marker' }, 'artifacts' => [{ 'reference' => { 'id' => 'data' } }]) }
    assert_empty deleted
  end

  def test_completion_marker_is_removed_before_payloads
    provider = ReadbackProvider.new({})
    deleted = []
    provider.define_singleton_method(:delete) { |reference| deleted << reference['id'] }
    provider.delete_set!('marker' => { 'id' => 'marker' }, 'artifacts' => [{ 'reference' => { 'id' => 'data' } }])
    assert_equal %w[marker data], deleted
  end
end
