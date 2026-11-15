# frozen_string_literal: true

module RedmineBackup
  module BackupLayout
    COMPONENTS = %w[database.dump application.tar.gz bootstrap.json RECOVERY.md manifest.json backup.zip complete.json].freeze

    def self.folder_name(run)
      name = "#{run.fetch('installation_id')}-#{run.fetch('id')}"
      validate_folder!(name)
      name
    end

    def self.validate_folder!(name)
      raise Error, 'INVALID_BACKUP_FOLDER' unless name.to_s.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,199}\z/)
    end

    def self.owned_key?(key, namespace)
      folder = namespace.delete_suffix('-')
      return true if key == "#{folder}.zip"
      return COMPONENTS.include?(key.delete_prefix("#{folder}/")) if key.start_with?("#{folder}/")
      key.start_with?(namespace) && !key.include?('/')
    end
  end
end
