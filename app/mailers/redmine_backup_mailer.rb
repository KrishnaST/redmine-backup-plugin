# frozen_string_literal: true

class RedmineBackupMailer < Mailer
  def alert(user, event)
    @event = event
    @details_url = "#{Setting.protocol}://#{Setting.host_name}#{Redmine::Utils.relative_url_root}/admin/backups"
    labels = { 'TEST_NOTIFICATION' => 'test notification', 'BACKUP_COMPLETE' => 'completed', 'BACKUP_RECOVERED' => 'recovered' }
    @heading = labels.fetch(event['code'], 'attention required').capitalize
    subject = "Redmine backup: #{labels.fetch(event['code'], 'attention required')}"
    mail to: user.mail, subject: subject
  end
end
