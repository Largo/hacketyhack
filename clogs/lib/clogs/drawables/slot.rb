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

    def measure(available_width)
      ml, _mt, mr, _mb = margin
      pl, pt, pr, pb = padding

      outer_width = requested_width(available_width) || (available_width - ml - mr)
      outer_width = 0 if outer_width.negative?
      content_width = [outer_width - pl - pr, 0].max

      flowed, positioned = laid_out_children.partition { |c| !c.positioned? }
      content_height = flow? ? layout_flow(flowed, content_width) : layout_stack(flowed, content_width)

      positioned.each do |child|
        child.measure(content_width)
        child.x = pl + Style.dimension(child.style(:left), content_width).to_i
        child.y = pt + Style.dimension(child.style(:top), outer_width).to_i
      end

      @content_width = content_width
      @width = outer_width
      @height = requested_height(available_width) || (content_height + pt + pb)
      decorations.each { |d| d.measure_for_slot(@width, @height) }
    end

    def layout_stack(kids, content_width)
      _pl, pt, = padding
      pl = padding[0]
      y = pt
      kids.each do |child|
        cml, cmt, _cmr, cmb = child.margin
        child.measure(content_width)
        child.x = pl + cml
        child.y = y + cmt
        y += cmt + child.height + cmb
      end
      y - pt
    end

    def layout_flow(kids, content_width)
      pl, pt, = padding
      x = 0
      y = 0
      line_height = 0
      kids.each do |child|
        cml, cmt, cmr, cmb = child.margin
        child.measure(content_width)
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

    def paint(painter, ox, oy)
      @abs_x = ox + @x
      @abs_y = oy + @y

      decorations.grep(Background).each { |d| d.paint_for_slot(painter, @abs_x, @abs_y, @width, @height) }
      @children.each do |child|
        next if child.hidden? || child.is_a?(Background) || child.is_a?(Border)

        child.paint(painter, @abs_x, @abs_y)
      end
      decorations.grep(Border).each { |d| d.paint_for_slot(painter, @abs_x, @abs_y, @width, @height) }
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
