# frozen_string_literal: true

require_relative "drawable"
require_relative "canvas"
require_relative "dialogs"
require_relative "clipboard"

module Clogs
  # The display side of Shoes::App: one libui window, one canvas, and the
  # plumbing that turns libui's callbacks into Shoes events.
  class App < Drawable
    class << self
      attr_accessor :instance

      # Set synchronously while a `builtin` event is being handled, so that
      # `ask`/`confirm` can return a value even on Lacci versions that have no
      # response channel of their own.
      attr_accessor :builtin_response
    end

    attr_reader :window, :canvas, :document_root, :mouse_state

    def initialize(properties)
      super
      App.instance = self
      @timers = []
      @needs_layout = true
      @focused = nil
      @hovered = nil
      @mouse_state = [0, 0, 0]

      bind_shoes_event(event_name: "init") { init }
      bind_shoes_event(event_name: "run") { run }
      bind_shoes_event(event_name: "destroy") { destroy }
      Shoes::DisplayService.subscribe_to_event("builtin", nil) do |cmd, args|
        App.builtin_response = builtin(cmd, args)
      end
    end

    def app
      self
    end

    def title
      style(:title) || "Shoes"
    end

    def app_width
      (style(:width) || 480).to_i
    end

    def app_height
      (style(:height) || 420).to_i
    end

    def init
      UI::L.init unless @initialized
      @initialized = true

      @window = UI::L.new_window(title, app_width, app_height, 0)
      UI::L.window_set_margined(@window, 0)
      UI::L.window_on_closing(@window) do
        quit
        0
      end

      @canvas = Canvas.new
      @canvas.on_draw = method(:on_draw)
      @canvas.on_mouse = method(:on_mouse)
      @canvas.on_key = method(:on_key)
      @canvas.on_crossed = method(:on_crossed)

      # An area needs a stretchy box around it or libui gives it no size.
      box = UI::L.new_vertical_box
      UI::L.box_append(box, @canvas.area, 1)
      UI::L.window_set_child(@window, box)
    end

    def run
      UI::L.control_show(@window)
      @running = true
      arm_timers
      install_test_hooks
      UI::L.main
      # libui aborts on exit if a control is still alive, so tear the window
      # down explicitly. Destroying the window destroys its children. Cached
      # image paths count as live objects too.
      Image.free_all_paths
      UI::L.control_destroy(@window) if @window
      @window = nil
      # Anything that runs after the window is gone -- at_exit handlers, an
      # app's own shutdown code -- must not touch the area again. Queueing a
      # redraw on a destroyed area segfaults.
      @canvas = nil
      UI::L.uninit if @initialized
    end

    # Hooks for automated testing: run the app for a fixed time, optionally
    # capture the screen, then quit. Used by Clogs' own visual tests and handy
    # for any Shoes app under CI.
    #
    #   CLOGS_EXIT_AFTER_MS=800 CLOGS_SCREENSHOT=out.png ruby app.rb
    def install_test_hooks
      ms = ENV["CLOGS_EXIT_AFTER_MS"]&.to_i
      return if ms.nil? || ms <= 0

      @exit_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + ms / 1000.0
      add_timer(ms, repeat: false) { finish_test_run }
    end

    # A busy app -- an animation that cannot keep up on a slow machine, say --
    # can starve a one-shot timer indefinitely. The deadline is therefore also
    # checked from the paint callback, so the run ends as long as anything is
    # still happening at all.
    def check_test_deadline
      return unless @exit_deadline
      return if Process.clock_gettime(Process::CLOCK_MONOTONIC) < @exit_deadline

      finish_test_run
    end

    def finish_test_run
      return if @exit_deadline.nil?

      @exit_deadline = nil
      capture_screenshot(ENV["CLOGS_SCREENSHOT"]) if ENV["CLOGS_SCREENSHOT"]
      quit
    end

    def capture_screenshot(path)
      # ImageMagick's `import` is the only dependency-free way to do this on
      # X11; elsewhere the screenshot is simply skipped.
      system("import", "-window", "root", path, err: File::NULL)
    end

    def destroy
      return if @destroyed

      @destroyed = true
      UI::L.quit
    end

    def quit
      notify("destroy")
      destroy
    end

    def document_root=(root)
      @document_root = root
      root.app = self
      needs_layout!
    end

    def needs_layout!
      @needs_layout = true
      redraw!
    end

    def redraw!
      return if @destroyed

      @canvas&.redraw
    end

    # ---- painting -----------------------------------------------------

    BACKGROUND = [255, 255, 255, 255].freeze

    def on_draw(painter, _params)
      check_test_deadline
      painter.fill_rect(0, 0, painter.width, painter.height, BACKGROUND)
      return unless @document_root

      if @needs_layout || @last_width != painter.width || @last_height != painter.height
        @document_root.measure(painter.width, painter.height)
        @last_width = painter.width
        @last_height = painter.height
        @needs_layout = false
      end
      @document_root.paint(painter, 0, 0)
      open_list_boxes.each { |lb| lb.draw_overlay(painter) }
    rescue StandardError => e
      report_error(e)
    end

    def open_list_boxes
      return [] unless @document_root

      found = []
      @document_root.each_peer { |peer| found << peer if peer.is_a?(ListBox) && peer.open? }
      found
    end

    # ---- input --------------------------------------------------------

    def peers_at(x, y)
      return [] unless @document_root

      hits = []
      @document_root.each_peer { |peer| hits << peer if peer.contains?(x, y) }
      hits
    end

    def topmost_clickable(x, y)
      peers_at(x, y).reverse.find(&:clickable?)
    end

    def on_mouse(event)
      @mouse_state = [event.button_down? ? 1 : 0, event.x.round, event.y.round]
      Shoes::DisplayService.mouse_state = @mouse_state if Shoes::DisplayService.respond_to?(:mouse_state=)

      update_hover(event)
      notify_subscribers("motion", event.x.round, event.y.round,
        event.modifiers.anybits?(UI::MOD_CTRL), event.modifiers.anybits?(UI::MOD_SHIFT))

      if event.down.positive?
        handle_press(event)
      elsif event.up.positive?
        handle_release(event)
      end
    rescue StandardError => e
      report_error(e)
    end

    def handle_press(event)
      # A click outside an open drop-down closes it.
      open_list_boxes.each { |lb| lb.close unless lb.contains?(event.x, event.y) || lb.overlay_contains?(event.x, event.y) }

      target = open_list_boxes.find { |lb| lb.overlay_contains?(event.x, event.y) } ||
        topmost_clickable(event.x, event.y)
      set_focus(target&.focusable? ? target : nil)
      target&.on_click(event.x, event.y, event.down)
      @pressed = target
      notify_subscribers("click", event.down, event.x.round, event.y.round)
    end

    def handle_release(event)
      # Shoes bubbles a click up through the enclosing slots: clicking the
      # text inside a button-like widget still fires the widget's handler.
      peer = @pressed
      @pressed = nil
      while peer
        peer.on_release(event.x, event.y, event.up)
        peer = peer.parent
      end
      notify_subscribers("release", event.up, event.x.round, event.y.round)
    end

    def update_hover(event)
      target = peers_at(event.x, event.y).reverse.find { |p| p.clickable? || p.is_a?(Control) }
      return if target == @hovered

      if @hovered
        @hovered.on_mouse_leave if @hovered.respond_to?(:on_mouse_leave)
        @hovered.notify("leave")
      end
      @hovered = target
      if target
        target.on_mouse_enter if target.respond_to?(:on_mouse_enter)
        target.notify("hover")
      end
      notify_subscribers("hover") if target
      notify_subscribers("leave") unless target
    end

    def set_focus(peer)
      return if peer == @focused

      @focused&.focused = false
      @focused&.focus_lost
      @focused = peer
      return unless peer

      peer.focused = true
      peer.focus_gained
    end

    def on_key(event)
      return false if @destroyed

      if @focused&.on_key(event)
        redraw!
        return true
      end
      name = key_name(event)
      return false unless name && !event.up

      # Shoes delivers printable characters as strings and everything else --
      # named keys and modifier combinations -- as symbols: "a" but :backspace,
      # :home, :control_c. Newline stays a string, as Shoes 3 had it.
      name = name.to_sym unless name.length == 1 || name == "\n"
      notify_subscribers("keypress", name)
      true
    rescue StandardError => e
      report_error(e)
      false
    end

    # Shoes reports keys as single characters, names like "up", or
    # "control_x" style combinations.
    def key_name(event)
      base = if event.ext
        event.ext.to_s
      elsif event.char
        case event.char
        when "\b", "\x7F" then "backspace"
        when "\r", "\n" then "\n"
        when "\t" then "tab"
        when " " then " "
        else event.char
        end
      end
      return nil unless base

      mods = []
      mods << "control" if event.ctrl?
      mods << "alt" if event.alt?
      mods << "shift" if event.shift? && base.length > 1
      mods.empty? ? base : (mods + [base]).join("_")
    end

    def on_crossed(left)
      return unless left

      @hovered&.on_mouse_leave if @hovered.respond_to?(:on_mouse_leave)
      @hovered = nil
      redraw!
    end

    # ---- subscriptions and timers -------------------------------------

    def subscriptions
      found = []
      @document_root&.each_peer { |peer| found << peer if peer.is_a?(SubscriptionItem) }
      found
    end

    def notify_subscribers(api_name, *args)
      subscriptions.each do |sub|
        sub.notify(api_name, *args) if sub.api_name == api_name
      end
    end

    # libui's timer callback returns nonzero to keep firing.
    #
    # Timers may only be armed once the main loop is running: Shoes programs
    # routinely call `animate` or `every` while the app is still being built,
    # and handing libui a timer before then crashes it. Queue those and arm
    # them when the loop starts.
    def add_timer(interval_ms, repeat: true, &block)
      interval_ms = 1 if interval_ms.to_i < 1
      unless @running
        (@pending_timers ||= []) << [interval_ms, repeat, block]
        return
      end

      # Arming a timer from inside a libui callback re-enters the loop's own
      # bookkeeping and crashes; queue_main defers it to a safe point. Shoes
      # programs create timers from event handlers all the time.
      UI::L.queue_main { arm_timer(interval_ms, repeat, block) }
    end

    def arm_timers
      pending = @pending_timers || []
      @pending_timers = nil
      pending.each { |interval, repeat, block| arm_timer(interval, repeat, block) }
    end

    # The libui binding builds the callback itself when given a block, which
    # is the only way to get the `int (*)(void *)` signature right; a
    # hand-rolled closure with the wrong arity corrupts the stack.
    # Returning nonzero keeps the timer running.
    def arm_timer(interval_ms, repeat, block)
      UI::L.timer(interval_ms) do
        if @destroyed
          0
        else
          begin
            block.call
          rescue StandardError => e
            report_error(e)
          end
          repeat ? 1 : 0
        end
      end
    end

    # ---- builtins -----------------------------------------------------

    def builtin(cmd, args)
      case cmd.to_s
      when "alert" then Dialogs.alert(@window, args[0])
      when "confirm" then Dialogs.confirm(@window, args[0])
      when "ask" then Dialogs.ask(@window, args[0])
      when "ask_open_file" then Dialogs.open_file(@window)
      when "ask_save_file" then Dialogs.save_file(@window)
      when "ask_open_folder" then Dialogs.open_folder(@window)
      when "ask_color" then nil
      when "font" then nil
      end
    rescue StandardError => e
      report_error(e)
      nil
    end

    def report_error(error)
      warn "Clogs error: #{error.class}: #{error.message}"
      warn error.backtrace.first(12).join("\n") if error.backtrace
    end
  end
end
