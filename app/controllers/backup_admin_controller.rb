# frozen_string_literal: true

require_relative '../../lib/redmine_backup/runtime'

class BackupAdminController < ApplicationController
  before_action :require_admin
  before_action :load_runtime

  def index
    @config = @runtime.config
    @runs = @runtime.store.read('runs', []).reverse.first(100)
    @health = @runtime.health
    @users = User.active.sorted
    @groups = Group.where(type: 'Group').order(:lastname)
    @audit = @runtime.store.read('audit', []).reverse.first(40)
    @notifications = @runtime.store.read('notifications', []).reverse.first(20)
    @recovery = @runtime.recovery?
  end

  def update
    @runtime.save!(settings_input, actor: User.current.id.to_s)
    flash[:notice] = 'Backup settings saved. Retention changes apply on the next successful upload.'
    redirect_to redmine_backups_path
  rescue RedmineBackup::Error => error
    flash[:error] = safe_error(error)
    redirect_to redmine_backups_path
  end

  def create
    @runtime.enqueue!(params.require(:kind), run_id: params[:run_id].presence, actor: User.current.id.to_s)
    flash[:notice] = 'Request queued for the backup worker.'
    redirect_to redmine_backups_path
  rescue RedmineBackup::Error => error
    flash[:error] = safe_error(error)
    redirect_to redmine_backups_path
  end

  def activate
    @runtime.activate!(actor: User.current.id.to_s)
    flash[:notice] = 'This restored instance is activated. Scheduling remains paused; review settings before enabling.'
    redirect_to redmine_backups_path
  rescue RedmineBackup::Error => error
    flash[:error] = safe_error(error)
    redirect_to redmine_backups_path
  end

  private

  def load_runtime
    @runtime = RedmineBackup::Runtime.new
  rescue StandardError
    render plain: 'Backup control storage is unavailable. Check private storage and the application key.', status: :service_unavailable
  end

  def settings_input
    submitted = params.require(:backup)
    values = @runtime.config.values.dup
    %w[time timezone local_directory local_keep_dates remote_keep_dates packaging disk_reserve_mb timeout_seconds pg_bin].each do |key|
      values[key] = submitted[key].to_s if submitted.key?(key)
    end
    values['enabled'] = submitted['enabled'] == '1'
    %w[recovery_notifications daily_success_summary].each { |key| values[key] = submitted[key] == '1' }
    values['additional_paths'] = submitted['additional_paths'].to_s.lines.map(&:strip).reject(&:empty?)
    %w[user_ids group_ids].each { |key| values[key] = Array(submitted[key]).map(&:to_i).select(&:positive?).uniq }
    %w[primary secondary].each do |slot|
      input = submitted.fetch(slot, ActionController::Parameters.new)
      original = @runtime.config[slot]
      values[slot] = original.dup
      (RedmineBackup::Runtime::TARGET_FIELDS + RedmineBackup::Runtime::SECRET_FIELDS).each do |key|
        next unless input.key?(key)
        next if RedmineBackup::Runtime::SECRET_FIELDS.include?(key) && input[key].to_s.empty?
        values[slot][key] = RedmineBackup::Runtime::SECRET_FIELDS.include?(key) ? input[key].to_s : input[key].to_s.strip
      end
      %w[enabled versioning retention_lock].each { |key| values[slot][key] = input[key] == '1' }
      if original['provider'] != values[slot]['provider'] || original['client_id'] != values[slot]['client_id'] || original['tenant_id'] != values[slot]['tenant_id']
        %w[access_token refresh_token expires_at].each { |key| values[slot].delete(key) }
      end
    end
    values
  end

  def safe_error(error)
    error.message.match?(/\A[A-Z0-9_]+\z/) ? error.message : 'BACKUP_REQUEST_FAILED'
  end
end
