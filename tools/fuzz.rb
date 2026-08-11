#!/usr/bin/env ruby
# frozen_string_literal: true

# In-process monkey fuzzer for the Hackety Hack UI.
#
#   rake fuzz                # a campaign of seeds, aggregated report
#   FUZZ_SEED=3 rake fuzz    # via the task; or directly:
#   HH_FUZZ=1 HOME=$(mktemp -d /tmp/hh-fuzz-home-XXXX) FUZZ_SEED=3 \
#     CLOGS_EXIT_AFTER_MS=15000 ruby tools/fuzz.rb
#
# Drives the app with a seeded stream of random clicks, drags and keys, so a
# failing seed replays exactly: every action is logged to stderr with its
# step number. Events are injected where libui's callbacks would deliver
# them rather than synthesized as X input, which does not route reliably
# under Wayland.
#
# Errors handlers raise surface as "Clogs error:" lines on stderr; a build
# failure or crash ends the process with a nonzero status. `rake fuzz`
# collects both across seeds and prints unique signatures.

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(root)
$LOAD_PATH.unshift(File.join(root, "clogs", "lib"))

# The fuzzer clicks everything, including "delete this program" links, and
# writes prefs. Never let it near a real profile.
unless ENV["HH_FUZZ"] == "1" && ENV["HOME"].to_s.include?("hh-fuzz-home")
  abort "tools/fuzz.rb refuses to run against a real HOME. Use `rake fuzz`, " \
        "or set HH_FUZZ=1 and point HOME at a throwaway hh-fuzz-home directory."
end

require "lib/compat/shoes3"

SEED = (ENV["FUZZ_SEED"] || "0").to_i
RNG = Random.new(SEED)
warn "FUZZ seed=#{SEED}"

# Even seeds fuzz the splash too; odd seeds skip straight to the main UI so
# most of the session exercises the tabs instead of the intro.
if SEED.odd?
  require "app/boot"
  HH::PREFS["skip_intro"] = true
end

# Dialogs are real modal windows and would hang an unattended run: answer
# them deterministically instead. Clipboard access shells out to xclip and
# would clobber the desktop clipboard. Nothing may open a browser.
module Clogs::Dialogs
  def self.alert(*); nil; end

  def self.confirm(*)
    RNG.rand < 0.5
  end

  def self.ask(*)
    "fuzz"
  end

  def self.open_file(*); nil; end
  def self.save_file(*); nil; end
  def self.open_folder(*); nil; end
end

module Clogs::Clipboard
  @fuzz_clipboard = ""

  def self.read
    @fuzz_clipboard
  end

  def self.write(text)
    @fuzz_clipboard = text.to_s
  end
end

class Shoes
  def self.show_manual; end

  module Compat
    module_function

    def open_url(_url); end
  end
end

class Shoes::App
  def visit(_url); end
end

# The one bug class events cannot surface on their own: a handler that blocks
# the UI thread. If no fuzz step lands for a while, dump every thread's
# backtrace so the hang is attributable, not just a timeout.
$fuzz_steps = 0
Thread.new do
  last = -1
  loop do
    sleep 5
    if $fuzz_steps == last && $fuzz_steps.positive?
      warn "FUZZ-STALL at step #{$fuzz_steps}; thread dump:"
      Thread.list.each do |t|
        warn "  #{t == Thread.main ? "main" : t.object_id}: " \
             "#{(t.backtrace || []).first(10).join("\n    ")}"
      end
    end
    last = $fuzz_steps
  end
end

module FuzzDriver
  CHARS = [*"a".."z", *"0".."9", " ", "\n", "\t", "\b",
           "(", ")", "[", "]", "\"", "=", "+", "-", "*", ".", ","].freeze
  EXT_KEYS = %i[left right up down home end delete].freeze

  def run
    add_timer((ENV["FUZZ_STEP_MS"] || "120").to_i, repeat: true) { fuzz_step }
    super
  end

  def fuzz_step
    @fuzz_n = (@fuzz_n || 0) + 1
    $fuzz_steps = @fuzz_n
    w = app_width
    h = app_height
    r = RNG.rand
    if r < 0.35
      fuzz_click_peer
    elsif r < 0.45
      fuzz_click(RNG.rand(w), RNG.rand(h))
    elsif r < 0.53
      fuzz_click(4 + RNG.rand(30), RNG.rand(h))                        # sidebar tabs
    elsif r < 0.58
      fuzz_click(40 + RNG.rand(w - 40), RNG.rand(40))                  # top tab row
    elsif r < 0.78
      fuzz_key(CHARS.sample(random: RNG), ctrl: RNG.rand < 0.15)
    elsif r < 0.88
      fuzz_key(nil, ext: EXT_KEYS.sample(random: RNG))
    else
      fuzz_drag
    end
  rescue StandardError => e
    warn "FUZZ-HARNESS-ERROR: #{e.class}: #{e.message}"
  end

  # Blind clicks mostly hit empty space; aiming at a random clickable peer's
  # centre reaches links, buttons and tabs at a useful rate.
  def fuzz_click_peer
    peers = []
    document_root&.each_peer do |p|
      peers << p if p.clickable? && p.width.to_i.positive? && !p.abs_x.nil?
    end
    return fuzz_click(RNG.rand(app_width), RNG.rand(app_height)) if peers.empty?

    peer = peers.sample(random: RNG)
    x = (peer.abs_x + peer.width / 2).clamp(0, app_width - 1)
    y = (peer.abs_y + peer.height / 2).clamp(0, app_height - 1)
    warn "FUZZ #{@fuzz_n} peer #{peer.class.name.split("::").last}"
    fuzz_click(x, y)
  end

  def fuzz_click(x, y)
    warn "FUZZ #{@fuzz_n} click #{x},#{y}"
    fuzz_mouse(x, y, down: 1)
    fuzz_mouse(x, y, up: 1)
  end

  def fuzz_drag
    x1 = RNG.rand(app_width)
    y1 = RNG.rand(app_height)
    x2 = RNG.rand(app_width)
    y2 = RNG.rand(app_height)
    warn "FUZZ #{@fuzz_n} drag #{x1},#{y1} -> #{x2},#{y2}"
    fuzz_mouse(x1, y1, down: 1)
    4.times do |i|
      fuzz_mouse(x1 + (x2 - x1) * (i + 1) / 5, y1 + (y2 - y1) * (i + 1) / 5, held: 1)
    end
    fuzz_mouse(x2, y2, up: 1)
  end

  def fuzz_key(char, ext: nil, ctrl: false)
    warn "FUZZ #{@fuzz_n} key #{ctrl ? "ctrl+" : ""}#{ext || char.inspect}"
    mods = ctrl ? Clogs::UI::MOD_CTRL : 0
    [false, true].each do |up|
      on_key(Clogs::Canvas::KeyEvent.new(char: char, ext: ext, modifier: 0, modifiers: mods, up: up))
    end
  end

  def fuzz_mouse(x, y, down: 0, up: 0, held: 0)
    on_mouse(Clogs::Canvas::MouseEvent.new(
      x: x, y: y, area_width: app_width, area_height: app_height,
      down: down, up: up, count: 1, modifiers: 0, held: held
    ))
  end
end
Clogs::App.prepend(FuzzDriver)

load File.join(root, "hacketyhack.rb")
