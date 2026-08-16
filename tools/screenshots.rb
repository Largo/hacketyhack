#!/usr/bin/env ruby
# frozen_string_literal: true

# Drive the Hackety Hack IDE and photograph it, one image per pane.
#
#   SHOT_DIR=tmp/shots ruby -Iclogs/lib -I. tools/screenshots.rb
#   SHOT_DIR=tmp/shots CLOGS_BACKEND=wx ruby -Iclogs/lib -I. tools/screenshots.rb
#
# On a headless machine put xvfb-run in front of it. The shots are taken with
# ImageMagick's `import`, the same way Clogs' own CLOGS_SCREENSHOT hook does.
#
# The scenes are driven through the app's own `opentab` rather than by clicking
# at coordinates, so this keeps working when the sidebar moves.
#
# The intro has to be skipped before the app is built -- Hackety Hack has a
# preference for exactly that, which is also how the fuzzer gets past it -- so
# the splash is photographed by a separate run:
#
#   SHOT_SPLASH=1 ruby -Iclogs/lib -I. tools/screenshots.rb

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(root)
$LOAD_PATH.unshift(File.join(root, "clogs", "lib"))

require "fileutils"
require "lib/compat/shoes3"

SHOT_DIR = File.expand_path(ENV["SHOT_DIR"] || File.join(root, "tmp", "shots"))
FileUtils.mkdir_p(SHOT_DIR)
BACKEND = Clogs.backend

# How long the splash gets before the first tab shot, and how long each pane
# gets to settle -- the Home tab loads its script list, and the artwork has to
# be decoded before it can appear.
SPLASH_MS = (ENV["SHOT_SPLASH_MS"] || "2600").to_i
SETTLE_MS = (ENV["SHOT_SETTLE_MS"] || "900").to_i

SPLASH_ONLY = ENV["SHOT_SPLASH"] == "1"
# About draws over everything and stays until its OK is clicked, so it goes
# last rather than hiding every pane after it.
SCENES = SPLASH_ONLY ? [] : %i[Home Lessons Help Cheat Prefs Editor About].freeze

# The intro can only be skipped before the window is built.
unless SPLASH_ONLY
  require "app/boot"
  HH::PREFS["skip_intro"] = true
end

# Answer anything modal rather than stopping forever in front of it: an
# unattended run has nobody to click OK, and on wx an unanswered dialog holds
# the whole event loop.
module Clogs::Dialogs
  class << self
    def alert(*) = nil
    def confirm(*) = false
    def ask(*) = nil
    def open_file(*) = nil
    def save_file(*) = nil
    def open_folder(*) = nil
  end
end

module ScreenshotDriver
  def run
    @shot_queue = SCENES.dup
    if SPLASH_ONLY
      # The splash animates itself into place; give it time to arrive.
      add_timer(SPLASH_MS, repeat: false) do
        shoot("splash")
        quit
      end
    else
      # The first pane is already open; the delay is for its artwork to decode.
      add_timer(SETTLE_MS, repeat: false) { next_scene }
    end
    super
  end

  def next_scene
    tab = @shot_queue.shift
    unless tab
      warn "screenshots: wrote #{SCENES.length} images to #{SHOT_DIR}"
      quit
      return
    end

    begin
      opentab tab
    rescue StandardError => e
      warn "screenshots: could not open #{tab}: #{e.class}: #{e.message}"
    end
    add_timer(SETTLE_MS, repeat: false) do
      shoot(tab.to_s.downcase)
      next_scene
    end
  end

  # `opentab` lives on the Shoes app, not on the display-side peer this module
  # is mixed into.
  def opentab(tab)
    shoes_app = Shoes.APPS.last
    shoes_app.opentab(tab)
    redraw!
  end

  # Clogs' own screenshot hook photographs the whole root window, which on a
  # headless server is mostly empty desk. Crop to the app.
  def shoot(name)
    path = File.join(SHOT_DIR, "#{BACKEND}-#{name}.png")
    system("import", "-window", "root", "-crop", "#{app_width}x#{app_height}+0+0",
      "+repage", path, err: File::NULL)
    warn "screenshots: #{path}"
  end
end
Clogs::App.prepend(ScreenshotDriver)

load File.join(root, "hacketyhack.rb")
