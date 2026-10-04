#!/usr/bin/env ruby
# End-to-end tests use only disposable, synthetic Git repositories.
require 'tmpdir'
require 'fileutils'
require 'open3'

scanner = File.expand_path('privacy_check.rb', __dir__)
fake_token = 'sk-' + ('x' * 32)
passed = 0
Dir.mktmpdir('agentjournal-privacy-test-') do |temporary|
  fixture = File.join(temporary, 'repo')
  FileUtils.mkdir_p(File.join(fixture, 'scripts'))
  FileUtils.cp(scanner, File.join(fixture, 'scripts/privacy_check.rb'))
  git = lambda do |*args|
    _out, _err, status = Open3.capture3('git', '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null',
      '-C', fixture, *args)
    raise "Synthetic Git fixture command failed: #{args.first}" unless status.success?
  end
  scan = lambda do |expected, *args|
    out, err, status = Open3.capture3('ruby', File.join(fixture, 'scripts/privacy_check.rb'), *args)
    raise 'Scanner exposed matched data' if (out + err).include?(fake_token)
    raise "Unexpected scanner result for #{args.join(' ')}" unless status.success? == expected
    passed += 1
    out + err
  end
  git.call('init', '--quiet')
  git.call('config', 'user.name', 'Synthetic Tester')
  git.call('config', 'user.email', 'test@example.invalid')
  sample = File.join(fixture, 'sample.txt')
  File.write(sample, 'Synthetic public text')
  git.call('add', '.')
  git.call('commit', '-qm', 'Synthetic baseline')
  scan.call(true, '--history')

  # Working tree secrets are caught, but unstaged changes do not alter a staged scan.
  File.write(sample, fake_token)
  scan.call(false)
  scan.call(true, '--staged')
  git.call('add', 'sample.txt')
  File.write(sample, 'Synthetic public text')
  scan.call(false, '--staged')
  scan.call(true)

  # A removed secret is still detected in reachable commit history.
  git.call('commit', '-qm', 'Synthetic secret-shaped fixture')
  git.call('add', 'sample.txt')
  git.call('commit', '-qm', 'Remove synthetic token')
  scan.call(true)
  scan.call(false, '--history')

  # Ignored data is not read. Force-added private filenames are still rejected.
  File.write(File.join(fixture, '.gitignore'), "sessions/\n")
  FileUtils.mkdir_p(File.join(fixture, 'sessions'))
  File.write(File.join(fixture, 'sessions/test.jsonl'), fake_token)
  scan.call(true)
  git.call('add', '-f', 'sessions/test.jsonl')
  scan.call(false, '--staged')

  # Never follow a symlink to personal files. Only the link itself is reported.
  outside = File.join(temporary, 'outside.txt')
  File.write(outside, fake_token)
  File.symlink(outside, File.join(fixture, 'link.txt'))
  report = scan.call(false)
  raise 'A symlink was followed' if report.lines.any? { |line| line.include?('link.txt') && line.include?('token') }

  # Artifact scanning covers compiled/bundled bytes and private filenames too.
  app = File.join(temporary, 'AgentJournal.app')
  executable = File.join(app, 'Contents/MacOS/AgentJournal')
  FileUtils.mkdir_p(File.dirname(executable))
  File.write(File.join(app, 'Contents/Info.plist'), 'Synthetic public metadata')
  File.binwrite(executable, fake_token)
  scan.call(false, '--artifact', app)
  File.binwrite(executable, 'Synthetic executable bytes')
  scan.call(true, '--artifact', app)
  File.write(File.join(app, 'Contents/journal.json'), '{}')
  scan.call(false, '--artifact', app)
end
puts "Privacy scanner: #{passed} end-to-end synthetic checks passed; temporary fixtures cleaned up."
