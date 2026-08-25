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

  # Fonts, cached for the life of the wx application.
  #
  # Building one is a round trip to the display server and a Shoes document
  # asks for the same handful thousands of times a frame, so this matters more
  # than it looks: without the cache a page of forty styled paragraphs costs
  # over a second a frame instead of a few milliseconds.
  module Fonts
    # Clogs' platform-neutral family names as wx font families, so that the
    # platform's own default sans, serif and monospace fonts are used rather
    # than a face name that may not exist.
    FAMILIES = {
      "Sans" => Wx::FONTFAMILY_SWISS,
      "sans-serif" => Wx::FONTFAMILY_SWISS,
      "Monospace" => Wx::FONTFAMILY_TELETYPE,
      "monospace" => Wx::FONTFAMILY_TELETYPE,
      "Serif" => Wx::FONTFAMILY_ROMAN,
      "serif" => Wx::FONTFAMILY_ROMAN
    }.freeze

    class << self
      def cache
        @cache ||= {}
      end

      def clear
        @cache = {}
        @measuring = nil
      end

      def for(family, size, bold: false, italic: false, underline: false, strike: false)
        family = (family || Clogs.default_font_family).to_s
        size = (size || Clogs.default_font_size).to_i
        cache[[family, size, bold, italic, underline, strike]] ||= build(family, size, bold, italic, underline, strike)
      end

      def build(family, size, bold, italic, underline, strike)
        generic = FAMILIES[family]
        font = Wx::Font.new(
          size,
          generic || Wx::FONTFAMILY_DEFAULT,
          italic ? Wx::FONTSTYLE_ITALIC : Wx::FONTSTYLE_NORMAL,
          bold ? Wx::FONTWEIGHT_BOLD : Wx::FONTWEIGHT_NORMAL,
          underline,
          generic ? "" : family
        )
        # wx draws these itself, which is why del() has a line through it on
        # this backend and not on libui.
        font.set_strikethrough(true) if strike
        font
      end

      # A context that can measure text without a window or a paint in
      # progress. Clogs measures during layout, which happens inside the draw
      # callback but with no graphics context in hand.
      def measuring_context
        @measuring ||= Wx::GraphicsRenderer.get_default_renderer.create_measuring_context
      end

      # The colour is irrelevant to a measurement, but set_font insists on
      # one. It must not be a wx stock colour: those are owned by the
      # application and reading one back asserts "invalid colour" once the
      # measuring context has taken a reference to it.
      def extent(text, font)
        ctx = measuring_context
        ctx.set_font(font, UI.colour([0, 0, 0, 255]))
        w, h, = ctx.get_text_extent(text)
        [w, h]
      end
    end
  end

  # A laid-out run of text.
  #
  # Clogs' Paragraph already does its own word layout -- every TextBlock it
  # builds has a wrap width of -1 and holds a single line -- so this only has
  # to measure and place runs. Wrapping is implemented anyway for a caller that
  # asks for it.
  class TextBlock
    ALIGN_LEFT = 0
    ALIGN_CENTER = 1
    ALIGN_RIGHT = 2

    Piece = Struct.new(:text, :run, :font, :x, :y, :width, :height)

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

    # Called back by the painter. wx places text by its top-left corner, which
    # is the corner Clogs works in, so no baseline arithmetic is needed.
    def render(painter, ox, oy)
      gc = painter.gc
      @pieces.each do |piece|
        gc.set_font(piece.font, UI.colour(piece.run.color || [0, 0, 0, 255]))
        gc.draw_text(piece.text, ox + piece.x, oy + piece.y)
      end
    end

    # Width of the first `n` characters, used to place text carets.
    def prefix_width(n)
      return 0.0 if n <= 0

      text = plain_text
      n = text.length if n > text.length
      @prefix_cache ||= {}
      @prefix_cache[n] ||= Fonts.extent(text[0, n], font_for(@runs.first))[0].to_f
    end

    def plain_text
      @plain_text ||= @runs.map { |r| r.text.to_s }.join
    end

    # Fonts belong to the cache; nothing here is owned.
    def free
      @pieces = []
    end

    private

    def font_for(run)
      Fonts.for(
        run&.family || @default_family,
        run&.size || @default_size,
        bold: run&.bold ? true : false,
        italic: run&.italic ? true : false,
        underline: run&.underline ? true : false,
        strike: run&.strike ? true : false
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
        tokens = @wrap_width.positive? ? text.scan(/[^\s]+[ \t]*|[ \t]+|\n/) : [text]
        tokens.each do |token|
          if token == "\n"
            line_height = Fonts.extent("Hg", font)[1] if line_height.zero?
            flush.call
            next
          end

          w, h = Fonts.extent(token, font)
          flush.call if x.positive? && @wrap_width.positive? && x + w > @wrap_width

          @pieces << Piece.new(token, run, font, x, y, w, h)
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
