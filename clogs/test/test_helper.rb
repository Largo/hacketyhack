# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "clogs"

module ClogsTest
  # Anything that measures text needs the display library initialised, which
  # in turn needs a display. On CI that is Xvfb; locally it is whatever you are
  # already using.
  #
  # This probes the capability rather than the display, because the backends
  # differ on when they have it. libui, FOX, Qt and GTK3 can measure a string
  # as soon as they have a display. wx cannot build a font until its
  # application object is fully initialised, and NAppGUI cannot until
  # osmain_imp has started its SDK -- both of which happen only inside the
  # main loop. On those two these tests skip, and the sample suite covers that
  # ground instead.
  #
  # Measurement has to be judged by its answer rather than by whether it
  # raised: the NAppGUI backend reports a zero extent before its SDK is up
  # instead of failing, which would otherwise read as a working measurement.
  def self.ui_available?
    return @ui_available unless @ui_available.nil?

    @ui_available = begin
      Clogs::App.ensure_backend!
      block = Clogs::TextBlock.new([Clogs::Run.new(text: "Hg", size: 12)], -1)
      measured = block.width.to_f.positive? && block.height.to_f.positive?
      block.free
      measured
    rescue StandardError, NameError
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
