# frozen_string_literal: true

require_relative '../../lib/redmine_backup/runtime'

class BackupAdminController < ApplicationController
  include BackupOauthFlow
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
    @callback_url = backup_callback_url rescue nil
  end

  def update
    @runtime.save!(settings_input, actor: User.current.id.to_s)
    return begin_storage_authorization(RedmineBackup::Runtime.new, params[:connect_slot]) if params[:connect_slot].present?
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
    %w[recovery_notifications daily_success_summary show_homepage_status].each { |key| values[key] = submitted[key] == '1' }
    values['additional_paths'] = submitted['additional_paths'].to_s.lines.map(&:strip).reject(&:empty?)
    %w[user_ids group_ids].each { |key| values[key] = Array(submitted[key]).map(&:to_i).select(&:positive?).uniq }
    %w[primary secondary].each do |slot|
      input = submitted.fetch(slot, ActionController::Parameters.new)
      values[slot] = RedmineBackup::ProviderSettingsService.merge(@runtime.config[slot], input)
    end
    values
  end

  def safe_error(error)
    error.message.match?(/\A[A-Z0-9_]+\z/) ? error.message : 'BACKUP_REQUEST_FAILED'
  end
end
