# frozen_string_literal: true

require_relative "bridge"
require_relative "canvas"
require_relative "dialogs"
require_relative "runtime"
require_relative "clipboard"
require_relative "threads"

module Clogs
  # The wasm half of Clogs::App.
  #
  # Everything about App that is not window, loop or timer is
  # backend-independent and stays in app.rb. What this replaces is the part
  # that assumed a native event loop existed to block in -- see Wasm::Runtime
  # for why there is none here, and what drives the frames instead.
  class App < Drawable
    class << self
      # There is no library to start. The page is already running by the time
      # any Ruby has executed, so this only records that a display exists at
      # all, and fails loudly if the page forgot to load the host script.
      def ensure_libui!
        return if @wasm_ready

        Wasm::Bridge.host
        @wasm_ready = true
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

    attr_reader :window_id

    def init
      App.ensure_libui!
      @initialized = true

      @window_id = Wasm::Runtime.next_window_id
      @window = @window_id
      Wasm::Bridge.open_window(@window_id, title, app_width, app_height)

      @canvas = Canvas.new(@window_id, app_width, app_height)
      @canvas.on_draw = method(:on_draw)
      @canvas.on_mouse = method(:on_mouse)
      @canvas.on_key = method(:on_key)
      @canvas.on_crossed = method(:on_crossed)
    end

    # Show the canvas and hand control back to the page.
    #
    # Every app takes the "return" branch, not just the nested ones the other
    # backends use it for: there is no loop to own. Lacci's Shoes::App#run
    # returns, the Ruby program that called `Shoes.app` runs on to its end, and
    # the app stays alive because Runtime is holding it -- which is also why a
    # Shoes 3 sample that assumed `Shoes.app` blocks behaves *better* here,
    # with its trailing definitions reached instead of skipped.
    def run
      @running = true
      arm_timers
      install_test_hooks
      Wasm::Runtime.install!
      Wasm::Runtime.register(self)
      App.loop_owner ||= self
      redraw!
      send_shoes_event("return", event_name: "custom_event_loop", target: @shoes_linkable_id)
    end

    def destroy
      return if @destroyed

      @destroyed = true
      App.instances.delete(self)
      Wasm::Runtime.unregister(self)
      @timers_due = []
      @canvas&.destroy
      @canvas = nil
      window_id = @window_id
      @window = nil
      Wasm::Bridge.close_window(window_id) if window_id

      return unless App.instances.empty?

      # Nothing is holding a native library open, so the only teardown is the
      # caches that were keyed to a window's fonts and pictures.
      Fonts.clear
      Image.free_all_paths
      App.loop_owner = nil
    end

    def redraw!
      return if @destroyed

      @canvas&.redraw
    end

    # The page resized the canvas under us; the shared on_draw re-measures the
    # document whenever the painter's size changes.
    def resize(width, height)
      @canvas&.resize(width.to_i, height.to_i)
    end

    # Playwright and friends take their own screenshots, and a wasm process has
    # no shell to run ImageMagick in even if it wanted one.
    def capture_screenshot(_path); end

    # ---- timers ---------------------------------------------------------
    #
    # There is no timer API to hand a callback to. Ruby keeps the schedule and
    # Runtime#tick fires whatever is due, which has the pleasant side effect of
    # making `animate` and `every` as reproducible as the frame clock is: a
    # harness that ticks by hand gets exactly the animation steps it asked for.

    def timers_due
      @timers_due ||= []
    end

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
      timers_due << { due: Wasm::Runtime.now + interval_ms, interval: interval_ms, repeat: repeat, block: block }
    end

    # Fired from the animation frame. A timer that has fallen far behind --
    # the page was in a background tab, say -- is caught up by one step rather
    # than by every step it missed, which is what keeps an animation from
    # sprinting after the tab comes back.
    def fire_due_timers(now_ms)
      return if @destroyed || timers_due.empty?

      due = timers_due.select { |t| t[:due] <= now_ms }
      return if due.empty?

      due.each do |timer|
        break if @destroyed

        begin
          timer[:block].call
        rescue StandardError => e
          report_error(e)
        end
        if timer[:repeat] && !@destroyed
          timer[:due] = now_ms + timer[:interval]
        else
          timers_due.delete(timer)
        end
      end
    end
  end
end
