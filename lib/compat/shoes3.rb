# frozen_string_literal: true

# Shoes 3 compatibility for Hackety Hack.
#
# Hackety Hack was written against Shoes 3 ("Policeman"). Clogs implements the
# Shoes API as defined by Lacci, which is close but not identical: Lacci is a
# deliberate re-specification of Shoes and has not yet grown some of Shoes 3's
# corners.
#
# This file fills those gaps for the parts Hackety Hack relies on. Everything
# here is additive -- a method is only defined if the underlying Shoes does not
# already provide it -- so as Lacci catches up these shims quietly stop being
# used.

require "clogs"

# `require "hpricot"` in a user program should find our Nokogiri-backed shim.
$LOAD_PATH.unshift(File.expand_path("../shims", __dir__))

class Shoes
  FONTS = [] unless defined?(FONTS)

  class << self
    # Shoes 3 took its options as a trailing hash: `Shoes.app :width => 300`.
    alias_method :__shoes3_app, :app
    def app(opts = {}, **kwargs, &block)
      __shoes3_app(**opts.transform_keys(&:to_sym).merge(kwargs), &block)
    end

    # Shoes 3 opened its bundled manual in a new window. There is no bundled
    # manual here; point at the online one instead of failing.
    unless method_defined?(:show_manual) || respond_to?(:show_manual)
      def show_manual
        Shoes::Compat.open_url("https://github.com/scarpe-team/scarpe/wiki")
      end
    end
  end

  # Helpers that do not belong to any one drawable.
  module Compat
    class << self
      def finish_blocks
        @finish_blocks ||= []
      end

      def run_finish_blocks
        blocks = finish_blocks.dup
        finish_blocks.clear
        blocks.each do |block|
          block.call
        rescue StandardError => e
          warn "Hackety Hack: error while shutting down: #{e.class}: #{e.message}"
        end
      end
    end

    module_function

    def open_url(url)
      opener = case RUBY_PLATFORM
      when /darwin/ then "open"
      when /mingw|mswin/ then "start"
      else "xdg-open"
      end
      system(opener, url.to_s, out: File::NULL, err: File::NULL)
    end
  end
end

class Shoes::App
  # Shoes 3 addressed the current slot as `app.slot`.
  def slot
    current_slot
  end

  # `close` ends the app, as the Quit tab expects.
  def close
    destroy
  end unless method_defined?(:close)

  # Shoes 3 ran slot blocks with `self` set to the slot, but fell back to the
  # object the block was written in for anything the slot did not understand.
  # Lacci instance_evals slot blocks into the app and raises NameError instead,
  # which breaks Hackety Hack's tab classes -- they define `content` on
  # themselves and call it from inside a slot block.
  #
  # Remember the receiver each block was written against, and consult it before
  # giving up.
  alias_method :__shoes3_with_slot, :with_slot
  def with_slot(slot, &block)
    outer = begin
      block&.binding&.receiver
    rescue StandardError
      nil
    end
    (@__shoes3_outer_selves ||= []).push(outer)
    __shoes3_with_slot(slot, &block)
  ensure
    @__shoes3_outer_selves&.pop
  end

  alias_method :__shoes3_method_missing, :method_missing
  def method_missing(name, *args, **kwargs, &block)
    __shoes3_method_missing(name, *args, **kwargs, &block)
  rescue NameError, NoMethodError => e
    outer = Array(@__shoes3_outer_selves).reverse.find do |candidate|
      candidate && !candidate.equal?(self) && candidate.respond_to?(name, true)
    end
    raise e unless outer

    outer.send(name, *args, **kwargs, &block)
  end

  # Shoes 3's class-level styling: `style(Shoes::Link, stroke: "#377")`.
  # Lacci keeps the same idea in drawable_default_styles.
  def style(klass = nil, styles = {})
    return super() if klass.nil?

    Shoes::Drawable.drawable_default_styles[klass].merge!(styles)
  end
end

