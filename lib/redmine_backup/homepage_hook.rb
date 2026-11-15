# frozen_string_literal: true

require_relative 'runtime'

module RedmineBackup
  class HomepageHook < Redmine::Hook::ViewListener
    def view_welcome_index_right(context = {})
      return '' unless User.current&.admin?
      render_summary(context)
    end

    private

    def render_summary(context)
      runtime = Runtime.new
      return '' unless runtime.config['show_homepage_status']
      context.fetch(:controller).send(:render_to_string, partial: 'backup_admin/homepage_status',
                                     locals: { summary: HomepageSummaryService.call(runtime) })
    rescue StandardError
      context.fetch(:controller).send(:render_to_string, partial: 'backup_admin/homepage_status', locals: { summary: nil })
    end
  end
end
