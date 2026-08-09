# frozen_string_literal: true

require "libui"

module Clogs
  # Thin, hand-rolled conveniences over the raw libui FFI bindings.
  #
  # Two things make raw libui painful from Ruby and both are handled here:
  #
  # 1. Every callback handed to C must be a Fiddle::Closure that outlives the
  #    C-side registration. Ruby will happily collect one that is still
  #    installed, and libui will then jump into freed memory. {UI.callback}
  #    keeps a permanent reference.
  # 2. Structs must be malloc'd and marked with a free function, and several of
  #    them (brushes, stroke params, font descriptors) are needed on every
  #    single paint. Allocating them per-paint is measurable, so the hot ones
  #    are pooled.
  module UI
    L = ::LibUI

    # Fill modes
    WINDING = 0
    ALTERNATE = 1

    # Line caps / joins
    CAP_FLAT = 0
    CAP_ROUND = 1
    CAP_SQUARE = 2
    JOIN_MITER = 0
    JOIN_ROUND = 1
    JOIN_BEVEL = 2

    BRUSH_SOLID = 0
    BRUSH_LINEAR_GRADIENT = 1
    BRUSH_RADIAL_GRADIENT = 2

    # Text weights/italics/stretches we actually use
    WEIGHT_NORMAL = 400
    WEIGHT_BOLD = 700
    ITALIC_NORMAL = 0
    ITALIC_ITALIC = 1
    STRETCH_NORMAL = 4

    # uiExtKey values, from ui.h. libui reports these separately from `Key`.
    EXT_KEYS = {
      1 => :escape, 2 => :insert, 3 => :delete, 4 => :home, 5 => :end,
      6 => :page_up, 7 => :page_down, 8 => :up, 9 => :down, 10 => :left,
      11 => :right, 12 => :f1, 13 => :f2, 14 => :f3, 15 => :f4, 16 => :f5,
      17 => :f6, 18 => :f7, 19 => :f8, 20 => :f9, 21 => :f10, 22 => :f11,
      23 => :f12
    }.freeze

    MOD_CTRL = 1 << 0
    MOD_ALT = 1 << 1
    MOD_SHIFT = 1 << 2
    MOD_SUPER = 1 << 3

    class << self
      # Closures handed to C live forever. There are a bounded number of them
      # (a handful per window plus one per timer) so this does not grow without
      # bound in practice.
      def callback(return_type, arg_types, &block)
        closure = Fiddle::Closure::BlockCaller.new(return_type, arg_types, &block)
        (@callbacks ||= []) << closure
        closure
      end

      def malloc(struct_class)
        s = struct_class.malloc
        s.to_ptr.free = Fiddle::RUBY_FREE
        s
      end

      # A solid uiDrawBrush. Colors arrive as Shoes [r, g, b, a] 0-255 arrays.
      def solid_brush(color)
        b = malloc(L::FFI::DrawBrush)
        b.Type = BRUSH_SOLID
        r, g, bl, a = color
        b.R = r / 255.0
        b.G = g / 255.0
        b.B = bl / 255.0
        b.A = (a || 255) / 255.0
        b
      end

      # A linear or radial gradient brush. `stops` is [[pos, [r,g,b,a]], ...].
      #
      # The Stops array must stay alive as long as the brush does, so it is
      # stashed on the brush object; Ruby's GC then keeps them together.
      def gradient_brush(type, from, to, stops, outer_radius: 0)
        b = malloc(L::FFI::DrawBrush)
        b.Type = type
        b.X0, b.Y0 = from
        b.X1, b.Y1 = to
        b.OuterRadius = outer_radius

        buf = Fiddle::Pointer.malloc(stops.size * 40, Fiddle::RUBY_FREE)
        stops.each_with_index do |(pos, color), i|
          r, g, bl, a = color
          buf[i * 40, 40] = [pos, r / 255.0, g / 255.0, bl / 255.0, (a || 255) / 255.0].pack("d5")
        end
        b.Stops = buf
        b.NumStops = stops.size
        b.instance_variable_set(:@clogs_stops, buf)
        b
      end

      def stroke_params(thickness, cap: CAP_FLAT, join: JOIN_MITER, dashes: nil)
        sp = malloc(L::FFI::DrawStrokeParams)
        sp.Cap = cap
        sp.Join = join
        sp.Thickness = thickness.to_f
        sp.MiterLimit = 10.0
        if dashes && !dashes.empty?
          buf = Fiddle::Pointer.malloc(dashes.size * 8, Fiddle::RUBY_FREE)
          buf[0, dashes.size * 8] = dashes.map(&:to_f).pack("d*")
          sp.Dashes = buf
          sp.NumDashes = dashes.size
          sp.instance_variable_set(:@clogs_dashes, buf)
        else
          sp.NumDashes = 0
        end
        sp.DashPhase = 0.0
        sp
      end

      def font_descriptor(family, size, weight: WEIGHT_NORMAL, italic: ITALIC_NORMAL)
        fd = malloc(L::FFI::FontDescriptor)
        fd.Family = family
        fd.Size = size.to_f
        fd.Weight = weight
        fd.Italic = italic
        fd.Stretch = STRETCH_NORMAL
        # Fiddle copies the string into the struct but does not own it; keep the
        # Ruby string alive so the char* stays valid.
        fd.instance_variable_set(:@clogs_family, family)
        fd
      end

      # uiDrawTextLayoutExtents writes through two double pointers.
      def text_extents(layout)
        w = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
        h = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
        L.draw_text_layout_extents(layout, w, h)
        [w[0, 8].unpack1("d"), h[0, 8].unpack1("d")]
      end

      # True if this libui build can blit a uiImage into a draw context.
      # Stock libui-ng cannot; see docs/libui_shoes_coverage.md.
      def draw_image?
        return @draw_image unless @draw_image.nil?

        @draw_image = L.respond_to?(:draw_image)
      end
    end
  end
end
