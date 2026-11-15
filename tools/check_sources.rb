# frozen_string_literal: true

require 'date'
require 'ripper'
require 'yaml'

root = File.expand_path('..', __dir__)
errors = []
files = Dir.glob(File.join(root, '{app,lib,config,test,tools}', '**', '*.rb')) + Dir.glob(File.join(root, 'bin', '*')).select { |path| File.file?(path) }
files.reject { |path| path.include?('/tools/runtime/') }.sort.each do |path|
  errors << "Ruby syntax: #{path.delete_prefix(root + '/')}" unless Ripper.sexp(File.read(path))
end
Dir.glob(File.join(root, '.github', '**', '*.yml')).each do |path|
  YAML.load_file(path, permitted_classes: [Date, Time], aliases: true)
  File.foreach(path).with_index do |line, index|
    indentation = line[/\A */].length
    errors << "YAML indentation: #{index + 1}" unless (indentation % 4).zero?
  end
end
Dir.glob(File.join(root, '{*.md,documentation/**/*.md}')).each do |path|
  File.read(path).scan(/\]\(([^)]+)\)/).flatten.each do |link|
    next if link.match?(/\A(?:https?:|#|mailto:)/)
    target = File.expand_path(link.split('#').first, File.dirname(path))
    errors << "Broken documentation link: #{link}" unless File.exist?(target)
  end
end
unless errors.empty?
  warn errors.join("\n")
  exit 1
end
puts 'Ruby source syntax, workflow YAML and local documentation links passed.'
