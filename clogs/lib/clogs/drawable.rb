# frozen_string_literal: true

require_relative "style"

module Clogs
  # Base class for every Clogs peer: the display-side half of a Shoes drawable.
  #
  # Lacci owns the Shoes-side object and tells us about it through three events
  # (`parent`, `prop_change`, `destroy`). We own pixels: where the thing sits,
  # how big it is, and what it looks like.
  #
  # The layout contract is two passes:
  #
  #   measure(available_width) -> sets @width / @height
  #   paint(painter, ox, oy)   -> draws, and records absolute geometry so that
  #                               mouse hit-testing has something to test
  class Drawable < Shoes::Linkable
    attr_accessor :parent, :x, :y
    attr_reader :children, :shoes_linkable_id, :styles, :abs_x, :abs_y, :width, :height

    class << self
      # Peer class lookup by Shoes class name, e.g. "Shoes::Button" -> Clogs::Button.
      def for_shoes_class(name)
        short = name.split("::").last
        Clogs.const_get(short) if Clogs.const_defined?(short, false)
      end
    end

    def initialize(properties)
      @styles = {}
      properties.each { |k, v| @styles[k.to_s] = v }
      @shoes_linkable_id = @styles.delete("shoes_linkable_id")
      @children = []
      @x = @y = 0
      @width = @height = 0

      super(linkable_id: @shoes_linkable_id)

      bind_shoes_event(event_name: "parent", target: @shoes_linkable_id) do |new_parent_id|
        new_parent = DisplayService.instance.query_display_drawable_for(new_parent_id, nil_ok: true)
        set_parent(new_parent) unless new_parent == @parent
      end

      bind_shoes_event(event_name: "prop_change", target: @shoes_linkable_id) do |changes|
        changes.each { |k, v| @styles[k.to_s] = v }
        properties_changed(changes)
      end

      bind_shoes_event(event_name: "destroy", target: @shoes_linkable_id) do
        destroy_self
      end
    end

    def properties_changed(_changes)
      needs_layout!
    end

    def destroy_self
      set_parent(nil)
      needs_layout!
    end

    def set_parent(new_parent)
      @parent&.remove_child(self)
      new_parent&.add_child(self)
      @parent = new_parent
      needs_layout!
    end

    def add_child(child)
      @children << child unless @children.include?(child)
    end

    def remove_child(child)
      @children.delete(child)
    end

    # The owning Clogs::App, found by walking up the tree.
    def app
      @app ||= @parent&.app
    end

    def needs_layout!
      app&.needs_layout!
    end

    def redraw!
      app&.redraw!
    end

    # ---- styles -------------------------------------------------------

    def style(name)
      @styles[name.to_s]
    end

    def hidden?
      !!style(:hidden)
    end

    # A drawable with an explicit left/top is taken out of the normal flow and
    # placed at those coordinates within its slot, exactly as in Shoes.
    def positioned?
      !style(:left).nil? && !style(:top).nil?
    end

    def margin
      @margin ||= Style.margins(@styles)
    end

    def requested_width(available)
      Style.dimension(style(:width), available)
    end

    def requested_height(available)
      Style.dimension(style(:height), available)
    end

    # ---- layout -------------------------------------------------------

    # Subclasses override. Must set @width and @height.
    def measure(available_width)
      @width = requested_width(available_width) || 0
      @height = requested_height(available_width) || 0
    end

    def paint(painter, ox, oy)
      @abs_x = ox + @x
      @abs_y = oy + @y
      draw(painter, @abs_x, @abs_y)
    end

    def draw(_painter, _x, _y); end

    # ---- events -------------------------------------------------------

    def contains?(px, py)
      return false if @abs_x.nil? || hidden?

      px >= @abs_x && px < @abs_x + @width && py >= @abs_y && py < @abs_y + @height
    end

    # Overridden by controls that want the keyboard.
    def focusable?
      false
    end

    def clickable?
      false
    end

    def on_click(_x, _y, _button); end

    def on_release(_x, _y, _button); end

    def on_mouse_move(_x, _y); end

    def on_key(_event)
      false
    end

    def focus_gained; end

    def focus_lost; end

    def notify(event_name, *args)
      send_shoes_event(*args, event_name: event_name, target: @shoes_linkable_id)
    end

    # Depth-first list of visible peers in paint order, for hit testing.
    def each_peer(&block)
      return if hidden?

      block.call(self)
      @children.each { |c| c.each_peer(&block) }
    end
  end
end
