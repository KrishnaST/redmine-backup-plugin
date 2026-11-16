# frozen_string_literal: true

module RedmineBackup
  class PrefixedTarWriter
    def initialize(writer, prefix)
      @writer, @prefix = writer, prefix
    end

    def mkdir(name, mode)
      @writer.mkdir("#{@prefix}/#{name}", mode)
    end

    def add_symlink(name, target, mode)
      @writer.add_symlink("#{@prefix}/#{name}", target, mode)
    end

    def add_file_simple(name, mode, size, &block)
      @writer.add_file_simple("#{@prefix}/#{name}", mode, size, &block)
    end
  end
end
