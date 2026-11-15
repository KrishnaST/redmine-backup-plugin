# frozen_string_literal: true

module RedmineBackup
  class Coverage
    def self.discover(application_root:, attachment_root:, environment: ENV)
      paths = [File.realpath(application_root), File.realpath(attachment_root)]
      environment.each_pair do |key, value|
        paths << value if key.start_with?('REDMINE_') && key.end_with?('_FILE', '_DIRECTORY') && !value.to_s.empty?
      end
      services = PlatformService.linux? ? Dir.glob('/etc/systemd/system/*redmine*.service') : []
      services.reject { |path| File.basename(path).include?('gateway') }.each do |service|
        paths << service
        File.foreach(service) do |line|
          next unless line.start_with?('EnvironmentFile=')
          line.sub('EnvironmentFile=', '').strip.split.each do |entry|
            next if entry.start_with?('-') && !File.exist?(entry.delete_prefix('-'))
            paths << entry.delete_prefix('-')
          end
        end
      end
      paths.uniq
    end

    def self.validate!(paths)
      paths.each do |path|
        raise Error, 'SOURCE_PATH_MISSING_OR_UNREADABLE' unless File.exist?(path) && File.readable?(path)
        raise Error, 'GATEWAY_PATH_EXCLUDED' if File.basename(path).match?(/gateway|letsencrypt/i)
      end
      true
    end
  end
end
