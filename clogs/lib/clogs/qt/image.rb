# frozen_string_literal: true

require_relative "shim"

module Clogs
  # Bitmaps, blitted and composited.
  #
  # Qt decodes every common format itself, scales with a smooth filter and
  # keeps the alpha channel, which QPainter then composites properly. Like the
  # wx backend this is the blit FOX has without the alpha FOX loses, and the
  # compositing libui has without the tens of thousands of rectangles libui
  # needs to get a picture onto the screen at all.
  class Image < Drawable
    class << self
      def cache
        @cache ||= {}
      end

      # Qt images are C++ objects the shim owns; they are freed when the app
      # tears down rather than left to the Ruby GC.
      def with_live_paths
        @with_live_paths ||= []
      end

      def free_all_paths
        cache.each_value { |handle| Shim.image_free(handle) if handle }
        cache.clear
        with_live_paths.clear
      end

      def image_for(url, width, height)
        key = [url, width, height]
        return cache[key] if cache.key?(key)

        cache[key] = build_image(url, width, height)
      end

      def build_image(url, width, height)
        path = local_path(url)
        return nil unless path && File.exist?(path)

        handle = Shim.image_load(path)
        if handle.nil? || handle.null?
          warn "Clogs: could not load image #{url.inspect}"
          return nil
        end

        w, h = Shim.out_ints { |a, b| Shim.image_size(handle, a, b) }
        if width&.positive? && height&.positive? && (width != w || height != h)
          scaled = Shim.image_scaled(handle, width, height)
          Shim.image_free(handle)
          handle = scaled
        end
        handle
      rescue StandardError => e
        warn "Clogs: could not load image #{url.inspect}: #{e.message}"
        nil
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
      @image = self.class.image_for(style(:url), req_w, req_h)
      if @image
        @width, @height = Shim.out_ints { |a, b| Shim.image_size(@image, a, b) }
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

      painter.draw_image(@image, x, y, @width, @height)
    end

    # The libui backend keeps live path objects per image and frees them before
    # uninit; the decoded image here belongs to the class-level cache.
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
