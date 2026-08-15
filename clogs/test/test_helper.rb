# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "clogs"

module ClogsTest
  # Anything that measures text needs the display library initialised, which in
  # turn needs a display. On CI that is Xvfb; locally it is whatever you are
  # already using. Both backends boot through Clogs::App, which knows which one
  # is selected.
  def self.ui_available?
    return @ui_available unless @ui_available.nil?

    @ui_available = begin
      Clogs::App.ensure_libui!
      true
    rescue StandardError
      false
    end
  end

  # Run a Shoes app headlessly for a short time and return its stderr.
  # Used to prove the examples do not blow up.
  def self.run_app(path, ms: 700, env: {})
    require "open3"
    lib = File.expand_path("../lib", __dir__)
    _out, err, status = Open3.capture3(
      { "CLOGS_EXIT_AFTER_MS" => ms.to_s }.merge(env),
      RbConfig.ruby, "-I", lib, path
    )
    [err, status]
  end

  # Noise libui and Lacci emit that says nothing about our code.
  IGNORED_STDERR = [
    /dbind-WARNING/,
    /AT-SPI/,
    /No release found in CHANGELOG/,
    /Gtk-WARNING/,
    /^\s*$/
  ].freeze

  def self.meaningful_stderr(err)
    err.lines.reject { |line| IGNORED_STDERR.any? { |re| line =~ re } }
  end
end
