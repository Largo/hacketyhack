# frozen_string_literal: true

require_relative "canvas"
require_relative "dialogs"

module Clogs
  # The Qt half of Clogs::App.
  #
  # Everything about App that is not window, loop or timer is
  # backend-independent and stays in app.rb; this reopens the class and
  # replaces the calls that were libui.
  class App < Drawable
    class << self
      attr_accessor :qt_initialized

      def ensure_libui!
        return true if qt_initialized

        Shim.load!
        raise Shim::NotBuilt, "Qt shim failed to initialise" if Shim.init.zero?

        install_timer_dispatch
        self.qt_initialized = true
      end
      alias_method :ensure_backend!, :ensure_libui!

      # Qt timers call back with the id they were made with; the blocks live
      # here so the closure handed to C never has to change.
      def timers
        @timers ||= {}
      end

      def install_timer_dispatch
        Shim.on_timer(Shim.callback(Fiddle::TYPE_VOID, [Fiddle::TYPE_INT]) do |id|
          timers[id]&.call
        end)
        Shim.on_close(Shim.callback(Fiddle::TYPE_VOID, [Fiddle::TYPE_VOIDP]) do |window|
          instances.find { |app| app.window_handle?(window) }&.quit
        end)
      end

      def next_timer_id
        @next_timer_id = (@next_timer_id || 0) + 1
      end

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
      App.ensure_libui!
      @initialized = true

      @window = Shim.window_new(title, app_width, app_height)
      @canvas = Canvas.new(@window)
      @canvas.on_draw = method(:on_draw)
      @canvas.on_mouse = method(:on_mouse)
      @canvas.on_key = method(:on_key)
      @canvas.on_crossed = method(:on_crossed)
    end

    def window_handle?(pointer)
      !@window.nil? && !pointer.nil? && @window.to_i == pointer.to_i
    end

    def run
      Shim.window_show(@window)
      @running = true
      arm_timers
      install_test_hooks

      if App.loop_owner.nil?
        # The first app in the process owns the shared Qt loop; every window
        # created while it runs -- including a nested Shoes.app -- is serviced
        # by the same exec().
        App.loop_owner = self
        Shim.run
        Image.free_all_paths
        App.loop_owner = nil
      else
        # Lacci calls destroy() the moment a display library's event loop
        # returns. Right for the loop owner, wrong for everyone else.
        send_shoes_event("return", event_name: "custom_event_loop", target: @shoes_linkable_id)
      end
    end

    def destroy
      return if @destroyed

      @destroyed = true
      App.instances.delete(self)
      window = @window
      @window = nil
      @canvas&.destroy
      @canvas = nil
      @timer_ids&.each { |id| App.timers.delete(id) }
      @timer_handles&.each { |handle| Shim.timer_stop(handle) }
      @timer_ids = nil
      @timer_handles = nil

      Shim.window_destroy(window) if window
      # Qt's own quit() asks every window to close first, and Clogs' windows
      # refuse a close they did not ask for, so the loop is ended directly --
      # once this was the last window standing.
      Shim.quit if App.instances.empty? && App.loop_owner
    end

    def redraw!
      return if @destroyed

      @canvas&.redraw
    end

    # Timers can only be armed once Qt is up. Shoes programs routinely call
    # `animate` while the app is still being built, so those are queued.
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
      id = App.next_timer_id
      App.timers[id] = lambda do
        next if @destroyed

        begin
          block.call
        rescue StandardError => e
          report_error(e)
        end
        App.timers.delete(id) unless repeat
      end
      (@timer_ids ||= []) << id
      handle = Shim.timer_new(interval_ms, repeat ? 1 : 0, id)
      (@timer_handles ||= []) << handle
      handle
    end
  end
end
