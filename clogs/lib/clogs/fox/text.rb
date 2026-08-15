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

  # FOX asks for a font once and then answers metric questions about it very
  # cheaply, but building one is a round trip to the X server. Shoes programs
  # ask for the same handful of fonts thousands of times a frame, so they are
  # cached for the life of the process.
  module Fonts
    # Clogs' platform-neutral family names, mapped onto the aliases FOX's font
    # matcher understands.
    ALIASES = {
      "Sans" => "Helvetica",
      "sans-serif" => "Helvetica",
      "Monospace" => "Courier",
      "monospace" => "Courier",
      "Serif" => "Times",
      "serif" => "Times"
    }.freeze

    class << self
      def cache
        @cache ||= {}
      end

      def clear
        @cache = {}
      end

      def for(family, size, bold: false, italic: false)
        family = (family || Clogs.default_font_family).to_s
        family = ALIASES.fetch(family, family)
        size = (size || Clogs.default_font_size).to_i
        cache[[family, size, bold, italic]] ||= begin
          font = Fox::FXFont.new(
            Fox::FXApp.instance, family, size,
            bold ? Fox::FONTWEIGHT_BOLD : Fox::FONTWEIGHT_NORMAL,
            italic ? Fox::FONTSLANT_ITALIC : Fox::FONTSLANT_REGULAR
          )
          font.create
          font
        end
      end
    end
  end

  # A laid-out run of text.
  #
  # The libui backend hands an attributed string to Pango and gets a wrapped,
  # measured layout back. FOX has no such thing: `FXFont` answers the width of
  # a string and `FXDC#drawText` puts one on the screen, and that is the whole
  # of it. It is enough, because Clogs' Paragraph already does its own word
  # layout -- every TextBlock in Clogs is built with a wrap width of -1 and
  # holds a single line. Wrapping is still implemented here for a caller that
  # asks for it.
  #
  # Doing the drawing a run at a time also buys two things Pango was hiding:
  # underline and strikethrough are drawn rather than requested, so `del()`
  # renders with a line through it instead of as plain text.
  class TextBlock
    ALIGN_LEFT = 0
    ALIGN_CENTER = 1
    ALIGN_RIGHT = 2

    Piece = Struct.new(:text, :run, :font, :x, :y, :width, :height, :ascent)

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

    # Called back by the painter once the origin is in device coordinates.
    def render(painter, dx, dy)
      dc = painter.dc
      @pieces.each do |piece|
        color = painter.resolve(piece.run.color || [0, 0, 0, 255])
        next unless color

        dc.foreground = color
        dc.setFont(piece.font)
        x = (dx + piece.x).round
        baseline = (dy + piece.y + piece.ascent).round
        dc.drawText(x, baseline, piece.text)

        if piece.run.underline
          dc.fillRectangle(x, baseline + 2, piece.width.round, 1)
        end
        if piece.run.strike
          dc.fillRectangle(x, (baseline - piece.ascent / 3.0).round, piece.width.round, 1)
        end
      end
    end

    # Width of the first `n` characters, used to place text carets.
    def prefix_width(n)
      return 0.0 if n <= 0

      text = plain_text
      n = text.length if n > text.length
      @prefix_cache ||= {}
      @prefix_cache[n] ||= font_for(@runs.first).getTextWidth(text[0, n]).to_f
    end

    def plain_text
      @plain_text ||= @runs.map { |r| r.text.to_s }.join
    end

    # Nothing outside the Ruby heap is held: the fonts belong to the cache.
    def free
      @pieces = []
    end

    private

    def font_for(run)
      Fonts.for(
        run&.family || @default_family,
        run&.size || @default_size,
        bold: run&.bold ? true : false,
        italic: run&.italic ? true : false
      )
    end

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

        font = font_for(run)
        height = font.fontHeight.to_f
        ascent = font.fontAscent.to_f

        tokens = @wrap_width.positive? ? text.scan(/[^\s]+[ \t]*|[ \t]+|\n/) : [text]
        tokens.each do |token|
          if token == "\n"
            line_height = height if line_height.zero?
            flush.call
            next
          end

          w = font.getTextWidth(token).to_f
          flush.call if x.positive? && @wrap_width.positive? && x + w > @wrap_width

          @pieces << Piece.new(token, run, font, x, y, w, height, ascent)
          x += w
          line_height = [line_height, height].max
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
