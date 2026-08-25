# frozen_string_literal: true

require_relative "canvas"
require_relative "dialogs"

module Clogs
  # The FOX half of Clogs::App.
  #
  # Everything about App that is not window, loop or timer -- layout, painting,
  # hit testing, focus, subscriptions -- is backend-independent and stays in
  # app.rb. This file reopens the class and replaces the calls that were libui.
  class App < Drawable
    class << self
      # FOX's application object. Like libui's init, it is process-wide rather
      # than per window.
      attr_accessor :fox_app

      def ensure_libui!
        return fox_app if fox_app

        self.fox_app = Fox::FXApp.new("Clogs", "Clogs")
        fox_app.create
        fox_app
      end
      alias_method :ensure_backend!, :ensure_libui!

      def run_builtin(cmd, args, window)
        ensure_libui!
        case cmd.to_s
        when "alert" then Dialogs.alert(window, args[0])
        when "confirm" then Dialogs.confirm(window, args[0])
        when "ask" then Dialogs.ask(window, args[0])
        when "ask_open_file" then Dialogs.open_file(window)
        when "ask_save_file" then Dialogs.save_file(window)
        when "ask_open_folder" then Dialogs.open_folder(window)
        when "ask_color" then nil
        when "font" then nil
        end
      rescue StandardError => e
        report_error(e)
        nil
      end
    end

    def init
      app = App.ensure_libui!
      @initialized = true

      @window = Fox::FXMainWindow.new(app, title, nil, nil, Fox::DECOR_ALL, 0, 0, app_width, app_height)
      @window.connect(Fox::SEL_CLOSE) do
        quit
        1
      end
      @window.padLeft = @window.padRight = @window.padTop = @window.padBottom = 0
      @window.hSpacing = @window.vSpacing = 0

      @canvas = Canvas.new(@window)
      @canvas.on_draw = method(:on_draw)
      @canvas.on_mouse = method(:on_mouse)
      @canvas.on_key = method(:on_key)
      @canvas.on_crossed = method(:on_crossed)
      @window.create
    end

    def run
      @window.show(Fox::PLACEMENT_SCREEN)
      @running = true
      arm_timers
      install_test_hooks

      if App.loop_owner.nil?
        # First app in the process owns the shared FOX loop; every later
        # window, including a nested Shoes.app, is serviced by the same one.
        App.loop_owner = self
        App.fox_app.run
        # Fonts are server resources tied to the FXApp that made them.
        Fonts.clear
        App.loop_owner = nil
      else
        # Lacci calls destroy() the moment a display library's event loop
        # returns. That is right for the loop owner and wrong for everyone
        # else, so tell it to hand control back to the outer loop instead.
        send_shoes_event("return", event_name: "custom_event_loop", target: @shoes_linkable_id)
      end
    end

    def destroy
      return if @destroyed

      @destroyed = true
      App.instances.delete(self)
      window = @window
      @window = nil
      canvas = @canvas
      @canvas = nil

      # Tearing a window down from inside its own close handler is safe in FOX
      # in a way it is not in libui, but the loop still has to outlive the last
      # window's own event dispatch, so the exit is deferred by a chore.
      canvas&.destroy
      if window
        window.hide
        window.destroy
      end
      return unless App.instances.empty? && App.loop_owner

      App.fox_app.addChore { App.fox_app.exit(0) }
    end

    def redraw!
      return if @destroyed

      @canvas&.redraw
    end

    # FOX timeouts are one-shot, so a repeating timer re-arms itself. Timers
    # armed before the loop starts are queued, as in the libui backend: Shoes
    # programs routinely call `animate` while the app is still being built.
    def add_timer(interval_ms, repeat: true, &block)
      interval_ms = 1 if interval_ms.to_i < 1
      unless @running
        (@pending_timers ||= []) << [interval_ms, repeat, block]
        return
      end

      arm_timer(interval_ms, repeat, block)
    end

    def arm_timers
      pending = @pending_timers || []
      @pending_timers = nil
      pending.each { |interval, repeat, block| arm_timer(interval, repeat, block) }
    end

    def arm_timer(interval_ms, repeat, block)
      App.fox_app.addTimeout(interval_ms) do
        unless @destroyed
          begin
            block.call
          rescue StandardError => e
            report_error(e)
          end
          arm_timer(interval_ms, repeat, block) if repeat && !@destroyed
        end
      end
    end
  end
end
