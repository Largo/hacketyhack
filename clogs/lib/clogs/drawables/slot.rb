# frozen_string_literal: true

require_relative "../drawable"

module Clogs
  # A slot: the container drawable that does Shoes' layout.
  #
  # Shoes has exactly two layout modes and they are both simple:
  #
  #   stack - children are placed one below another, each as wide as the slot
  #   flow  - children are placed left to right and wrap when they run out of
  #           room, like words in a paragraph
  #
  # Anything with an explicit `left` and `top` is lifted out of that flow and
  # placed at those coordinates relative to the slot, which is how Shoes
  # programs do absolute positioning.
  class Slot < Drawable
    def flow?
      false
    end

    # A slot only takes a click if something is listening for one.
    #
    # Drawables are clickable by default, which is right for a leaf and wrong
    # for a container: slots routinely cover one another, so the topmost slot
    # under the pointer wins the hit test whether or not it does anything with
    # it, and whatever is beneath it never hears the click. Hackety Hack's
    # whole sidebar was unreachable this way -- a full-window slot painted
    # after it swallowed every click on a tab icon.
    #
    # Handlers on enclosing slots still fire: a release bubbles from the
    # drawable that was pressed up through its parents, so a slot wrapping a
    # clickable child hears about it either way.
    def clickable?
      !style(:click).nil?
    end

    def padding
      @padding ||= Style.paddings(@styles)
    end

    # Backgrounds and borders are children in the Shoes tree but they are not
    # laid out: they cover the whole slot.
    def decorations
      @children.select { |c| c.is_a?(Background) || c.is_a?(Border) }
    end

    def laid_out_children
      @children.reject { |c| c.is_a?(Background) || c.is_a?(Border) || c.hidden? }
    end

    def measure(available_width, available_height = nil)
      ml, mt, mr, mb = margin
      pl, pt, pr, pb = padding

      # Shoes 3's box model: a slot's margins live inside its declared width.
      # `stack :width => 37, :margin_right => 6` occupies 37 pixels with the
      # content inset -- two columns sized 37 and -37 tile a row exactly.
      outer_width = (requested_width(available_width) || available_width) - ml - mr
      outer_width = 0 if outer_width.negative?
      content_width = [outer_width - pl - pr, 0].max

      requested = requested_height(available_height)
      requested = [requested - mt - mb, 0].max if requested
      content_avail_height = requested ? [requested - pt - pb, 0].max : available_height

      # A scrolling slot keeps its bar inside its own box rather than letting
      # it sit over the content, so the room comes off the width the children
      # are laid out against. It is reserved whether or not the content
      # currently overflows: laying out again the moment it does would reflow
      # every line at the exact moment the user started scrolling.
      content_width -= SCROLLBAR_WIDTH if scrolls?
      content_width = 0 if content_width.negative?

      flowed, positioned = laid_out_children.partition { |c| !c.positioned? }
      content_height = if flow?
        layout_flow(flowed, content_width, content_avail_height)
      else
        layout_stack(flowed, content_width, content_avail_height)
      end

      @content_width = content_width
      @width = outer_width
      @height = requested || (content_height + pt + pb)
      # What the children actually came to, which is what there is to scroll
      # through when it is more than fits.
      @content_height = content_height + pt + pb

      inner_height = [@height - pt - pb, 0].max
      positioned.each do |child|
        child.measure(content_width, inner_height)
        child.x = pl + position_x(child, content_width)
        child.y = pt + position_y(child, inner_height)
      end

      decorations.each { |d| d.measure_for_slot(@width, @height) }
    end

    # Shoes positions from whichever edges are given; the missing coordinate
    # defaults to the slot's origin.
    def position_x(child, extent)
      left = Style.position(child.style(:left), extent)
      return left if left

      right = Style.position(child.style(:right), extent)
      right ? extent - right - child.width : 0
    end

    def position_y(child, extent)
      top = Style.position(child.style(:top), extent)
      return top if top

      bottom = Style.position(child.style(:bottom), extent)
      bottom ? extent - bottom - child.height : 0
    end

    def layout_stack(kids, content_width, available_height = nil)
      _pl, pt, = padding
      pl = padding[0]
      y = pt
      kids.each do |child|
        cml, cmt, _cmr, cmb = child.margin
        child.measure(content_width, available_height)
        child.x = pl + cml
        child.y = y + cmt
        y += cmt + child.height + cmb
      end
      y - pt
    end

    def layout_flow(kids, content_width, available_height = nil)
      pl, pt, = padding
      x = 0
      y = 0
      line_height = 0
      kids.each do |child|
        cml, cmt, cmr, cmb = child.margin
        child.measure(content_width, available_height)
        advance = cml + child.width + cmr
        if x.positive? && x + advance > content_width
          y += line_height
          x = 0
          line_height = 0
        end
        child.x = pl + x + cml
        child.y = pt + y + cmt
        x += advance
        line_height = [line_height, cmt + child.height + cmb].max
      end
      y + line_height
    end

    # A slot with an explicit size clips its contents, as Shoes 3 did --
    # Hackety Hack's sidebar tooltip relies on it by growing the slot on
    # hover. A scrolling slot clips too, by definition: the part you have not
    # scrolled to is the part that must not be drawn.
    def clip_contents?
      scrolls? || (!style(:width).nil? && !style(:height).nil?)
    end

    # ---- scrolling -----------------------------------------------------
    #
    # `stack :scroll => true` in Shoes gives a slot its own scrollbar and
    # scrolls its contents under it. Hackety Hack asks for exactly that in two
    # places that matter -- the lesson pane and the editor's code area -- and
    # without it everything past the bottom edge is simply unreachable.

    SCROLLBAR_WIDTH = 10
    MIN_THUMB = 24

    def scrolls?
      !style(:scroll).nil? && style(:scroll) != false
    end

    def content_height
      @content_height || @height || 0
    end

    # How far down it is possible to scroll: nothing, when it all fits.
    def max_scroll
      [content_height - (@height || 0), 0].max
    end

    def scroll_top
      [(@scroll_top || 0), max_scroll].min
    end

    def scroll_top=(value)
      wanted = value.to_f.round
      wanted = 0 if wanted.negative?
      wanted = max_scroll if wanted > max_scroll
      return if wanted == @scroll_top

      @scroll_top = wanted
      redraw!
    end

    # A wheel turn, or a drag of the bar. Returns true when it actually moved,
    # so a wheel over a slot that cannot scroll falls through to whatever is
    # behind it.
    def scroll_by(amount)
      return false unless scrolls? && max_scroll.positive?

      before = scroll_top
      self.scroll_top = before + amount
      scroll_top != before
    end

    def scrollbar_rect
      return nil unless scrolls? && max_scroll.positive? && @abs_x

      [@abs_x + @width - SCROLLBAR_WIDTH, @abs_y, SCROLLBAR_WIDTH, @height]
    end

    def thumb_rect
      track = scrollbar_rect
      return nil unless track

      tx, ty, tw, th = track
      height = [(th * th.to_f / content_height).round, MIN_THUMB].max
      height = th if height > th
      travel = th - height
      offset = max_scroll.zero? ? 0 : (travel * scroll_top.to_f / max_scroll).round
      [tx, ty + offset, tw, height]
    end

    def paint(painter, ox, oy)
      @abs_x = ox + @x
      @abs_y = oy + @y

      decorations.grep(Background).each do |d|
        d.paint_for_slot(painter, @abs_x, @abs_y, @width, @height) unless d.hidden?
      end
      if clip_contents?
        painter.save do |p|
          p.clip_rect(@abs_x, @abs_y, @width, @height)
          paint_children(p)
        end
      else
        paint_children(painter)
      end
      paint_scrollbar(painter)
      decorations.grep(Border).each do |d|
        d.paint_for_slot(painter, @abs_x, @abs_y, @width, @height) unless d.hidden?
      end
    end

    def paint_children(painter)
      # Scrolling moves the contents up under the clip; the children know
      # nothing about it, and the absolute positions they record on the way
      # through are the ones the mouse will be tested against.
      oy = @abs_y - (scrolls? ? scroll_top : 0)
      @children.each do |child|
        next if child.hidden? || child.is_a?(Background) || child.is_a?(Border)

        child.paint(painter, @abs_x, oy)
      end
    end

    TRACK_COLOR = [0, 0, 0, 26].freeze
    THUMB_COLOR = [0, 0, 0, 92].freeze

    # Outside the clip, so the bar stays put while the contents move under it.
    def paint_scrollbar(painter)
      track = scrollbar_rect
      return unless track

      painter.fill_rect(*track, TRACK_COLOR)
      tx, ty, tw, th = thumb_rect
      painter.fill_rect(tx + 2, ty + 1, tw - 4, [th - 2, 1].max, THUMB_COLOR)
    end
  end

  class Stack < Slot; end

  class Flow < Slot
    def flow?
      true
    end
  end

  # The invisible slot that holds an app's whole document. Shoes' top level
  # behaves like a flow.
  class DocumentRoot < Flow
    def app=(app)
      @app = app
    end

    def app
      @app
    end
  end
end
