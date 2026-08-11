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

desc "Monkey-fuzz the UI with seeded random input: rake fuzz SEEDS=12 FUZZ_MS=15000"
task :fuzz do
  require "open3"
  require "fileutils"
  require "tmpdir"
  require "set"

  seeds = (ENV["SEEDS"] || "12").to_i
  ms = (ENV["FUZZ_MS"] || "15000").to_i
  outdir = File.join(__dir__, "tmp", "fuzz")
  FileUtils.mkdir_p(outdir)

  findings = Hash.new { |h, k| h[k] = { seeds: Set.new, count: 0 } }
  crashes = []
  stalls = []

  # A headless X server beats the live desktop for fuzzing: no windows
  # flashing up, and no dependence on the compositor presenting frames -- on
  # an idle/locked session GTK paints block, which reads as a hang. Xvfb is
  # used automatically when installed; FUZZ_DISPLAY=live opts out.
  xvfb_pid = nil
  xvfb_display = nil
  if ENV["FUZZ_DISPLAY"] != "live" && system("which Xvfb > /dev/null 2>&1")
    n = (90..110).find { |d| !File.exist?("/tmp/.X11-unix/X#{d}") }
    if n
      xvfb_display = ":#{n}"
      xvfb_pid = Process.spawn("Xvfb", xvfb_display, "-screen", "0", "1280x900x24",
        %i[out err] => File::NULL)
      sleep 0.1 until File.exist?("/tmp/.X11-unix/X#{n}") || !system("kill -0 #{xvfb_pid} > /dev/null 2>&1")
      unless File.exist?("/tmp/.X11-unix/X#{n}")
        Process.wait(xvfb_pid)
        xvfb_pid = nil
        xvfb_display = nil
      end
      puts "Fuzzing headlessly on Xvfb #{xvfb_display}." if xvfb_display
    end
  end
  puts "Fuzzing on the live display; keep the session awake." unless xvfb_display

  seeds.times do |seed|
    home = Dir.mktmpdir("hh-fuzz-home-")
    begin
      env = {
        "HOME" => home,
        "HH_FUZZ" => "1",
        "FUZZ_SEED" => seed.to_s,
        "CLOGS_EXIT_AFTER_MS" => ms.to_s
      }
      if xvfb_display
        env["DISPLAY"] = xvfb_display
        env["GDK_BACKEND"] = "x11"
        env["WAYLAND_DISPLAY"] = nil
        env["XAUTHORITY"] = nil
      end
      out, status = Open3.capture2e(env, "timeout", "#{ms / 1000 + 45}",
        RbConfig.ruby, File.join(__dir__, "tools", "fuzz.rb"))
      File.write(File.join(outdir, "seed-#{seed}.log"), out)

      # A signal death (segfault, abort) is a crash in its own right, on top
      # of whatever handler errors were logged. The outer timeout (124) is
      # reported separately: on a live desktop it is almost always the
      # compositor suspending an idle session's frames, which blocks GTK
      # paints indefinitely -- an environment artifact, not an app bug. Fuzz
      # with the session awake, or under Xvfb, for trustworthy results.
      code = status.exitstatus
      if status.signaled?
        crashes << [seed, "signal #{status.termsig}"]
      elsif code == 124
        stalls << seed
      elsif code != 0
        crashes << [seed, "exit #{code}"]
      end

      lines = out.lines
      lines.each_with_index do |line, i|
        next unless line.start_with?("Clogs error: ")

        message = line.chomp.delete_prefix("Clogs error: ")
          .gsub(/0x[0-9a-f]+/, "0xX").gsub(/#<([A-Za-z:]+)[^>]*/, '#<\1>')
        frame = lines[(i + 1)..(i + 12)]&.find { |l| l =~ %r{(app|lib|clogs/lib)/[^:]+\.rb:\d+} }
        frame = frame ? frame[%r{(?:app|lib|clogs/lib)/[^:]+\.rb:\d+}] : "(no app frame)"
        f = findings["#{message} @ #{frame}"]
        f[:seeds] << seed
        f[:count] += 1
      end
      print "."
    ensure
      FileUtils.remove_entry(home)
    end
  end
  puts

  if findings.empty? && crashes.empty?
    puts "No errors in #{seeds} seeds x #{ms / 1000}s. Raise SEEDS or FUZZ_MS."
  else
    puts "#{findings.size} unique error signature(s) across #{seeds} seeds " \
         "(logs in tmp/fuzz/, replay with FUZZ_SEED=<n>):"
    puts
    findings.sort_by { |_, f| [-f[:seeds].size, -f[:count]] }.each do |sig, f|
      puts "#{f[:seeds].size} seed(s), #{f[:count]} hit(s), e.g. seed #{f[:seeds].min}"
      puts "  #{sig}"
    end
    unless crashes.empty?
      puts
      puts "Hard crashes (see the seed log tail):"
      crashes.each { |seed, how| puts "  seed #{seed}: #{how}" }
    end
  end
  unless stalls.empty?
    puts
    if xvfb_display
      puts "#{stalls.length} seed(s) timed out on Xvfb: #{stalls.join(", ")} -- these are real hangs."
    else
      puts "#{stalls.length} seed(s) timed out: #{stalls.join(", ")}. On a live desktop this " \
           "usually means the compositor suspended an idle session's frames (keep the " \
           "session awake, or install Xvfb for headless runs); a stall on an active " \
           "display is a real hang."
    end
  end
ensure
  if xvfb_pid
    begin
      Process.kill("TERM", xvfb_pid)
      Process.wait(xvfb_pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
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
