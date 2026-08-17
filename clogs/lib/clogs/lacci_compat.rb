# frozen_string_literal: true

# Small pieces of the Shoes API that Lacci 0.5.0 does not implement but that
# real Shoes programs use constantly. Each is defined only if the installed
# Lacci lacks it, so newer versions win.

# Lacci 0.5.0 binds a SubscriptionItem's callback twice: once in the
# per-event `case` in its initialize, and once more unconditionally right
# after it. Every animate/every/timer/hover callback would run twice per
# event -- an animation advances at double speed and pays double the work.
# The trailing generic bind is the redundant one, and its id is what ends up
# in @unsub_id, so undo exactly that one.
module Clogs
  module SubscriptionItemSingleBind
    def initialize(*args, **kwargs, &block)
      super
      unsub_id = instance_variable_get(:@unsub_id)
      if unsub_id
        unsub_shoes_event(unsub_id)
        instance_variable_set(:@unsub_id, nil)
      end
    end
  end
end
Shoes::SubscriptionItem.prepend(Clogs::SubscriptionItemSingleBind)

# Shoes lets you click a slot, but Lacci declares no `click` style for one, so
# nothing tells the display side which slots want a click and which are merely
# in the way. Clogs::Slot#clickable? reads exactly this style: without it every
# slot is a click target, and a slot covering another swallows its clicks.
Shoes::Slot.shoes_styles(:click) unless Shoes::Slot.shoes_style_name?(:click)

# Shoes lets an art drawable carry its own fill/stroke/strokewidth
# (`star ..., :fill => red`); Lacci 0.5.0 only takes those from the draw
# context.
%w[Star Rect Oval Line Arc Shape Arrow].each do |name|
  next unless Shoes.const_defined?(name)

  klass = Shoes.const_get(name)
  %i[fill stroke strokewidth].each do |style|
    klass.shoes_styles(style) unless klass.shoes_style_name?(style)
  end
end

# Lacci pairs `border` with a real Shoes::Border drawable, but `background`
# only records a `background_color` style on the slot and drops its options
# hash -- so no display drawable is ever created and nothing gets painted.
# Give backgrounds the same treatment borders already have: a drawable the
# display service pairs with a Clogs::Background slot decoration. Shoes 3
# backgrounds also carry geometry (`background "#cdc", :width => 38`) and are
# shown/hidden dynamically, so the drawable keeps its whole options hash and
# `background` returns it.
unless Shoes.const_defined?(:BackgroundDrawable)
  class Shoes::BackgroundDrawable < Shoes::Drawable
    shoes_styles :fill, :curve

    opt_init_args :fill
    def initialize(*args, **kwargs)
      super
      create_display_drawable
    end
  end

  module Shoes::Background
    def background(color, options = {})
      self.background_color = color
      # Lacci only sets the creating app around DSL calls that go through
      # Shoes::App#method_missing, so set it here the same way.
      Shoes::Drawable.with_current_app(@app || Shoes.APPS.last) do
        Shoes::BackgroundDrawable.new(color, **options.transform_keys(&:to_sym))
      end
    end
  end
end

class Shoes::App
  # Lacci's own App lifecycle events (init/run/destroy, plus the
  # @watch_for_destroy and @watch_for_event_loop subscriptions set up in
  # #initialize) all bind and dispatch with no target, which broadcasts to
  # every Shoes::App in the process. That's harmless with one app, but with
  # Clogs' :multi_app support a second Shoes.app's init/run/destroy would
  # fire on every other running app too -- closing one window would destroy
  # them all. Default the target to this app's own linkable_id whenever a
  # caller doesn't specify one, so each app's lifecycle events stay its own.
  module Shoes3AppScopedLifecycleEvents
    def send_shoes_event(*args, event_name:, target: nil, **kwargs)
      super(*args, event_name: event_name, target: target || linkable_id, **kwargs)
    end

    def bind_shoes_event(event_name:, target: nil, &block)
      super(event_name: event_name, target: target || linkable_id, &block)
    end
  end
  prepend Shoes3AppScopedLifecycleEvents

  # `app.clear { ... }` empties the top-level slot and optionally refills it.
  # Animated Shoes programs redraw themselves this way on every frame.
  unless method_defined?(:clear)
    def clear(&block)
      root = instance_variable_get(:@document_root)
      root&.clear(&block)
    end
  end

  # `self.mouse` returns [button, x, y]. Clogs tracks the pointer as libui
  # reports it, per window -- so this has to look up *this* app's own peer,
  # not just whichever Clogs::App happened to be created most recently.
  unless method_defined?(:mouse)
    def mouse
      peer = Shoes::DisplayService.display_service&.query_display_drawable_for(linkable_id, nil_ok: true)
      peer&.mouse_state || [0, 0, 0]
    end
  end

  # Shoes 3's `visit` opened a URL; without a browser widget the best we can do
  # is hand it to the desktop.
  unless method_defined?(:visit)
    def visit(url)
      opener = case RUBY_PLATFORM
      when /darwin/ then "open"
      when /mingw|mswin/ then "start"
      else "xdg-open"
      end
      system(opener, url.to_s, out: File::NULL, err: File::NULL)
    end
  end

  # Shoes 3 read and wrote the system clipboard through the app.
  unless method_defined?(:clipboard)
    def clipboard
      Clogs::Clipboard.read
    end

    def clipboard=(text)
      Clogs::Clipboard.write(text.to_s)
    end
  end
end
