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

      flowed, positioned = laid_out_children.partition { |c| !c.positioned? }
      content_height = if flow?
        layout_flow(flowed, content_width, content_avail_height)
      else
        layout_stack(flowed, content_width, content_avail_height)
      end

      @content_width = content_width
      @width = outer_width
      @height = requested || (content_height + pt + pb)

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
    # hover.
    def clip_contents?
      !style(:width).nil? && !style(:height).nil?
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
      decorations.grep(Border).each do |d|
        d.paint_for_slot(painter, @abs_x, @abs_y, @width, @height) unless d.hidden?
      end
    end

    def paint_children(painter)
      @children.each do |child|
        next if child.hidden? || child.is_a?(Background) || child.is_a?(Border)

        child.paint(painter, @abs_x, @abs_y)
      end
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
