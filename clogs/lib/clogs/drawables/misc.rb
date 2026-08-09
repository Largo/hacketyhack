# frozen_string_literal: true

require_relative "../drawable"
require_relative "slot"

module Clogs
  # `animate`, `every`, `timer`, `motion`, `click`, `hover`, `keypress`: Shoes
  # calls that subscribe to something rather than drawing anything.
  class SubscriptionItem < Drawable
    def initialize(properties)
      super
      @frame = 0
      start_timer
    end

    def api_name
      style(:shoes_api_name).to_s
    end

    def args
      Array(style(:args))
    end

    def measure(_available_width)
      @width = 0
      @height = 0
    end

    def clickable?
      false
    end

    def start_timer
      case api_name
      when "animate"
        fps = (args[0] || 10).to_i
        fps = 10 if fps <= 0
        schedule(1000 / fps) { notify("animate", @frame += 1) }
      when "every"
        seconds = (args[0] || 1).to_f
        schedule((seconds * 1000).round) { notify("every", @frame += 1) }
      when "timer"
        seconds = (args[0] || 1).to_f
        schedule((seconds * 1000).round, repeat: false) { notify("timer") }
      end
    end

    # The app may not exist yet when the subscription is created, so defer.
    def schedule(interval, repeat: true, &block)
      @pending_timer = [interval, repeat, block]
      install_timer
    end

    def install_timer
      return unless @pending_timer
      return unless app

      interval, repeat, block = @pending_timer
      @pending_timer = nil
      @stopped = false
      app.add_timer(interval, repeat: repeat) do
        block.call unless @stopped
      end
    end

    def set_parent(new_parent)
      super
      @app = nil
      install_timer
    end

    def destroy_self
      @stopped = true
      super
    end
  end

  # A user-defined Shoes::Widget subclass. It behaves as a slot.
  class Widget < Slot; end

  # Shoes' `mask` composites its contents as an alpha mask over the slot
  # beneath it. libui has no group/alpha-compositing support, so the contents
  # are drawn normally; see the coverage matrix.
  class Mask < Slot; end

  class Video < Drawable
    def measure(available_width)
      @width = requested_width(available_width) || 320
      @height = requested_height(available_width) || 240
    end

    # libui has no media support at all, so this is an honest placeholder
    # rather than a silent no-op.
    def draw(painter, x, y)
      painter.fill_rect(x, y, @width, @height, [20, 20, 20, 255])
      painter.draw(fill: [200, 200, 200, 255]) do |p|
        cx = x + @width / 2.0
        cy = y + @height / 2.0
        p.move_to(cx - 12, cy - 16).line_to(cx + 16, cy).line_to(cx - 12, cy + 16).close
      end
    end
  end

  class Arrow < ArtDrawable
    def measure(available_width)
      @width = Style.dimension(style(:width), available_width).to_i
      @height = (@width / 2.0).round
    end

    def draw(painter, x, y)
      w = @width
      h = @height
      painter.draw(fill: fill_paint, stroke: stroke_paint, thickness: strokewidth) do |p|
        p.move_to(x, y + h * 0.35)
          .line_to(x + w * 0.6, y + h * 0.35)
          .line_to(x + w * 0.6, y)
          .line_to(x + w, y + h * 0.5)
          .line_to(x + w * 0.6, y + h)
          .line_to(x + w * 0.6, y + h * 0.65)
          .line_to(x, y + h * 0.65)
          .close
      end
    end
  end
end
