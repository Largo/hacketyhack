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

# Shoes' `clear` empties a slot of its *contents*. In Lacci an `animate`,
# `every` or `timer` is a Shoes::SubscriptionItem parented to the slot like any
# other drawable -- so a program that redraws itself with
#
#     animate(24) { clear { ... } }
#
# which is how Shoes animations have been written since Shoes 3, destroys the
# subscription that is calling it and stops dead after one frame. samples/Clock
# and samples/Arcs are both exactly that, and both drew a single frame.
#
# Subscriptions are not contents: in Shoes 3 an animation belonged to the app
# and was ended with `stop`, not by clearing the slot it happened to be written
# in. So they survive a clear, and everything else still goes.
class Shoes::Slot
  unless method_defined?(:__clogs_clear_all_children)
    alias_method :__clogs_clear_all_children, :clear

    def clear(&block)
      @children ||= []
      @children.dup.each do |child|
        child.destroy unless child.is_a?(Shoes::SubscriptionItem)
      end
      append(&block) if block_given?
      nil
    end
  end
end

# Destroying a slot has to destroy what is inside it. Lacci's Drawable#destroy
# unhooks only the drawable it is called on -- it removes itself from its
# parent, drops its subscriptions and unregisters its id, but never touches its
# own children. So clearing a slot that contains slots leaves every nested
# drawable alive: still registered, still subscribed to hover, leave, motion,
# parent, prop_change and destroy, and now unreachable.
#
# Nothing noticed while animations stopped after one frame. Once they run,
# `samples/Arcs.rb` -- ten `shape { arc ... }`, rebuilt forty times a second --
# orphaned ten arcs and sixty subscriptions per frame, and since Lacci finds a
# subscription to remove by scanning every subscription it holds, each frame
# cost more than the last: a second of animation took 2.5 seconds of work, then
# 7, then 15.
#
# Lacci's own main has since grown this same cascade (scarpe-team/scarpe
# 586c603, "Fix Slot#destroy to cascade to children"), reached here through
# the fork the Gemfile points at -- so, like every other shim in this file,
# this one steps aside when the installed Lacci already does the job.
# Released lacci 0.5.0 does not define Slot#destroy at all; the version that
# cascades defines it precisely to do so.
if Shoes::Slot.instance_method(:destroy).owner != Shoes::Slot
  class Shoes::Slot
    alias_method :__clogs_destroy_without_children, :destroy

    def destroy
      @children&.dup&.each do |child|
        child.destroy unless child.instance_variable_get(:@destroyed)
      end
      __clogs_destroy_without_children
    end
  end
end

# Cancelling a subscription costs Lacci a walk over every subscription it
# holds: the unsubscribe id says nothing about where the handler lives, so
# `unsub_from_events` searches the whole table for it, and leaves the emptied
# entries behind afterwards so the next search is no shorter.
#
# Nothing notices until something unsubscribes in bulk, and then everything
# does. Every Shoes drawable subscribes six times, so tearing down a slot
# unsubscribes six times per drawable in it -- and Hackety Hack rebuilds a
# whole tab that way. Opening the Home tab was destroying about eighty
# drawables against a table of some fourteen hundred entries: two thirds of a
# million hash steps, and about a second of the click.
#
# So remember where each subscription went, and cancel it in one step. Ids
# from before this file loaded are not in the index and fall back to the
# search. Dropping a bucket once it empties is safe -- Lacci re-creates them
# with `||=` on subscribe and reads them with `.compact` on dispatch -- and it
# is what keeps the table proportional to what is really subscribed rather
# than to everything that ever was.
module Clogs
  module IndexedSubscriptions
    def subscribe_to_event(event_name, event_target, &handler)
      unsub_id = super
      Clogs.subscription_index[unsub_id] = [event_name, event_target]
      unsub_id
    end

    def unsub_from_events(unsub_id)
      raise "Must provide an unsubscribe ID!" if unsub_id.nil?
      return unless Shoes::DisplayService.class_variable_defined?(:@@display_event_handlers)

      table = Shoes::DisplayService.class_variable_get(:@@display_event_handlers)
      where = Clogs.subscription_index.delete(unsub_id)
      return unsub_by_search(table, unsub_id) unless where

      event_name, target = where
      by_target = table[event_name]
      handlers = by_target && by_target[target]
      return nil unless handlers

      handlers.delete_if { |handler| handler[:unsub_id] == unsub_id }
      by_target.delete(target) if handlers.empty?
      nil
    end

    private

    def unsub_by_search(table, unsub_id)
      table.each_value do |by_target|
        by_target.delete_if do |_target, handlers|
          handlers.delete_if { |handler| handler[:unsub_id] == unsub_id }
          handlers.empty?
        end
      end
      nil
    end
  end

  def self.subscription_index
    @subscription_index ||= {}
  end
end
Shoes::DisplayService.singleton_class.prepend(Clogs::IndexedSubscriptions)

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

# Shoes 3 styles a run of text bold with `:weight => "bold"`, which the Shoes 3
# compatibility layer rewrites to Lacci's `:font_weight` -- but only for classes
# that declare it, and Lacci declares it on Shoes::Para and not on the inline
# text drawables. So `span("size", :weight => "bold")` was dropped with a
# warning, which is how Hackety Hack's syntax highlighting lost the bold on
# every method name, constant and class name it colours, in the editor and in
# the lessons alike.
%w[Span Link Em Strong Code Del Ins Sub Sup Bg Fg].each do |name|
  next unless Shoes.const_defined?(name)

  klass = Shoes.const_get(name)
  klass.shoes_styles(:font_weight) unless klass.shoes_style_name?(:font_weight)
end

# Lacci pairs `border` with a real Shoes::Border drawable, but `background`
# only records a `background_color` style on the slot and drops its options
# hash -- so no display drawable is ever created and nothing gets painted.
# Give backgrounds the same treatment borders already have: a drawable the
# display service pairs with a Clogs::Background slot decoration. Shoes 3
# backgrounds also carry geometry (`background "#cdc", :width => 38`) and are
# shown/hidden dynamically, so the drawable keeps its whole options hash and
# `background` returns it.
# Newer Lacci (as paired with Scarpe's webview display service) ships
# `Shoes::Background` itself as a real drawable class, making this shim both
# unnecessary and impossible to load -- reopening it `module Shoes::Background`
# below would raise TypeError against a class. Skip the whole shim there.
background_drawable_needed = !Shoes.const_defined?(:BackgroundDrawable) &&
  !(Shoes.const_defined?(:Background) && Shoes::Background.is_a?(Class))

if background_drawable_needed
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
end
