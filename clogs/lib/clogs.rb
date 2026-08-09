# frozen_string_literal: true

require "shoes"

require_relative "clogs/log"

# Lacci expects a logging implementation to be plugged in before any Shoes
# object is built.
Shoes::Log.instance = Clogs::Log.new
Shoes::Log.configure_logger(ENV["SCARPE_DEBUG"] ? Shoes::Log::DEFAULT_DEBUG_LOG_CONFIG : Shoes::Log::DEFAULT_LOG_CONFIG)

require_relative "clogs/version"
require_relative "clogs/ui"
require_relative "clogs/style"
require_relative "clogs/painter"
require_relative "clogs/text"
require_relative "clogs/paragraph"
require_relative "clogs/canvas"
require_relative "clogs/clipboard"
require_relative "clogs/dialogs"
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
require_relative "clogs/display_service"

Shoes::DisplayService.set_display_service_class(Clogs::DisplayService)

# Lacci 0.5.0's builtins (`ask`, `confirm`, `ask_open_file`, ...) always return
# nil: there is no channel for a display service to answer. Shoes programs very
# much expect an answer, so Clogs supplies one. Newer Lacci versions have their
# own response mechanism, and we leave those alone.
unless Shoes::DisplayService.respond_to?(:consume_builtin_response)
  module Shoes::Builtins
    def shoes_builtin(cmd_name, *args)
      Clogs::App.builtin_response = nil
      Shoes::DisplayService.dispatch_event("builtin", nil, cmd_name, args)
      Clogs::App.builtin_response
    end
  end
end
