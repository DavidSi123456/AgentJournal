#!/usr/bin/env ruby
# Heuristic pre-publication guard, not a security audit. Never print matched data.
require 'open3'

module PrivacyCheck
  CONTENT_RULES = {
    'private-key material' => /-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----/,
    'OpenAI / Anthropic-style token' => /\bsk-[A-Za-z0-9_-]{20,}/,
    'GitHub token' => /\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})/
  }.freeze

  def self.rules(path, bytes, symlink: false)
    reasons = []
    reasons << 'symlink needs manual review' if symlink
    normalized = path.downcase
    sensitive = normalized.match?(%r{(?:\A|/)(?:\.build|dist|data|exports|sessions|archived_sessions|\.swiftpm)(?:/|\z)}) ||
      normalized.match?(%r{(?:\A|/)(?:auth|credentials|index)\.json\z}) ||
      normalized.match?(%r{(?:\A|/)[^/]*journal[^/]*\.json\z}) ||
      normalized.match?(/\.(?:jsonl|sqlite\w*|log|p12|pfx|p8|pem|key|cer|mobileprovision|provisionprofile)\z/) ||
      (File.basename(normalized).start_with?('.env') && File.basename(normalized) != '.env.example') ||
      File.basename(normalized).start_with?('config.local.')
    reasons << 'private data / signing credential filename' if sensitive
    text = bytes.dup.force_encoding(Encoding::UTF_8).scrub
    CONTENT_RULES.each { |name, pattern| reasons << name if text.match?(pattern) }
    # /Users/demo is used exclusively for public synthetic redaction fixtures.
    if text.scan(%r{/Users/([^\s/\\"'|()\[\]]+)(?:/|$)}).flatten.any? { |name| !%w[demo Shared].include?(name) }
      reasons << 'personal absolute macOS home path'
    end
    reasons
  end

  def self.git(*args)
    stdout, _stderr, status = Open3.capture3('git', *args)
    raise "Git command failed: #{args.first}" unless status.success?
    stdout
  end

  def self.self_test
    token = 'sk-' + ('x' * 32)
    private_key = '-----BEGIN ' + 'PRIVATE KEY-----'
    personal_path = '/' + 'Users/synthetic-person/project'
    cases = [
      ['Sources/example.swift', 'public synthetic text', false],
      ['Tests/example.swift', '/Users/demo/private.md', false],
      ['example.swift', token, true],
      ['example.swift', 'ghp_' + ('x' * 36), true],
      ['example.swift', 'github_pat_' + ('x' * 32), true],
      ['example.swift', private_key, true],
      ['README.md', personal_path, true],
      ['cert.p12', 'binary', true],
      ['auth.json', '{}', true],
      ['exports/card.png', 'image', true],
      ['private/session.jsonl', '{}', true],
      ['.env.local', 'secret', true],
      ['.env.example', 'DOCUMENTED_PLACEHOLDER', false]
    ]
    cases.each do |path, data, expected|
      raise 'Privacy self-test failed' unless !rules(path, data).empty? == expected
    end
    raise 'Symlink self-test failed' if rules('link', '', symlink: true).empty?
    puts "Privacy scanner: #{cases.length + 1} synthetic checks passed."
  end
end

if ARGV.include?('--help')
  puts 'Usage: ruby scripts/privacy_check.rb [--staged] [--history] | --self-test | --artifact APP'
  puts 'Default: tracked + non-ignored untracked publish candidates. --staged reads staged blobs.'
  puts '--history also checks reachable Git blobs. No matched text or secret values are printed.'
  exit
end
if ARGV == ['--self-test']
  PrivacyCheck.self_test
  exit
end
if ARGV.first == '--artifact'
  abort 'Use --artifact with one AgentJournal.app bundle.' unless ARGV.length == 2
  app = File.expand_path(ARGV[1])
  abort 'Expected a real AgentJournal.app directory.' unless File.basename(app) == 'AgentJournal.app' && File.directory?(app) && !File.symlink?(app)
  abort 'Missing application layout.' unless File.file?(File.join(app, 'Contents/Info.plist')) && File.file?(File.join(app, 'Contents/MacOS/AgentJournal'))
  files = Dir.glob(File.join(app, '**', '*'), File::FNM_DOTMATCH).reject { |f| File.directory?(f) && !File.symlink?(f) }
  abort 'Too many artifact files.' if files.length > 10000
  findings = []
  files.each do |file|
    relative = file.delete_prefix(app + '/')
    symlink = File.symlink?(file)
    abort 'Artifact file exceeds scan limit.' if !symlink && File.size(file) > 100 * 1024 * 1024
    bytes = symlink ? File.readlink(file) : File.binread(file)
    reasons = PrivacyCheck.rules(relative, bytes, symlink: symlink)
    findings << [relative, reasons] unless reasons.empty?
  end
  puts "Artifact privacy scan: #{files.length} files."
  findings.each { |path, reasons| warn "REVIEW artifact #{path.dump}: #{reasons.join('; ')}" }
  abort 'Artifact privacy guard failed. No matched values were printed.' unless findings.empty?
  puts 'No configured artifact heuristic matched. Images and arbitrary prose still need review.'
  exit
end
abort 'Unknown option; use --help.' unless (ARGV - %w[--staged --history]).empty?

Dir.chdir(File.expand_path('..', __dir__))
staged = ARGV.include?('--staged')
paths = if staged
  PrivacyCheck.git('diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z').split("\0")
else
  PrivacyCheck.git('ls-files', '--cached', '--others', '--exclude-standard', '-z').split("\0").uniq
end
findings = []
checked = 0
paths.each do |path|
  next if !staged && !File.exist?(path) && !File.symlink?(path)
  symlink = staged ? PrivacyCheck.git('ls-files', '--stage', '--', path).start_with?('120000 ') : File.symlink?(path)
  # Do not follow links into personal files, even for a newly added symlink.
  bytes = staged ? PrivacyCheck.git('show', ":#{path}") : (symlink ? File.readlink(path) : File.binread(path))
  checked += 1
  reasons = PrivacyCheck.rules(path, bytes, symlink: symlink)
  findings << ["publish candidate #{path.dump}", reasons] unless reasons.empty?
end
historical = 0
if ARGV.include?('--history')
  PrivacyCheck.git('rev-list', '--objects', '--all').each_line do |line|
    oid, path = line.chomp.split(' ', 2)
    next unless path && PrivacyCheck.git('cat-file', '-t', oid).strip == 'blob'
    historical += 1
    reasons = PrivacyCheck.rules(path, PrivacyCheck.git('cat-file', 'blob', oid))
    findings << ["history blob #{oid} (#{path.dump})", reasons] unless reasons.empty?
  end
end
puts "Privacy scan: #{checked} publish candidates, #{historical} reachable historical blobs."
findings.each { |label, reasons| warn "REVIEW #{label}: #{reasons.join('; ')}" }
abort 'Privacy guard failed. Review the listed files; never paste secrets into an issue.' unless findings.empty?
puts 'No configured heuristic matched. Review screenshots, staged contents and history manually too.'
