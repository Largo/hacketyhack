# frozen_string_literal: true

require_relative "../drawable"

module Clogs
  # Bitmaps.
  #
  # This is the one place where libui really lets Shoes down. libui-ng has
  # `uiImage`, but the only thing that can display one is a table cell -- the
  # released library exports no `uiDrawImage`, so there is no way to blit a
  # bitmap into an area. (Clogs checks for it at runtime and uses it if a
  # future build provides one.)
  #
  # The fallback is the same trick glimmer-dsl-libui uses: turn the image into
  # filled rectangles. Clogs run-length encodes each row first, so flat art --
  # icons, logos, screenshots of text -- costs a handful of rectangles per row
  # instead of one per pixel. Photographs are genuinely slow and are best
  # avoided until libui grows a draw-image call.
  class Image < Drawable
    class << self
      def cache
        @cache ||= {}
      end

      # Images holding live libui path objects. libui aborts at uninit if any
      # path is still alive, so the app frees them all on teardown -- including
      # images in subtrees that were removed from the document.
      def with_live_paths
        @with_live_paths ||= []
      end

      def free_all_paths
        with_live_paths.dup.each(&:free_paths)
      end

      # Load an image and reduce it to per-row colour runs at the requested
      # size. Cached by [path, width, height].
      def runs_for(url, width, height)
        key = [url, width, height]
        cache[key] ||= build_runs(url, width, height)
      end

      # Every rectangle is a separate libui fill, so a photograph can cost tens
      # of thousands of draw calls per frame and starve the event loop. Flat
      # art stays well under this; anything that does not gets sampled at a
      # coarser resolution until it fits, trading sharpness for a UI that still
      # responds. None of this is needed once libui exports uiDrawImage.
      RUN_BUDGET = 40_000

      def build_runs(url, width, height)
        pixels, src_w, src_h = load_pixels(url)
        return nil unless pixels

        width = src_w if width.nil? || width <= 0
        height = src_h if height.nil? || height <= 0

        runs = encode(pixels, src_w, src_h, width, height, 1)
        step = 1
        while runs.size > RUN_BUDGET && step < 8
          step *= 2
          runs = encode(pixels, src_w, src_h, width, height, step)
        end
        [runs, width, height]
      end

      # Walk the target rectangle at `step` pixels at a time, emitting one
      # rectangle per run of equal colour.
      def encode(pixels, src_w, src_h, width, height, step)
        runs = []
        0.step(height - 1, step) do |y|
          sy = src_h == height ? y : (y * src_h / height)
          row_start = sy * src_w
          run_color = nil
          run_x = 0
          0.step(width - 1, step) do |x|
            sx = src_w == width ? x : (x * src_w / width)
            color = pixels[row_start + sx]
            next if color == run_color

            runs << [run_x, y, x - run_x, run_color] if run_color && run_color[3].positive?
            run_color = color
            run_x = x
          end
          runs << [run_x, y, width - run_x, run_color] if run_color && run_color[3].positive?
        end
        compact(runs, step)
      end

      # Rows that repeat identically become one taller rectangle. Flat art
      # collapses dramatically here.
      def compact(runs, step = 1)
        by_key = {}
        result = []
        runs.each do |x, y, w, color|
          key = [x, w, color]
          prev = by_key[key]
          if prev && prev[1] + prev[3] == y
            prev[3] += step
          else
            rect = [x, y, w, step, color]
            result << rect
            by_key[key] = rect
          end
        end
        result
      end

      def load_pixels(url)
        path = local_path(url)
        return nil unless path && File.exist?(path)

        png = png_canvas(path)
        return nil unless png

        pixels = Array.new(png.width * png.height)
        png.height.times do |y|
          png.width.times do |x|
            v = png[x, y]
            pixels[y * png.width + x] = [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]
          end
        end
        [pixels, png.width, png.height]
      rescue StandardError => e
        warn "Clogs: could not load image #{url.inspect}: #{e.message}"
        nil
      end

      def png_canvas(path)
        require "chunky_png"
        return ChunkyPNG::Canvas.from_file(path) if File.extname(path).downcase == ".png"

        converted = convert_to_png(path)
        converted ? ChunkyPNG::Canvas.from_file(converted) : nil
      end

      # chunky_png only reads PNG. Anything else goes through ImageMagick if it
      # happens to be installed.
      def convert_to_png(path)
        require "tmpdir"
        out = File.join(Dir.tmpdir, "clogs-#{File.basename(path)}.png")
        return out if File.exist?(out)
        return nil unless system("which convert > /dev/null 2>&1")

        system("convert", path, out) ? out : nil
      end

      def local_path(url)
        return nil if url.nil?

        url = url.to_s
        return url unless url.start_with?("http://", "https://")

        download(url)
      end

      def download(url)
        require "tmpdir"
        require "digest"
        require "open-uri"
        dest = File.join(Dir.tmpdir, "clogs-img-#{Digest::SHA256.hexdigest(url)[0, 16]}")
        return dest if File.exist?(dest)

        URI.parse(url).open { |io| File.binwrite(dest, io.read) }
        dest
      rescue StandardError => e
        warn "Clogs: could not fetch #{url}: #{e.message}"
        nil
      end
    end

    def measure(available_width, available_height = nil)
      req_w = requested_width(available_width)
      req_h = requested_height(available_height)
      loaded = self.class.runs_for(style(:url), req_w, req_h)
      if loaded
        @runs, @width, @height = loaded
      else
        @runs = nil
        @width = req_w || 0
        @height = req_h || 0
      end
    end

    def draw(painter, x, y)
      unless @runs
        # Nothing loaded: a light placeholder box beats an invisible hole.
        painter.stroke_rect(x + 0.5, y + 0.5, [@width - 1, 1].max, [@height - 1, 1].max,
          [200, 200, 200, 255], thickness: 1)
        return
      end
      return unless painter.visible?(x, y, @width, @height)

      # A photograph is thousands of runs, and rebuilding a path per run per
      # frame is what makes bitmaps slow. Build one path and one brush per
      # colour, once, in image-local coordinates; every later frame is just a
      # translate and one fill call per colour.
      painter.save do |p|
        p.translate(x, y)
        color_paths.each { |brush, path| p.fill_path(path, brush) }
      end
    end

    def color_paths
      return @color_paths if @color_paths && @color_paths_runs.equal?(@runs)

      free_paths
      by_color = Hash.new { |h, k| h[k] = [] }
      @runs.each { |rx, ry, rw, rh, color| by_color[color] << [rx, ry, rw, rh] }
      @color_paths = by_color.map do |color, rects|
        path = Path.new(Painter::WINDING)
        rects.each { |r| path.rect(*r) }
        path.end!
        [UI.solid_brush(color), path]
      end
      @color_paths_runs = @runs
      Image.with_live_paths << self
      @color_paths
    end

    def free_paths
      @color_paths&.each { |_brush, path| path.free }
      @color_paths = nil
      @color_paths_runs = nil
      Image.with_live_paths.delete(self)
    end

    def destroy_self
      free_paths
      super
    end

    def clickable?
      !style(:click).nil?
    end

    def on_release(x, y, _button)
      notify("click") if contains?(x, y) && style(:click)
    end
  end
end
