# frozen_string_literal: true

require_relative 'test_helper'

class NotificationTest < BackupTest
  Person = Struct.new(:id, :mail, :status)
  Team = Struct.new(:users)

  class Relation < Array
    def where(id:, **_options)
      self.class.new(select { |person| id.include?(person.id) })
    end

    def includes(_name)
      self
    end
  end

  def setup
    super
    @store = RedmineBackup::Store.new(File.join(@temporary, 'state'))
    @people = [Person.new(1, 'one@example.test', 1), Person.new(2, 'two@example.test', 1), Person.new(3, 'locked@example.test', 3)]
    people = @people
    users = Class.new
    users.define_singleton_method(:active) { Relation.new(people.select { |person| person.status == 1 }) }
    users.define_singleton_method(:find) { |identifier| people.find { |person| person.id == identifier } }
    teams = Class.new
    teams.define_singleton_method(:where) { |**_options| Relation.new([Team.new(people)]) }
    Object.const_set(:User, users)
    Object.const_set(:Group, teams)
    @mailer = Class.new
    Object.const_set(:RedmineBackupMailer, @mailer)
  end

  def teardown
    %i[User Group RedmineBackupMailer].each { |name| Object.send(:remove_const, name) }
    super
  end

  def test_group_and_direct_recipients_are_active_and_deduplicated
    service = RedmineBackup::NotificationService.new(config('user_ids' => [1], 'group_ids' => [10]), @store)
    assert_equal [1, 2], service.recipient_ids.sort
    @people[1].status = 3
    assert_equal [1], service.recipient_ids
  end

  def test_retry_does_not_resend_to_already_delivered_recipients
    service = RedmineBackup::NotificationService.new(config('user_ids' => [1, 2]), @store)
    delivered = []
    fail_second = true
    @mailer.define_singleton_method(:alert) do |user, _event|
      delivery = Object.new
      delivery.define_singleton_method(:deliver_now) do
        raise 'Simulated delivery failure' if user.id == 2 && fail_second
        delivered << user.id
      end
      delivery
    end
    service.queue({ 'id' => 'test-run' }, 'UPLOAD_FAILED')
    service.queue({ 'id' => 'test-run' }, 'UPLOAD_FAILED')
    assert_equal 1, @store.read('notifications').length
    service.deliver_pending
    assert_equal [1], delivered
    pending = @store.read('notifications')
    pending.first['next_attempt_at'] = (Time.now.utc - 1).iso8601
    @store.write('notifications', pending)
    fail_second = false
    service.deliver_pending
    assert_equal [1, 2], delivered
    assert @store.read('notifications').first['sent_at']
  end
end
