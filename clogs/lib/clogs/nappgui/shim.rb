# frozen_string_literal: true

require "fiddle"

module Clogs
  # The Ruby side of clogs/ext/nappgui/clogs_nappgui.cpp.
  #
  # NAppGUI is a C SDK, so unlike Qt this shim is not here for want of a
  # binding -- Fiddle could call most of draw2d directly. It is here for two
  # narrower reasons:
  #
  #   * NAppGUI wants to own main(). Its `osmain` macro *defines* main() and
  #     hands the process to the SDK, which a Ruby program cannot do. The macro
  #     expands to `osmain_imp`, an ordinary exported function, so the shim
  #     calls that and the SDK runs inside a process Ruby started.
  #   * Its events arrive as structs behind `event_params` and its listeners
  #     are objects rather than function pointers, so Fiddle would have to
  #     encode NAppGUI's struct layouts in Ruby and re-encode them at every
  #     release.
  #
  # The consequence Ruby has to live with is that draw2d does not exist until
  # osmain_imp has started it: no font, window or image may be created before
  # the create callback fires. `started?` is what the rest of the backend
  # checks.
  module Shim
    class NotBuilt < StandardError; end

    LIBRARY = File.expand_path(
      "../../../ext/nappgui/libclogs_nappgui.#{RbConfig::CONFIG["host_os"] =~ /darwin/ ? "dylib" : "so"}",
      __dir__
    )

    VOID = Fiddle::TYPE_VOID
    PTR = Fiddle::TYPE_VOIDP
    INT = Fiddle::TYPE_INT
    # Packed 0xRRGGBBAA colours overflow a signed int.
    UINT = Fiddle::TYPE_UINT
    # draw2d is a single-precision API throughout; passing doubles would only
    # mean converting them twice.
    FLT = Fiddle::TYPE_FLOAT

    # name => [argument types, return type]
    FUNCTIONS = {
      version: [[], PTR],
      run: [[], INT],
      quit: [[], VOID],
      started: [[], INT],

      on_create: [[PTR], VOID],
      on_paint: [[PTR], VOID],
      on_mouse: [[PTR], VOID],
      on_key: [[PTR], VOID],
      on_crossed: [[PTR], VOID],
      on_close: [[PTR], VOID],
      on_timer: [[PTR], VOID],

      window_new: [[PTR, INT, INT], PTR],
      window_view: [[PTR], PTR],
      window_show: [[PTR], VOID],
      window_destroy: [[PTR], VOID],
      view_update: [[PTR], VOID],

      timer_new: [[INT, INT, INT], VOID],
      timer_stop: [[INT], VOID],

      clear: [[PTR, UINT], VOID],
      ctx_bitmap: [[INT, INT], PTR],
      ctx_to_image: [[PTR], PTR],
      antialias: [[PTR, INT], VOID],
      matrix: [[PTR, FLT, FLT, FLT, FLT, FLT, FLT], VOID],
      fill_color: [[PTR, UINT], VOID],
      fill_linear: [[PTR, UINT, UINT, FLT, FLT, FLT, FLT], VOID],
      line_style: [[PTR, UINT, FLT, INT, INT, PTR, INT], VOID],
      rect: [[PTR, INT, FLT, FLT, FLT, FLT], VOID],
      ellipse: [[PTR, INT, FLT, FLT, FLT, FLT], VOID],
      line: [[PTR, FLT, FLT, FLT, FLT], VOID],
      polygon: [[PTR, INT, PTR, INT], VOID],
      polyline: [[PTR, INT, PTR, INT], VOID],

      font: [[PTR, FLT, INT, INT, INT, INT], PTR],
      font_destroy: [[PTR], VOID],
      font_extents: [[PTR, PTR, PTR, PTR], VOID],
      draw_text: [[PTR, PTR, PTR, FLT, FLT, UINT], VOID],

      image_load: [[PTR], PTR],
      image_size: [[PTR, PTR, PTR], VOID],
      image_scaled: [[PTR, INT, INT], PTR],
      image_free: [[PTR], VOID],
      draw_image: [[PTR, PTR, FLT, FLT], VOID],

      alert: [[PTR, PTR], VOID],
      confirm: [[PTR, PTR], INT],
      ask: [[PTR, PTR], PTR],
      ask_open_file: [[PTR], PTR],
      ask_save_file: [[PTR], PTR],
      ask_open_folder: [[PTR], PTR]
    }.freeze

    # draw2d's drawop_t, which every shape call takes.
    OP_STROKE = 1
    OP_FILL = 2
    OP_STROKE_FILL = 3
    OP_FILL_STROKE = 4

    class << self
      def available?
        File.exist?(LIBRARY)
      end

      def handle
        @handle ||= begin
          unless available?
            raise NotBuilt, "Clogs' NAppGUI shim is not built. Run clogs/ext/nappgui/build.sh " \
                            "with NAPPGUI_SRC pointing at a built NAppGUI checkout; " \
                            "see docs/backends.md."
          end

          Fiddle.dlopen(LIBRARY)
        end
      end

      def load!
        return if @loaded

        FUNCTIONS.each do |name, (args, ret)|
          fn = Fiddle::Function.new(handle["clogs_nap_#{name}"], args, ret)
          define_singleton_method(name) { |*a| fn.call(*a) }
        end
        @loaded = true
      end

      # True once osmain_imp has started the SDK. Nothing draw2d owns -- a
      # font, a window, an image -- may be built before this answers true.
      def started?
        @loaded && !started.zero?
      end

      # Closures handed to C must outlive the call, and there are a bounded
      # number of them: one per event kind, plus the timer dispatcher.
      def callback(ret, args, &block)
        closure = Fiddle::Closure::BlockCaller.new(ret, args, &block)
        (@closures ||= []) << closure
        closure
      end

      def out_ints(&block)
        a = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT)
        b = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT)
        block.call(a, b)
        [a[0, Fiddle::SIZEOF_INT].unpack1("l"), b[0, Fiddle::SIZEOF_INT].unpack1("l")]
      end

      def out_floats(&block)
        a = Fiddle::Pointer.malloc(Fiddle::SIZEOF_FLOAT)
        b = Fiddle::Pointer.malloc(Fiddle::SIZEOF_FLOAT)
        block.call(a, b)
        [a[0, Fiddle::SIZEOF_FLOAT].unpack1("f"), b[0, Fiddle::SIZEOF_FLOAT].unpack1("f")]
      end

      def string(pointer)
        return nil if pointer.nil? || pointer.null?

        pointer.to_s
      end
    end
  end
end
