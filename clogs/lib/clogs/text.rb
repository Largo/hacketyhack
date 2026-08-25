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

  # A laid-out paragraph.
  #
  # libui gives us Pango/DirectWrite/Core Text via uiDrawTextLayout: an
  # attributed string plus a wrap width, and it reports the resulting extents.
  # That covers Shoes' text model (a paragraph of differently-styled spans that
  # wraps) without us writing a line breaker.
  #
  # What it does *not* give us is per-character hit testing or caret geometry,
  # which is why Clogs' own text editing (edit_line / edit_box) measures
  # substrings instead of asking the layout where a click landed.
  class TextBlock
    ALIGN_LEFT = 0
    ALIGN_CENTER = 1
    ALIGN_RIGHT = 2

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
      painter.draw_text(@layout, x, y)
    end

    # Width of the first `n` characters, used to place text carets.
    def prefix_width(n)
      return 0.0 if n <= 0

      text = plain_text
      n = text.length if n > text.length
      @prefix_cache ||= {}
      @prefix_cache[n] ||= begin
        sub = TextBlock.new(
          [Run.new(text: text[0, n], **first_style)],
          -1,
          default_family: @default_family,
          default_size: @default_size
        )
        w = sub.width
        sub.free
        w
      end
    end

    def plain_text
      @plain_text ||= @runs.map { |r| r.text.to_s }.join
    end

    def free
      UI::L.draw_free_text_layout(@layout) if @layout
      UI::L.free_attributed_string(@astr) if @astr
      @layout = nil
      @astr = nil
    end

    private

    def first_style
      r = @runs.first
      return { size: @default_size, color: [0, 0, 0, 255] } unless r

      { size: r.size, color: r.color, family: r.family, bold: r.bold, italic: r.italic }
    end

    def build
      @astr = UI::L.new_attributed_string("")
      @runs.each do |run|
        text = run.text.to_s
        next if text.empty?

        start = UI::L.attributed_string_len(@astr)
        UI::L.attributed_string_append_unattributed(@astr, text)
        finish = start + text.bytesize

        if run.size
          UI::L.attributed_string_set_attribute(@astr, UI::L.new_size_attribute(run.size.to_f), start, finish)
        end
        if run.color
          r, g, b, a = run.color
          UI::L.attributed_string_set_attribute(
            @astr,
            UI::L.new_color_attribute(r / 255.0, g / 255.0, b / 255.0, (a || 255) / 255.0),
            start, finish
          )
        end
        if run.family
          UI::L.attributed_string_set_attribute(@astr, UI::L.new_family_attribute(run.family), start, finish)
        end
        if run.bold
          UI::L.attributed_string_set_attribute(@astr, UI::L.new_weight_attribute(UI::WEIGHT_BOLD), start, finish)
        end
        if run.italic
          UI::L.attributed_string_set_attribute(@astr, UI::L.new_italic_attribute(UI::ITALIC_ITALIC), start, finish)
        end
        if run.underline
          UI::L.attributed_string_set_attribute(@astr, UI::L.new_underline_attribute(1), start, finish)
        end
      end

      font = UI.font_descriptor(@default_family, @default_size)
      params = UI.malloc(UI::L::FFI::DrawTextLayoutParams)
      params.String = @astr
      params.DefaultFont = font.to_ptr
      # A negative width means "do not wrap"; libui wants a very large number.
      params.Width = @wrap_width.negative? ? 1_000_000.0 : @wrap_width
      params.Align = @align
      # Keep the descriptor alive for as long as the layout uses it.
      @font = font

      @layout = UI::L.draw_new_text_layout(params)
      @width, @height = UI.text_extents(@layout)
    end
  end
end
