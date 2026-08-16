# frozen_string_literal: true

require "wx"

module Clogs
  # The wx backend's stand-in for Clogs::UI.
  #
  # Clogs reaches into this module for a handful of enumerations that are part
  # of its own vocabulary rather than any one library's -- `UI::CAP_ROUND` in
  # the controls, `UI::MOD_CTRL` in the app, the brush constructors in
  # `Background`. The values here are wx's own where wx has one.
  module UI
    WINDING = Wx::WINDING_RULE
    ALTERNATE = Wx::ODDEVEN_RULE

    CAP_FLAT = Wx::CAP_BUTT
    CAP_ROUND = Wx::CAP_ROUND
    CAP_SQUARE = Wx::CAP_PROJECTING
    JOIN_MITER = Wx::JOIN_MITER
    JOIN_ROUND = Wx::JOIN_ROUND
    JOIN_BEVEL = Wx::JOIN_BEVEL

    # Keyboard modifiers as bits, numbered as the libui backend numbers them so
    # that App's `event.modifiers.anybits?(UI::MOD_CTRL)` tests are unchanged.
    MOD_CTRL = 1 << 0
    MOD_ALT = 1 << 1
    MOD_SHIFT = 1 << 2
    MOD_SUPER = 1 << 3

    BRUSH_SOLID = 0
    BRUSH_LINEAR_GRADIENT = 1
    BRUSH_RADIAL_GRADIENT = 2

    # A solid colour as Shoes hands it over: [r, g, b, a], 0-255. wx has a real
    # alpha channel, so unlike the FOX backend this is carried through to the
    # renderer untouched.
    Solid = Struct.new(:rgba) do
      def type
        BRUSH_SOLID
      end
    end

    # `background red..blue`. Materialised into a wx gradient brush at paint
    # time, when the graphics context that has to create it is in scope.
    Gradient = Struct.new(:kind, :from, :to, :stops) do
      def type
        kind
      end
    end

    class << self
      def solid_brush(color)
        Solid.new(normalize(color))
      end

      def gradient_brush(kind, from, to, stops)
        Gradient.new(kind, from, to, stops.map { |pos, color| [pos.to_f, normalize(color)] })
      end

      def normalize(color)
        return [0, 0, 0, 255] unless color

        r, g, b, a = color
        [r.to_i, g.to_i, b.to_i, (a || 255).to_i]
      end


      # These are built fresh every time on purpose.
      #
      # wx's GDI objects -- colours, pens, brushes, fonts -- are reference
      # counted handles onto shared data, and wxRuby hands out Ruby wrappers
      # that do not keep that data alive on their own. Holding one in a Ruby
      # cache and using it several frames later is a use-after-free: wx first
      # complains ("invalid ref data count" from DecRef) and then the process
      # dies inside set_pen or set_font. Hackety Hack, which paints far more
      # than the sample programs, hits it on its first frame.
      #
      # Constructing them per call is what wxRuby's own samples do, and the
      # objects are thin: see docs/backends.md for what it costs.
      # Colours reach here from several directions -- Shoes styles, Clogs'
      # own widget palette, a gradient stop -- and not all of them have been
      # through `normalize`. wx rejects a Colour built from floats or from
      # out-of-range channels, and then asserts "invalid colour" on every
      # later use of it, so normalising here rather than at each call site is
      # what keeps that from happening.
      def colour(rgba)
        r, g, b, a = normalize(rgba)
        (@colours ||= {})[[r, g, b, a]] ||=
          Wx::Colour.new(r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255), a.clamp(0, 255))
      end

      def brush(rgba)
        (@brushes ||= {})[normalize(rgba)] ||= Wx::Brush.new(colour(rgba))
      end

      def pen(rgba, width, cap, join, dashes)
        key = [normalize(rgba), width, cap, join, dashes]
        (@pens ||= {})[key] ||= begin
          p = Wx::Pen.new(colour(rgba), [width.round, 1].max)
          p.set_cap(cap)
          p.set_join(join)
          if dashes && !dashes.empty?
            p.set_style(Wx::PENSTYLE_USER_DASH)
            p.set_dashes(dashes.map { |d| [d.round, 1].max })
          end
          p
        end
      end

      # "Draw no outline" and "draw no fill".
      #
      # wx has stock objects for both, but they are owned by the application
      # and handing wxRuby's `Wx::TRANSPARENT_PEN` to a graphics context
      # segfaults on some paths -- Hackety Hack's first frame dies in
      # `set_pen` on it, while the smaller sample programs do not. Building
      # our own costs one object each and is stable.
      def no_pen
        @no_pen ||= Wx::Pen.new(colour([0, 0, 0, 0]), 1, Wx::PENSTYLE_TRANSPARENT)
      end

      def no_brush
        @no_brush ||= Wx::Brush.new(colour([0, 0, 0, 0]), Wx::BRUSHSTYLE_TRANSPARENT)
      end

      # Everything above belongs to the wx application that created it.
      def clear_cache
        @colours = nil
        @brushes = nil
        @pens = nil
        @no_pen = nil
        @no_brush = nil
      end
    end
  end
end
