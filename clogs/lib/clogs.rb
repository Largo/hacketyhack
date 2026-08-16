# frozen_string_literal: true

require "shoes"

require_relative "clogs/log"

# Lacci expects a logging implementation to be plugged in before any Shoes
# object is built.
Shoes::Log.instance = Clogs::Log.new
Shoes::Log.configure_logger(ENV["SCARPE_DEBUG"] ? Shoes::Log::DEFAULT_DEBUG_LOG_CONFIG : Shoes::Log::DEFAULT_LOG_CONFIG)

require_relative "clogs/version"

module Clogs
  # Which display library draws the pixels.
  #
  # `libui` is the default and the one Clogs was written against. The other two
  # exist because the three libraries fail in different directions: libui has
  # Cairo's compositing and transforms but no way to blit a bitmap, FOX blits
  # bitmaps but has neither a transform stack nor an alpha channel, and wx has
  # both at the price of a much larger dependency. Select one with
  # CLOGS_BACKEND, and see docs/backends.md for what each trade costs.
  BACKENDS = %w[libui fox wx].freeze
  DEFAULT_BACKEND = "libui"

  def self.backend
    @backend ||= begin
      name = (ENV["CLOGS_BACKEND"] || DEFAULT_BACKEND).downcase
      unless BACKENDS.include?(name)
        raise ArgumentError, "Unknown CLOGS_BACKEND #{name.inspect}, expected one of #{BACKENDS.join(", ")}"
      end

      name
    end
  end

  def self.libui?
    backend == "libui"
  end

  def self.fox?
    backend == "fox"
  end

  def self.wx?
    backend == "wx"
  end
end

# A backend supplies the drawing surface, the event source, text measurement
# and the dialogs. Everything else -- layout, the drawable tree, the widgets
# Clogs paints for itself -- is shared between them.
#
# libui's files predate the split and sit at the top of the tree; the others
# live in a directory named for themselves.
if Clogs.libui?
  require_relative "clogs/ui"
  require_relative "clogs/painter"
  require_relative "clogs/text"
  require_relative "clogs/canvas"
  require_relative "clogs/dialogs"
else
  require_relative "clogs/#{Clogs.backend}/ui"
  require_relative "clogs/#{Clogs.backend}/painter"
  require_relative "clogs/#{Clogs.backend}/text"
end
require_relative "clogs/style"
require_relative "clogs/paragraph"
require_relative "clogs/clipboard"
require_relative "clogs/drawable"

# Clogs: Shoes, worn over libui.
#
# Shoes is _why the lucky stiff's tiny Ruby GUI toolkit. Clogs implements the
# Shoes drawing and layout model on top of libui, a small cross-platform native
# widget library, so Shoes programs run on plain CRuby -- no browser engine, no
# JVM, one small native dependency.
#
# The Shoes API itself comes from Lacci, the display-independent half of
# Scarpe. Clogs is a Lacci *display service*: Lacci owns the DSL and the
# drawable tree, Clogs owns the pixels. Run an app with:
#
#     SCARPE_DISPLAY_SERVICE=clogs ruby my_app.rb
#
# or simply `require "clogs"` before `Shoes.app`.
module Clogs
  class << self
    # libui takes a font *family* name and resolves it per platform.
    def default_font_family
      @default_font_family ||= case RUBY_PLATFORM
      when /darwin/ then "Helvetica"
      when /mingw|mswin/ then "Segoe UI"
      else "Sans"
      end
    end

    attr_writer :default_font_family

    def default_font_size
      @default_font_size ||= 14
    end

    attr_writer :default_font_size

    def monospace_font_family
      @monospace_font_family ||= case RUBY_PLATFORM
      when /darwin/ then "Monaco"
      when /mingw|mswin/ then "Consolas"
      else "Monospace"
      end
    end

    attr_writer :monospace_font_family
  end
end

require_relative "clogs/drawables/slot"
require_relative "clogs/drawables/text"
require_relative "clogs/drawables/shapes"
require_relative "clogs/drawables/controls"
require_relative "clogs/drawables/image"
require_relative "clogs/drawables/misc"
require_relative "clogs/app"

# App and Image are the two classes that are part backend: the rest of each is
# shared, so a backend reopens them rather than replacing the files.
unless Clogs.libui?
  require_relative "clogs/#{Clogs.backend}/app"
  require_relative "clogs/#{Clogs.backend}/image"
end

require_relative "clogs/display_service"
require_relative "clogs/lacci_compat"

Shoes::DisplayService.set_display_service_class(Clogs::DisplayService)

# Clogs windows are cheap enough to nest: a Shoes.app called from inside a
# running Shoes.app gets its own libui window serviced by the same event
# loop, rather than raising Shoes::Errors::TooManyInstancesError.
Shoes::FEATURES << :multi_app unless Shoes::FEATURES.include?(:multi_app)

# Lacci 0.5.0's builtins (`ask`, `confirm`, `ask_open_file`, ...) always return
# nil: there is no channel for a display service to answer. Shoes programs very
# much expect an answer, so Clogs supplies one. Newer Lacci versions have their
# own response mechanism, and we leave those alone.
unless Shoes::DisplayService.respond_to?(:consume_builtin_response)
  module Shoes::Builtins
    def shoes_builtin(cmd_name, *args)
      # shoes_builtin is mixed into Kernel, so `self` here can be a
      # Shoes::App, any other drawable, or (called from top-level code) plain
      # `main`. Route the dialog to whichever app it actually belongs to, so
      # a nested Shoes.app's alert() doesn't also pop up in every other open
      # window -- falling back to the most recently created app for callers
      # that aren't part of any drawable tree.
      target_app = if is_a?(Shoes::App)
        self
      elsif is_a?(Shoes::Drawable)
        app
      end
      target_app ||= Shoes.APPS.last

      if target_app
        Clogs::App.builtin_response = nil
        Shoes::DisplayService.dispatch_event("builtin", target_app.linkable_id, cmd_name, args)
        Clogs::App.builtin_response
      else
        # No Shoes.app has ever been created -- Hackety Hack's own Guessing
        # Game sample is a bare ask/alert loop with no Shoes.app in sight.
        # There's no app peer to dispatch the "builtin" event to, so show
        # the dialog directly instead of silently dropping it.
        Clogs::App.ensure_libui!
        Clogs::App.run_builtin(cmd_name, args, nil)
      end
    end
  end
end
