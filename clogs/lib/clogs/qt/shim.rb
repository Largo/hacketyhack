# frozen_string_literal: true

require "fiddle"

module Clogs
  # The Ruby side of clogs/ext/qt/clogs_qt.cpp.
  #
  # Qt is C++, and the only Ruby binding on rubygems is qtbindings, which is
  # Qt 4.8 and cannot be built on a distribution that has dropped Qt 4. So this
  # backend ships its own C surface over Qt and calls it through Fiddle -- the
  # same arrangement libui offers as a library, and the reason the rest of this
  # backend reads like the others.
  module Shim
    class NotBuilt < StandardError; end

    LIBRARY = File.expand_path(
      "../../../ext/qt/libclogs_qt.#{RbConfig::CONFIG["host_os"] =~ /darwin/ ? "dylib" : "so"}",
      __dir__
    )

    VOID = Fiddle::TYPE_VOID
    PTR = Fiddle::TYPE_VOIDP
    INT = Fiddle::TYPE_INT
    # Packed 0xRRGGBBAA colours overflow a signed int.
    UINT = Fiddle::TYPE_UINT
    DBL = Fiddle::TYPE_DOUBLE

    # name => [argument types, return type]
    FUNCTIONS = {
      version: [[], PTR],
      init: [[], INT],
      run: [[], INT],
      quit: [[], VOID],
      process_events: [[], VOID],

      on_paint: [[PTR], VOID],
      on_mouse: [[PTR], VOID],
      on_key: [[PTR], VOID],
      on_crossed: [[PTR], VOID],
      on_close: [[PTR], VOID],
      on_timer: [[PTR], VOID],

      window_new: [[PTR, INT, INT], PTR],
      window_canvas: [[PTR], PTR],
      window_show: [[PTR], VOID],
      window_destroy: [[PTR], VOID],
      canvas_update: [[PTR], VOID],

      timer_new: [[INT, INT, INT], PTR],
      timer_stop: [[PTR], VOID],

      save: [[PTR], VOID],
      restore: [[PTR], VOID],
      translate: [[PTR, DBL, DBL], VOID],
      rotate: [[PTR, DBL], VOID],
      scale: [[PTR, DBL, DBL], VOID],
      shear: [[PTR, DBL, DBL], VOID],
      clip_rect: [[PTR, DBL, DBL, DBL, DBL], VOID],
      fill_rect: [[PTR, DBL, DBL, DBL, DBL, UINT], VOID],
      fill_path: [[PTR, PTR, INT, UINT, INT], VOID],
      fill_path_gradient: [[PTR, PTR, INT, INT, DBL, DBL, DBL, DBL, UINT, UINT], VOID],
      stroke_path: [[PTR, PTR, INT, UINT, DBL, INT, INT, PTR, INT], VOID],
      draw_text: [[PTR, DBL, DBL, PTR, PTR, DBL, INT, INT, INT, INT, UINT], VOID],
      text_extent: [[PTR, PTR, DBL, INT, INT, PTR, PTR], VOID],

      image_load: [[PTR], PTR],
      image_size: [[PTR, PTR, PTR], VOID],
      image_scaled: [[PTR, INT, INT], PTR],
      image_free: [[PTR], VOID],
      draw_image: [[PTR, PTR, DBL, DBL, DBL, DBL], VOID],

      alert: [[PTR, PTR], VOID],
      confirm: [[PTR, PTR], INT],
      ask: [[PTR, PTR], PTR],
      ask_open_file: [[PTR], PTR],
      ask_save_file: [[PTR], PTR],
      ask_open_folder: [[PTR], PTR]
    }.freeze

    class << self
      def available?
        File.exist?(LIBRARY)
      end

      def handle
        @handle ||= begin
          unless available?
            raise NotBuilt, "Clogs' Qt shim is not built. Run clogs/ext/qt/build.sh " \
                            "(needs Qt 6's development files); see docs/backends.md."
          end

          Fiddle.dlopen(LIBRARY)
        end
      end

      def load!
        return if @loaded

        FUNCTIONS.each do |name, (args, ret)|
          fn = Fiddle::Function.new(handle["clogs_qt_#{name}"], args, ret)
          define_singleton_method(name) { |*a| fn.call(*a) }
        end
        @loaded = true
      end

      # Closures handed to C must outlive the call, and there are a bounded
      # number of them -- one per event kind, plus the timer dispatcher.
      def callback(ret, args, &block)
        closure = Fiddle::Closure::BlockCaller.new(ret, args, &block)
        (@closures ||= []) << closure
        closure
      end

      # Qt fills two ints or two doubles through pointers; these unpack them.
      def out_ints(&block)
        a = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT)
        b = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT)
        block.call(a, b)
        [a[0, Fiddle::SIZEOF_INT].unpack1("l"), b[0, Fiddle::SIZEOF_INT].unpack1("l")]
      end

      def out_doubles(&block)
        a = Fiddle::Pointer.malloc(Fiddle::SIZEOF_DOUBLE)
        b = Fiddle::Pointer.malloc(Fiddle::SIZEOF_DOUBLE)
        block.call(a, b)
        [a[0, Fiddle::SIZEOF_DOUBLE].unpack1("d"), b[0, Fiddle::SIZEOF_DOUBLE].unpack1("d")]
      end

      def string(pointer)
        return nil if pointer.nil? || pointer.null?

        pointer.to_s
      end
    end
  end
end
