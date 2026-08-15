# frozen_string_literal: true

require "fox16"

module Clogs
  # Bitmaps, blitted.
  #
  # This is the drawable the two backends differ over most. libui exports no
  # draw-image call, so the libui backend decodes a PNG with chunky_png, run
  # length encodes it, and paints it as filled rectangles -- tens of thousands
  # of them for a photograph, every frame. FOX has `FXDC#drawImage`, so an
  # image is decoded once by the toolkit's own loader and then blitted.
  #
  # The catch is alpha. Xlib has no source alpha, so FOX's blit is opaque and
  # cannot composite. What it does have is a *shape mask*: an FXIcon carries a
  # one-bit stencil derived from the source's alpha channel, and `drawIcon`
  # honours it. So a cutout keeps its silhouette -- Hackety Hack's splash hand
  # is a rounded blob on a black background, not a white square -- but a soft
  # antialiased edge becomes a hard one, and a pixel that is half transparent
  # is drawn fully opaque rather than blended with what is under it. This is
  # the one place where the libui backend is unambiguously better, because
  # Cairo composites properly. See docs/fox_vs_libui.md.
  class Image < Drawable
    class << self
      def cache
        @cache ||= {}
      end

      # FOX images hold a server-side pixmap, so they are freed explicitly when
      # the app shuts down rather than left to the Ruby GC.
      def with_live_paths
        @with_live_paths ||= []
      end

      def free_all_paths
        cache.each_value { |entry| entry&.first&.destroy }
        cache.clear
        with_live_paths.clear
      end

      # Decoded and scaled, cached by [path, width, height]. The value is
      # [image, has_transparency] or nil.
      def image_for(url, width, height)
        key = [url, width, height]
        return cache[key] if cache.key?(key)

        cache[key] = build_image(url, width, height)
      end

      # Every format FOX itself decodes. The libui backend can only read PNG,
      # because chunky_png can only read PNG; it shells out to ImageMagick for
      # anything else and gives up if that is not installed.
      #
      # The icon classes are loaded rather than the plain image ones: an FXIcon
      # is an FXImage that also builds a shape mask, so one decode serves both
      # the masked and the unmasked blit.
      LOADERS = {
        ".png" => "FXPNGIcon", ".jpg" => "FXJPGIcon", ".jpeg" => "FXJPGIcon",
        ".gif" => "FXGIFIcon", ".bmp" => "FXBMPIcon", ".ico" => "FXICOIcon",
        ".tif" => "FXTIFIcon", ".tiff" => "FXTIFIcon", ".ppm" => "FXPPMIcon",
        ".pcx" => "FXPCXIcon", ".tga" => "FXTGAIcon", ".xpm" => "FXXPMIcon"
      }.freeze

      def build_image(url, width, height)
        path = local_path(url)
        return nil unless path && File.exist?(path)

        loader = LOADERS[File.extname(path).downcase]
        return nil unless loader

        image = Fox.const_get(loader).new(
          App.fox_app, File.binread(path), 0,
          Fox::IMAGE_KEEP | Fox::IMAGE_OWNED | Fox::IMAGE_SHMI | Fox::IMAGE_SHMP
        )
        image.create
        transparent = transparent?(image)
        # Shoes sizes images by asking for a width and a height; FOX resamples
        # the pixels and the shape mask together.
        if width&.positive? && height&.positive? && (width != image.width || height != image.height)
          image.scale(width, height, 1)
          image.create
        end
        [image, transparent]
      rescue StandardError => e
        warn "Clogs: could not load image #{url.inspect}: #{e.message}"
        nil
      end

      # Only images that actually have transparent pixels pay for the masked
      # blit; photographs and screenshots take the plain one.
      def transparent?(image)
        pixels = image.pixels
        return false unless pixels.is_a?(Array)

        pixels.any? { |v| (v >> 24) != 0xff }
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
        dest = File.join(Dir.tmpdir, "clogs-img-#{Digest::SHA256.hexdigest(url)[0, 16]}#{File.extname(url)}")
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
      @image, @transparent = self.class.image_for(style(:url), req_w, req_h)

      if @image
        @width = @image.width
        @height = @image.height
      else
        @width = req_w || 0
        @height = req_h || 0
      end
    end

    def draw(painter, x, y)
      unless @image
        painter.stroke_rect(x + 0.5, y + 0.5, [@width - 1, 1].max, [@height - 1, 1].max,
          [200, 200, 200, 255], thickness: 1)
        return
      end
      return unless painter.visible?(x, y, @width, @height)

      if @transparent
        painter.draw_icon(@image, x, y)
      else
        painter.draw_image(@image, x, y)
      end
    end

    # The libui backend keeps live path objects per image and has to free them
    # before uninit; there is nothing per-drawable to free here, because the
    # decoded image belongs to the class-level cache.
    def free_paths; end

    def destroy_self
      @image = nil
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
