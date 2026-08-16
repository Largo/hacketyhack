# frozen_string_literal: true

require_relative "shim"

module Clogs
  # Bitmaps, blitted and composited.
  #
  # draw2d decodes the common formats, scales with a smooth filter and keeps
  # the alpha channel, which the platform then composites properly -- the blit
  # FOX has, with the alpha FOX loses, and without the tens of thousands of
  # rectangles libui needs to get a picture onto the screen at all.
  #
  # The one catch is NAppGUI's: an image cannot be decoded before the SDK is
  # running, and a Shoes program builds its drawable tree before that. So
  # loading is deferred to the first paint rather than done at measure time,
  # and the first measure answers from the size Shoes asked for.
  class Image < Drawable
    class << self
      def cache
        @cache ||= {}
      end

      def free_all
        cache.each_value { |handle| Shim.image_free(handle) if handle }
        cache.clear
      end

      # The libui backend caches paths per image and frees them before uninit;
      # here it is the decoded bitmaps that are the native objects.
      def free_all_paths
        free_all
      end

      def image_for(url, width, height)
        return nil unless Shim.started?

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
      @req_w = requested_width(available_width)
      @req_h = requested_height(available_height)
      @image = self.class.image_for(style(:url), @req_w, @req_h)
      if @image
        @width, @height = Shim.out_ints { |a, b| Shim.image_size(@image, a, b) }
      else
        # Before the SDK is up, or for an image that would not load: the size
        # Shoes asked for, so the layout around it is right either way.
        @width = @req_w || 0
        @height = @req_h || 0
      end
    end

    def draw(painter, x, y)
      # The tree is usually measured once before the loop starts, when nothing
      # can be decoded yet; the first paint is the first chance to try.
      if @image.nil?
        @image = self.class.image_for(style(:url), @req_w, @req_h)
        if @image
          @width, @height = Shim.out_ints { |a, b| Shim.image_size(@image, a, b) }
          app&.needs_layout!
        end
      end

      unless @image
        painter.stroke_rect(x + 0.5, y + 0.5, [@width - 1, 1].max, [@height - 1, 1].max,
          [200, 200, 200, 255], thickness: 1)
        return
      end
      return unless painter.visible?(x, y, @width, @height)

      painter.draw_image(@image, x, y, @width, @height)
    end

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
