# frozen_string_literal: true

require_relative "../drawable"
require_relative "../paragraph"

module Clogs
  # `nostroke` reaches drawables as a fully transparent colour. For shapes
  # that means "don't stroke", but Shoes text never disappears that way -- a
  # text drawable that inherited the transparent draw-context stroke falls
  # back to the colour it would otherwise have had.
  def self.text_color(value, fallback)
    c = Style.color(value, nil)
    c && c[3].to_i.positive? ? c : fallback
  end

  # The display side of Shoes' inline text drawables: strong, em, code, link,
  # span and friends. These have no geometry of their own -- they contribute
  # styled runs to whichever paragraph contains them.
  class TextDrawable < Drawable
    def emphasis_style(base)
      style_for_tag(base)
    end

    # Overridden per tag.
    def style_for_tag(base)
      base
    end

    def own_style(base)
      s = style_for_tag(base)
      s = s.with(size: resolved_size(s.size)) if style(:size)
      s = s.with(color: Clogs.text_color(style(:stroke), s.color)) if style(:stroke)
      s = s.with(bg: Style.color(style(:fill), s.bg)) if style(:fill)
      s = s.with(family: style(:family)) if style(:family)
      s = s.with(underline: true) if truthy_underline?
      s = s.with(italic: true) if style(:emphasis).to_s == "italic"
      s = s.with(bold: style(:font_weight).to_s == "bold") if style(:font_weight)
      s.with(owner: self)
    end

    def truthy_underline?
      u = style(:underline)
      !u.nil? && u != "" && u != "none" && u != false
    end

    def resolved_size(default)
      Paragraph::SIZES[style(:size).to_s.to_sym] || (style(:size).is_a?(Numeric) ? style(:size) : default)
    end

    # Contribute [text, style] pairs to the enclosing paragraph.
    def runs(base_style)
      mine = own_style(base_style)
      Clogs.expand_text_items(style(:text_items), mine)
    end
  end

  class Strong < TextDrawable
    def style_for_tag(base) = base.with(bold: true)
  end

  class Em < TextDrawable
    def style_for_tag(base) = base.with(italic: true)
  end

  class Code < TextDrawable
    def style_for_tag(base) = base.with(family: Clogs.monospace_font_family)
  end

  class Ins < TextDrawable
    def style_for_tag(base) = base.with(underline: true)
  end

  class Del < TextDrawable
    # libui's attributed strings have no strikethrough attribute exposed by the
    # Ruby binding, so on that backend del() still renders as plain text. The
    # FOX backend draws its own text run by run and so can draw the line.
    def style_for_tag(base) = base.with(strike: true)
  end

  class Sub < TextDrawable
    def style_for_tag(base) = base.with(size: (base.size * 0.7).round)
  end

  class Sup < TextDrawable
    def style_for_tag(base) = base.with(size: (base.size * 0.7).round)
  end

  class Span < TextDrawable; end

  class Bg < TextDrawable
    def style_for_tag(base) = base.with(bg: Style.color(style(:fill), base.bg))
  end

  class Fg < TextDrawable
    def style_for_tag(base) = base.with(color: Clogs.text_color(style(:stroke), base.color))
  end

  # A clickable run of text. Clicks are routed by the containing paragraph,
  # which knows where the link's words ended up on screen.
  class Link < TextDrawable
    DEFAULT_COLOR = [0, 0, 238, 255].freeze

    def style_for_tag(base)
      base.with(color: DEFAULT_COLOR, underline: true)
    end

    def clickable?
      true
    end

    def click!(x, y)
      notify("click", 1, x, y)
    end
  end

  # A paragraph: the only text drawable with real geometry.
  class Para < Drawable
    def default_size
      Paragraph::SIZES[:para]
    end

    def base_style
      size = style(:size)
      resolved = Paragraph::SIZES[size.to_s.to_sym] || (size.is_a?(Numeric) ? size.to_i : default_size)
      Paragraph::TextStyle.new(
        family: style(:family) || Clogs.default_font_family,
        size: resolved,
        bold: style(:font_weight).to_s == "bold",
        italic: %w[italic oblique].include?(style(:emphasis).to_s),
        underline: false,
        color: Clogs.text_color(style(:stroke), [0, 0, 0, 255]),
        bg: Style.color(style(:fill), nil),
        owner: self
      )
    end

    def align
      case style(:align).to_s
      when "center" then :center
      when "right" then :right
      else :left
      end
    end

    def measure(available_width, available_height = nil)
      ml, _mt, mr, = margin
      req_w = requested_width(available_width)
      # An explicit width includes the margins, Shoes 3 style.
      avail = (req_w || available_width) - ml - mr
      @paragraph = Paragraph.new(Clogs.expand_text_items(style(:text_items), base_style), avail, align: align)
      @width = if req_w
        avail
      elsif align != :left
        # An aligned para spans its slot; aligning inside a text-sized box
        # would be a no-op.
        avail
      else
        [@paragraph.width.ceil, avail].min
      end
      @height = requested_height(available_height) || @paragraph.height.ceil
    end

    def draw(painter, x, y)
      return unless @paragraph

      @paragraph.draw(painter, x, y)
      draw_text_cursor(painter, x, y)
    end

    # Shoes 3 asks a para which character sits under a window point (nil when
    # the point is outside the para) and where the caret's line starts, for
    # keeping it scrolled into view.
    def hit(x, y)
      return nil unless @paragraph && !@abs_x.nil?
      return nil unless contains?(x, y)

      @paragraph.index_at(x - @abs_x, y - @abs_y)
    end

    def caret_top
      return 0 unless @paragraph

      @paragraph.line_top(style(:text_cursor).to_i)
    end

    # Shoes' `para.cursor = n` puts a caret at character n. libui's text layouts
    # do not expose caret geometry, but Clogs lays out word by word, so the
    # position is a lookup plus one substring measurement.
    def draw_text_cursor(painter, x, y)
      position = style(:text_cursor)
      return if position.nil? || ENV["CLOGS_NO_CARET"]

      item = @paragraph.placed.find do |placed|
        position >= placed.char_offset && position <= placed.char_offset + placed.text.length
      end
      item ||= @paragraph.placed.last
      return unless item

      prefix = item.text[0...(position - item.char_offset)].to_s
      cx = x + item.x + Paragraph.measure(prefix, item.style)[0]
      cy = y + item.y
      painter.line(cx, cy, cx, cy + item.height, [0, 0, 0, 255], thickness: 1)
    end

    def clickable?
      true
    end

    # Find the link (if any) under this point and fire it.
    def on_click(x, y, button)
      return unless @paragraph

      lx = x - @abs_x
      ly = y - @abs_y
      link = link_at(lx, ly)
      link&.click!(x, y)
      _ = button
    end

    def link_at(lx, ly)
      owners = @paragraph.placed.map(&:owner).uniq.select { |o| o.is_a?(Link) }
      owners.find do |owner|
        @paragraph.boxes_for(owner).any? do |bx, by, bw, bh|
          lx >= bx && lx < bx + bw && ly >= by && ly < by + bh
        end
      end
    end

    def cursor_index_at(x, y)
      @paragraph&.index_at(x - @abs_x, y - @abs_y) || 0
    end
  end

  class << Clogs
    # text_items is an array of Strings and linkable IDs of TextDrawables.
    # Resolve it into a flat list of [text, style] pairs.
    def expand_text_items(items, style)
      return [] if items.nil?

      # An item is either literal text or the linkable id of a nested text
      # drawable such as strong() or link(). Ids are not always Strings, so
      # ask the display service about anything that could be one.
      Array(items).flat_map do |item|
        peer = DisplayService.instance&.query_display_drawable_for(item, nil_ok: true)
        if peer.is_a?(TextDrawable)
          peer.runs(style)
        else
          [[item.to_s, style]]
        end
      end
    end
  end
end
