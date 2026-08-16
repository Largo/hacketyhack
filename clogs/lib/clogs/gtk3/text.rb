# frozen_string_literal: true

require_relative "ui"

module Clogs
  # One styled run of text inside a paragraph.
  Run = Struct.new(:text, :size, :color, :family, :bold, :italic, :underline, :strike, :owner,
    keyword_init: true) do
    def style_key
      [size, color, family, bold, italic, underline, strike]
    end
  end

  # Pango, reached directly.
  #
  # This is the same text engine the libui backend uses -- libui's
  # uiAttributedString is a wrapper over Pango on Linux -- but reached without
  # the wrapper, which changes what is available. libui exposes no way to ask a
  # layout where it put anything, so Clogs does its own line breaking and the
  # coverage matrix lists hit testing as missing. Pango has `xy_to_index` and
  # `index_to_pos`, so on this backend the geometry is there for the asking.
  #
  # Clogs still does its own word layout, because that is shared code; what
  # this backend gets cheaply is correct measurement of styled runs.
  module Fonts
    class << self
      # One Pango context for measurement, with no window and no paint in
      # progress behind it -- Clogs measures during its own layout pass.
      def context
        @context ||= Pango::Context.new.tap do |ctx|
          ctx.font_map = PangoCairo::FontMap.default
        end
      end

      def clear
        @context = nil
        @descriptions = nil
      end

      # Pango parses a font description string; they are worth keeping, since
      # a Shoes document asks for the same handful thousands of times a frame.
      def description(family, size, bold, italic)
        key = [family, size, bold, italic]
        (@descriptions ||= {})[key] ||= begin
          desc = Pango::FontDescription.new
          desc.family = (family || Clogs.default_font_family).to_s
          desc.size = ((size || Clogs.default_font_size) * Pango::SCALE).to_i
          desc.weight = bold ? Pango::Weight::BOLD : Pango::Weight::NORMAL
          desc.style = italic ? Pango::Style::ITALIC : Pango::Style::NORMAL
          desc
        end
      end

      def layout_for(text, run, default_family, default_size)
        layout = Pango::Layout.new(context)
        layout.font_description = description(
          run&.family || default_family, run&.size || default_size,
          run&.bold ? true : false, run&.italic ? true : false
        )
        layout.text = text.to_s
        attrs = attributes(run)
        layout.attributes = attrs if attrs
        layout
      end

      # Underline and strikethrough are Pango attributes rather than font
      # properties, which is why `del()` renders with a line through it here
      # and does not on the libui backend: the attribute exists, libui's Ruby
      # binding just does not expose it.
      def attributes(run)
        return nil unless run&.underline || run&.strike

        list = Pango::AttrList.new
        list.insert(Pango::AttrUnderline.new(Pango::Underline::SINGLE)) if run.underline
        list.insert(Pango::AttrStrikethrough.new(true)) if run.strike
        list
      end

      def extent(text, run, default_family, default_size)
        layout = layout_for(text, run, default_family, default_size)
        layout.pixel_size
      end
    end
  end

  # A laid-out run of text.
  class TextBlock
    ALIGN_LEFT = 0
    ALIGN_CENTER = 1
    ALIGN_RIGHT = 2

    Piece = Struct.new(:text, :run, :layout, :x, :y, :width, :height)

    attr_reader :width, :height, :runs

    def initialize(runs, wrap_width, align: ALIGN_LEFT, default_family: nil, default_size: nil)
      @runs = runs
      @wrap_width = wrap_width.to_f
      @align = align
      @default_family = default_family || Clogs.default_font_family
      @default_size = default_size || Clogs.default_font_size
      build
    end

    def draw(painter, x, y)
      painter.draw_text(self, x, y)
    end

    # Pango places a layout by its top-left corner, which is the corner Clogs
    # works in, so there is no baseline arithmetic.
    def render(painter, ox, oy)
      cr = painter.cr
      @pieces.each do |piece|
        cr.save
        cr.set_source_rgba(*UI.rgba(piece.run.color || [0, 0, 0, 255]))
        cr.move_to(ox + piece.x, oy + piece.y)
        cr.show_pango_layout(piece.layout)
        cr.restore
      end
    end

    # Width of the first `n` characters, used to place text carets. Pango could
    # answer this from the layout directly; measuring the substring keeps the
    # behaviour identical to the other backends.
    def prefix_width(n)
      return 0.0 if n <= 0

      text = plain_text
      n = text.length if n > text.length
      @prefix_cache ||= {}
      @prefix_cache[n] ||= Fonts.extent(text[0, n], @runs.first, @default_family, @default_size)[0].to_f
    end

    def plain_text
      @plain_text ||= @runs.map { |r| r.text.to_s }.join
    end

    def free
      @pieces = []
    end

    private

    def build
      @pieces = []
      x = 0.0
      y = 0.0
      line_start = 0
      line_height = 0.0
      max_x = 0.0

      flush = lambda do
        align_line(line_start, x)
        max_x = [max_x, x].max
        y += line_height
        x = 0.0
        line_height = 0.0
        line_start = @pieces.size
      end

      @runs.each do |run|
        text = run.text.to_s
        next if text.empty?

        tokens = @wrap_width.positive? ? text.scan(/[^\s]+[ \t]*|[ \t]+|\n/) : [text]
        tokens.each do |token|
          if token == "\n"
            line_height = Fonts.extent("Hg", run, @default_family, @default_size)[1] if line_height.zero?
            flush.call
            next
          end

          layout = Fonts.layout_for(token, run, @default_family, @default_size)
          w, h = layout.pixel_size
          flush.call if x.positive? && @wrap_width.positive? && x + w > @wrap_width

          @pieces << Piece.new(token, run, layout, x, y, w, h)
          x += w
          line_height = [line_height, h].max
        end
      end
      flush.call

      @width = max_x
      @height = y
    end

    def align_line(from, line_width)
      return if @align == ALIGN_LEFT || @wrap_width <= 0

      shift = @align == ALIGN_CENTER ? (@wrap_width - line_width) / 2.0 : @wrap_width - line_width
      return if shift <= 0

      (from...@pieces.size).each { |i| @pieces[i].x += shift }
    end
  end
end
