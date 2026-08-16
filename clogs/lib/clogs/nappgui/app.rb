# frozen_string_literal: true

require_relative "canvas"
require_relative "dialogs"

module Clogs
  # The NAppGUI half of Clogs::App.
  #
  # Everything about App that is not window, loop or timer is
  # backend-independent and stays in app.rb; this reopens the class and
  # replaces the calls that were libui.
  #
  # The one thing NAppGUI forces on this file that no other backend does is
  # *when* a window may be built. draw2d does not exist until osmain_imp has
  # started the SDK and called back, so `init` cannot create the window the way
  # every other backend's does -- it records what to build, and `run` builds it
  # from inside the create callback. A second Shoes.app opened later has it
  # easier: by then the SDK is up and the window can be made on the spot.
  class App < Drawable
    class << self
      attr_accessor :nappgui_initialized

      def ensure_libui!
        return true if nappgui_initialized

        Shim.load!
        install_dispatch
        self.nappgui_initialized = true
      end
      alias_method :ensure_backend!, :ensure_libui!

      # The shim's timers call back with the id they were made with; the
      # blocks live here so the closure handed to C never has to change.
      def timers
        @timers ||= {}
      end

      def install_dispatch
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

      # Run a block at the next tick rather than now.
      #
      # Destroying a window from inside its own draw callback pulls the
      # drawing context out from under NAppGUI while it is still using it,
      # which is the same hazard libui's queue_main exists for -- and a Shoes
      # app that animates does exactly this when its run deadline expires
      # mid-paint. The shim's tick is the safe point, so the shortest
      # possible one-shot timer stands in for queue_main.
      def defer(&block)
        id = next_timer_id
        timers[id] = lambda do
          timers.delete(id)
          block.call
        end
        Shim.timer_new(1, 0, id)
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

      # Only if the SDK is already running -- otherwise #run does it from
      # inside the create callback, which is the first moment it is legal.
      build_window if Shim.started?
    end

    def build_window
      return if @window || @destroyed

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
      @running = true

      if App.loop_owner.nil?
        # The first app in the process owns the shared NAppGUI loop. Its
        # window cannot exist yet, so it is built in the create callback --
        # the first point at which draw2d is up.
        App.loop_owner = self
        Shim.on_create(Shim.callback(Fiddle::TYPE_VOID, []) { start_in_loop })
        Shim.run
        App.loop_owner = nil
      else
        # The shared loop is already running, so this window can be built and
        # shown now. Lacci calls destroy() the moment a display library's
        # event loop returns, which is right for the loop owner and wrong for
        # everyone else.
        build_window
        show_and_arm
        send_shoes_event("return", event_name: "custom_event_loop", target: @shoes_linkable_id)
      end
    end

    # Runs inside NAppGUI's create callback, with the SDK up and the loop
    # about to start.
    def start_in_loop
      build_window
      show_and_arm
    rescue StandardError => e
      report_error(e)
      App.instances.dup.each(&:quit)
    end

    def show_and_arm
      Shim.window_show(@window)
      arm_timers
      install_test_hooks
    end

    def destroy
      return if @destroyed

      @destroyed = true
      App.instances.delete(self)
      window = @window
      @window = nil
      @canvas&.destroy
      @canvas = nil
      @timer_ids&.each do |id|
        App.timers.delete(id)
        Shim.timer_stop(id)
      end
      @timer_ids = nil

      App.defer do
        Shim.window_destroy(window) if window
        next unless App.instances.empty? && App.loop_owner

        # Fonts and images are draw2d objects, and draw2d does not outlive
        # the loop -- so they go now rather than after Shim.run returns.
        Fonts.clear
        Image.free_all
        Shim.quit
      end
    end

    def redraw!
      return if @destroyed

      @canvas&.redraw
    end

    # Timers can only be armed once the loop is up. Shoes programs routinely
    # call `animate` while the app is still being built, so those are queued.
    def add_timer(interval_ms, repeat: true, &block)
      interval_ms = 1 if interval_ms.to_i < 1
      unless @running && @window
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
      Shim.timer_new(interval_ms, repeat ? 1 : 0, id)
      id
    end
  end
end
