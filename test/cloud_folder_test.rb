# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/cloud_http'

class CloudFolderTest < BackupTest
  NAME = 'test-installation-20261115T143000Z-abcdef123456'

  def google_folder(**overrides)
    { 'id' => 'run-folder', 'name' => NAME, 'mimeType' => 'application/vnd.google-apps.folder', 'parents' => ['destination'] }.merge(overrides.stringify_keys)
  end

  def service(http, provider = 'google_drive')
    target = { 'provider' => provider, 'folder_id' => 'destination' }
    target['drive_id'] = 'library' if provider == 'sharepoint'
    RedmineBackup::CloudFolderService.new(target, http: http, authorization: -> { { 'Authorization' => 'Bearer fixture' } })
  end

  def test_google_creates_one_folder_under_configured_destination
    http = CloudHttp.new({ data: { 'files' => [] } }, { data: google_folder })
    folder = service(http).prepare(NAME)
    assert_equal({ 'id' => 'run-folder', 'name' => NAME }, folder)
    assert_equal ['destination'], JSON.parse(http.requests.last[2][:body])['parents']
    assert_equal NAME, JSON.parse(http.requests.last[2][:body])['name']
  end

  def test_repeated_prepare_reuses_existing_folder_and_validates_stored_id
    http = CloudHttp.new({ data: { 'files' => [google_folder] } }, { data: google_folder })
    locations = service(http)
    first = locations.prepare(NAME)
    assert_equal first, locations.prepare(NAME, first)
    assert_equal %w[get get], http.requests.map(&:first)
  end

  def test_duplicate_google_folders_fail_without_creating_another
    http = CloudHttp.new(data: { 'files' => [google_folder, google_folder(id: 'duplicate')] })
    error = assert_raises(RedmineBackup::Error) { service(http).prepare(NAME) }
    assert_equal 'DUPLICATE_BACKUP_FOLDERS', error.message
    assert_equal 1, http.requests.length
  end

  def test_folder_moved_outside_destination_cannot_be_reused_or_deleted
    http = CloudHttp.new(data: google_folder(parents: ['another-destination']))
    assert_raises(RedmineBackup::Error) { service(http).assert!({ 'id' => 'run-folder', 'name' => NAME }, NAME) }
    assert_equal ['get'], http.requests.map(&:first)
  end

  def test_nonempty_folder_is_never_recursively_deleted
    http = CloudHttp.new({ data: google_folder }, { data: { 'files' => [{ 'id' => 'unrelated', 'name' => 'keep.txt' }] } })
    error = assert_raises(RedmineBackup::Error) { service(http).delete_empty('id' => 'run-folder', 'name' => NAME) }
    assert_equal 'BACKUP_FOLDER_NOT_EMPTY', error.message
    assert_equal %w[get get], http.requests.map(&:first)
  end

  def test_empty_owned_folder_can_be_deleted
    http = CloudHttp.new({ data: google_folder }, { data: { 'files' => [] } }, { status: 204, data: {} })
    service(http).delete_empty('id' => 'run-folder', 'name' => NAME)
    assert_equal 'delete', http.requests.last.first
  end

  def test_microsoft_folder_uses_configured_library_and_parent
    item = { 'id' => 'run-folder', 'name' => NAME, 'folder' => {}, 'parentReference' => { 'id' => 'destination', 'driveId' => 'library' } }
    http = CloudHttp.new({ data: { 'value' => [] } }, { status: 201, data: item })
    assert_equal 'run-folder', service(http, 'sharepoint').prepare(NAME)['id']
    assert_includes http.requests.last[1], '/drives/library/items/destination/children'
    assert_equal 'fail', JSON.parse(http.requests.last[2][:body])['@microsoft.graph.conflictBehavior']
  end

  def test_path_traversal_folder_names_are_rejected_before_http
    http = CloudHttp.new
    assert_raises(RedmineBackup::Error) { service(http).prepare('../outside') }
    assert_empty http.requests
  end
end
