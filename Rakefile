# frozen_string_literal: true

SAMPLES = FileList["samples/*.rb"]

# Run a Shoes program headlessly with a hard wall-clock limit, so a hung app
# fails the build instead of hanging it. Returns [stderr, ok].
def run_shoes(args, env: {}, run_ms: 700, limit: 90)
  require "open3"
  require "timeout"

  err = nil
  ok = false
  Open3.popen3({ "CLOGS_EXIT_AFTER_MS" => run_ms.to_s }.merge(env), *args) do |stdin, stdout, stderr, thread|
    stdin.close
    reader = Thread.new { stderr.read }
    Thread.new { stdout.read }
    begin
      Timeout.timeout(limit) { thread.value }
      ok = thread.value.success?
    rescue Timeout::Error
      Process.kill("KILL", thread.pid) rescue nil
      err = "timed out after #{limit}s\n"
    end
    err ||= reader.value
  end
  [err.to_s, ok]
end

def meaningful_stderr(err)
  err.lines.reject do |line|
    line =~ /dbind-WARNING|AT-SPI|No release found in CHANGELOG|Unexpected non-style keyword|^\s*$/
  end
end

desc "Run Hackety Hack"
task :run do
  ruby "-Iclogs/lib -I. hacketyhack.rb"
end

desc "Boot the Hackety Hack IDE headlessly and check it builds its window"
task :boot do
  err, ok = run_shoes([RbConfig.ruby, File.join(__dir__, "hacketyhack.rb")], run_ms: 2500, limit: 120)
  noise = meaningful_stderr(err)

  raise "Hackety Hack did not shut down cleanly:\n#{err}" unless ok
  raise "Hackety Hack wrote to stderr:\n#{noise.join}" unless noise.empty?

  puts "Hackety Hack booted, built its window and shut down cleanly."
end

desc "Run every bundled Shoes sample headlessly and report which ones work"
task :samples do
  failures = []
  SAMPLES.sort.each do |sample|
    err, ok = run_shoes(
      [RbConfig.ruby, "-Iclogs/lib", "-I.", "-e", "require 'lib/compat/shoes3'; load #{sample.inspect}"],
      run_ms: 700, limit: 60
    )
    noise = meaningful_stderr(err)

    if ok && noise.empty?
      puts "  ok    #{sample}"
    else
      puts "  FAIL  #{sample}"
      puts noise.first(4).map { |l| "          #{l}" }.join
      failures << sample
    end
  end

  puts
  puts "#{SAMPLES.size - failures.size}/#{SAMPLES.size} samples run cleanly on Clogs."
  # Not every Shoes 3 sample runs yet; KNOWN_SAMPLE_FAILURES keeps CI honest
  # about which ones without letting new breakage in unnoticed.
  unexpected = failures - KNOWN_SAMPLE_FAILURES
  fixed = KNOWN_SAMPLE_FAILURES & SAMPLES.to_a - failures
  puts "Newly fixed (remove from KNOWN_SAMPLE_FAILURES): #{fixed.join(", ")}" unless fixed.empty?
  raise "Samples that used to work are now broken: #{unexpected.join(", ")}" unless unexpected.empty?
end

# Samples that rely on Shoes 3 features Clogs does not implement yet. See
# clogs/docs/libui_shoes_coverage.md.
KNOWN_SAMPLE_FAILURES = [
  "samples/Animated Flowers.rb",  # Shoes 3 image() canvases
  "samples/Fractal.rb",           # Shoes 3 image() canvases
  "samples/Funnies.rb",           # needs Shoes 3 download() semantics
  "samples/Guessing Game.rb",     # ask() during app init, before the window exists
  "samples/Turtle Barbwire.rb",   # turtle canvas needs Hackety Hack's own widgets
  "samples/Turtle Stars.rb"       # turtle canvas needs Hackety Hack's own widgets
].freeze

task default: [:samples, :boot]
