#!/usr/bin/env ruby
require 'json'
require 'digest'
require 'open3'
abort 'Usage: release_metadata.rb APP ASSET MODE' unless ARGV.length == 3
app, zip, mode = ARGV
abort 'Unknown signing mode' unless %w[adhoc developer-id notarized].include?(mode)
def plist(app, key)
  text, _error, status = Open3.capture3('/usr/libexec/PlistBuddy', '-c', "Print :#{key}", File.join(app, 'Contents/Info.plist'))
  abort 'Cannot read app metadata' unless status.success?
  text.strip
end
revision, _error, status = Open3.capture3('git', 'rev-parse', 'HEAD')
abort 'Cannot identify source revision' unless status.success?
changes, _error, status = Open3.capture3('git', 'status', '--porcelain')
abort 'Cannot identify source state' unless status.success?
digest = Digest::SHA256.file(zip).hexdigest
metadata = {
  'app' => 'AgentJournal', 'version' => plist(app, 'CFBundleShortVersionString'),
  'build' => plist(app, 'CFBundleVersion'), 'minimum_macos' => plist(app, 'LSMinimumSystemVersion'),
  'architecture' => 'arm64', 'signing' => mode, 'notarized' => mode == 'notarized',
  'source_revision' => revision.strip, 'source_dirty' => !changes.empty?,
  'asset' => File.basename(zip), 'sha256' => digest
}
# No home paths, machine identifiers, certificate names or account information.
abort 'Unsupported asset extension' unless zip.match?(/\.(zip|dmg)\z/)
sidecar = zip.end_with?('.zip') ? zip.sub(/\.zip\z/, '.json') : zip + '.json'
File.write(sidecar, JSON.pretty_generate(metadata) + "\n")
File.write(zip + '.sha256', "#{digest}  #{File.basename(zip)}\n")