class Shoes::Drawable
  # Shoes 3 predates keyword arguments: styles were passed as a trailing hash,
  # `image(path, :bottom => 0)`. Lacci wants real keywords, so move a trailing
  # hash across before it reaches the argument checker.
  module HashStyleArgs
    def initialize(*args, **kwargs, &block)
      kwargs = args.pop.transform_keys(&:to_sym).merge(kwargs) if args.last.is_a?(Hash)
      super(*args, **kwargs, &block)
    end
  end
  prepend HashStyleArgs

  # Shoes 3 could position a drawable from the right or bottom edge of its
  # slot. Lacci has no such styles; register them so they are carried through
  # to the display service, where Clogs' layout understands them.
  shoes_styles :bottom, :right unless shoes_style_name?(:bottom)

  # Shoes 3's `start` and `finish` fire when a slot is first drawn and when it
  # goes away. Lacci has no slot lifecycle events yet, so `finish` blocks run
  # at process exit -- which is what Hackety Hack uses it for (saving prefs).
  def finish(&block)
    Shoes::Compat.finish_blocks << block if block
    self
  end unless method_defined?(:finish)

  def start(&block)
    block&.call(self)
    self
  end unless method_defined?(:start)

  # Shoes 3 attaches mouse handlers straight to a drawable and returns the
  # drawable, so they chain:
  #
  #   image(path).hover { ... }.leave { ... }.click { ... }
  #
  # In Lacci the bare `hover`/`click` methods instead create a free-standing
  # subscription covering the whole app, which is still what we want when they
  # are called on the app itself.
  %i[hover leave click release].each do |event|
    define_method(event) do |&block|
      return method_missing(event, &block) if is_a?(Shoes::App)
      return self unless block

      # Subscribe directly rather than via bind_self_event: Lacci only lets a
      # drawable bind events its own class declares, and most drawables do not
      # declare `click` even though Shoes 3 let you click anything.
      Shoes::DisplayService.subscribe_to_event(event.to_s, linkable_id) do |*args|
        block.arity.zero? ? block.call : block.call(self, *args)
      end
      self
    end
  end

  # Shoes 3 lets any drawable be toggled or removed.
  def toggle
    self.hidden = !hidden
  end unless method_defined?(:toggle)

  def hide
    self.hidden = true
  end unless method_defined?(:hide)

  def show
    self.hidden = false
  end unless method_defined?(:show)
end

# Shoes 3's `image(width, height) { ... }` made an off-screen canvas to draw
# into. Clogs has no off-screen surfaces (libui cannot blit one back), so treat
# it as an empty image of that size: the app keeps running and the space is
# reserved, rather than the whole program failing to start.
class Shoes::Image
  module Shoes3Canvas
    def initialize(*args, **kwargs, &block)
      if args.length == 2 && args.all? { |a| a.is_a?(Numeric) }
        width, height = args
        args = [nil]
        kwargs = kwargs.merge(width: width, height: height)
      end
      super(*args, **kwargs, &block)
    end
  end
  prepend Shoes3Canvas
end

# Shoes 3 let you reposition any drawable after creating it.
class Shoes::Drawable
  def move(new_left, new_top)
    self.left = new_left
    self.top = new_top
    self
  end unless method_defined?(:move)

  def displace(dx, dy)
    self.left = left.to_i + dx
    self.top = top.to_i + dy
    self
  end unless method_defined?(:displace)
end

# Lacci validates arc angles as non-negative, but Shoes 3 programs happily pass
# negative radians to sweep anticlockwise. Normalise into [0, 2pi).
class Shoes::Arc
  module Shoes3Angles
    TWO_PI = Math::PI * 2

    def initialize(*args, **kwargs, &block)
      args = args.each_with_index.map do |value, index|
        index >= 4 && value.is_a?(Numeric) && value.negative? ? value % TWO_PI : value
      end
      %i[angle1 angle2].each do |key|
        kwargs[key] %= TWO_PI if kwargs[key].is_a?(Numeric) && kwargs[key].negative?
      end
      super(*args, **kwargs, &block)
    end
  end
  prepend Shoes3Angles
end

# In Shoes 3, `oval(left, top, width, height)` gave an axis-aligned ellipse.
# Lacci reads the third positional argument as a radius, so a four-argument
# call comes out twice as wide as intended.
class Shoes::Oval
  module Shoes3PositionalArgs
    def initialize(*args, **kwargs, &block)
      if args.length == 4 && !kwargs.key?(:width) && !kwargs.key?(:height)
        left, top, width, height = args
        args = [left, top]
        kwargs = kwargs.merge(width: width, height: height)
      end
      super(*args, **kwargs, &block)
    end
  end
  prepend Shoes3PositionalArgs
end

module Kernel
  # Shoes 3's top-level `window` is how Hackety Hack starts. With no app
  # running it opens the main one; inside a running app Shoes 3 would open a
  # second window, which Clogs does not support yet -- see the coverage matrix.
  unless method_defined?(:window)
    def window(opts = {}, &block)
      Shoes.app(**opts.transform_keys(&:to_sym), &block)
    end
  end

  # Shoes 3's modal `dialog`. Clogs is single-window, so this renders the
  # dialog's contents inside the current app instead of in a new window.
  unless method_defined?(:dialog)
    def dialog(opts = {}, &block)
      app = Shoes::App.instance if Shoes::App.respond_to?(:instance)
      app ||= Shoes.APPS&.last
      return unless app

      app.instance_eval do
        current_slot.stack(top: 0, left: 0, width: 1.0, height: 1.0, &block)
      end
    end
  end
end

# Hackety Hack's turtle graphics are part of the environment user programs run
# in, so make `Turtle` available to anything using this compatibility layer.
begin
  require "lib/art/turtle"
rescue LoadError
  # Running Clogs without the Hackety Hack tree; that is fine.
end

# Slots that registered a `finish` block expect it to run on shutdown.
at_exit { Shoes::Compat.run_finish_blocks }
