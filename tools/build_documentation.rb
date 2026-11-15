# frozen_string_literal: true

require 'cgi'
require 'rdoc'
require 'rdoc/markdown'
require 'rdoc/markup/to_html'

root = File.expand_path('../documentation', __dir__)
pages = {
  'PLAN.md' => 'Full plan', 'INSTALLATION.md' => 'Installation', 'CONFIGURATION.md' => 'Configuration',
  'AUTHENTICATION.md' => 'Provider authentication',
  'RECOVERY.md' => 'Recovery', 'RECOVERY-WORKSHEET.md' => 'Recovery worksheet', 'STORAGE.md' => 'Storage catalog',
  'SECURITY.md' => 'Security', 'IMPLEMENTATION.md' => 'Implementation', 'DEPLOYMENT.md' => 'Deployment',
  'VALIDATION.md' => 'Validation', 'REFERENCE.md' => 'References'
}
sections = pages.map do |filename, title|
  identifier = filename.delete_suffix('.md').downcase
  content = RDoc::Markdown.parse(File.read(File.join(root, filename)))
  html = RDoc::Markup::ToHtml.new(RDoc::Options.new).convert(content)
  html = html.gsub(/id="([^"]+)"/, "id=\"#{identifier}-\\1\"")
             .gsub(/href="#([^"]+)"/, "href=\"##{identifier}-\\1\"")
  pages.each_key do |target|
    html = html.gsub("href=\"#{target}\"", "href=\"##{target.delete_suffix('.md').downcase}\"")
  end
  html = html.gsub(/href="\.\.\/([^"]+)"/, 'href="https://github.com/KrishnaST/redmine-backup-plugin/blob/main/\1"')
  "<section id=\"#{identifier}\" aria-label=\"#{CGI.escapeHTML(title)}\"><span id=\"#{identifier}-top\"></span>#{html}</section>"
end
navigation = pages.map { |filename, title| "<a href=\"##{filename.delete_suffix('.md').downcase}\">#{CGI.escapeHTML(title)}</a>" }.join
document = <<~HTML
  <!doctype html>
  <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Redmine Backup — Documentation</title>
  <style>
  *{box-sizing:border-box}body{margin:0;background:#f3f5f7;color:#27313e;font:15px/1.65 system-ui,sans-serif}
  nav{position:fixed;inset:0 auto 0 0;width:230px;background:#27313e;padding:25px;overflow:auto;color:#fff}
  nav strong{display:block;margin-bottom:20px;font-size:20px}nav a{display:block;color:#d9e4ee;text-decoration:none;padding:7px 0}
  main{margin-left:230px;padding:30px;max-width:1250px}section{background:#fff;border:1px solid #dde3e9;border-radius:8px;padding:28px;margin-bottom:26px;scroll-margin:20px}
  h1,h2,h3{line-height:1.25;color:#263b51}table{border-collapse:collapse;width:100%;font-size:14px}th,td{border:1px solid #dce2e8;padding:8px 11px;text-align:left;vertical-align:top}th{background:#eaf0f5}
  pre{padding:16px;background:#eef2f6;overflow:auto;border-radius:5px}code{overflow-wrap:anywhere}a{color:#1c608e}li{margin-bottom:7px}
  @media(max-width:800px){nav{position:relative;width:auto}nav a{display:inline-block;margin-right:18px}main{margin:0;padding:14px}section{padding:18px}}
  @media print{nav{display:none}main{margin:0;padding:0}section{border:0;break-before:page}a{color:inherit}}
  </style></head><body><nav><strong>Redmine Backup</strong>#{navigation}<hr><a href="https://github.com/KrishnaST/redmine-backup-plugin/tree/main/documentation">Source documentation</a></nav><main>
  #{sections.join("\n")}
  </main></body></html>
HTML
destination = ARGV.first || File.join(root, 'index.html')
File.write(destination, document)
puts "Built offline documentation: #{pages.length} sections."
