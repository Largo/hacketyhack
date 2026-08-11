# frozen_string_literal: true

require_relative "drawable"
require_relative "app"

module Clogs
  # Lacci's half of the bargain: it hands us a Shoes drawable class name and an
  # id, and expects a display-side peer back. Everything after that happens
  # through events on that id.
  class DisplayService < Shoes::DisplayService
    class << self
      attr_accessor :instance
    end

    def initialize
      raise Shoes::SingletonError, "Clogs::DisplayService is a singleton!" if DisplayService.instance

      DisplayService.instance = self
      super()
    end

    # Shoes class name (minus namespace) => Clogs peer class.
    PEERS = {
      "App" => "App",
      "DocumentRoot" => "DocumentRoot",
      "Stack" => "Stack",
      "Flow" => "Flow",
      "Shape" => "Shape",
      "Mask" => "Mask",
      "Para" => "Para",
      "Link" => "Link",
      "LinkHover" => "Link",
      "Strong" => "Strong",
      "Em" => "Em",
      "Code" => "Code",
      "Del" => "Del",
      "Ins" => "Ins",
      "Sub" => "Sub",
      "Sup" => "Sup",
      "Span" => "Span",
      "Bg" => "Bg",
      "Fg" => "Fg",
      "Button" => "Button",
      "Check" => "Check",
      "Radio" => "Radio",
      "Progress" => "Progress",
      "EditLine" => "EditLine",
      "EditBox" => "EditBox",
      "ListBox" => "ListBox",
      "Image" => "Image",
      "Video" => "Video",
      "Arrow" => "Arrow",
      "Rect" => "Rect",
      "Oval" => "Oval",
      "Line" => "Line",
      "Star" => "Star",
      "Arc" => "Arc",
      "Background" => "Background",
      "BackgroundDrawable" => "Background",
      "Border" => "Border",
      "SubscriptionItem" => "SubscriptionItem"
    }.freeze

    def create_display_drawable_for(drawable_class_name, drawable_id, properties, parent_id:, is_widget:)
      existing = query_display_drawable_for(drawable_id, nil_ok: true)
      return existing if existing

      properties = properties.dup
      properties["shoes_linkable_id"] ||= drawable_id

      peer = build_peer(drawable_class_name, properties, is_widget)
      set_drawable_pairing(drawable_id, peer)

      if peer.is_a?(App)
        link_app(drawable_id, app: peer)
      else
        parent = parent_id ? query_display_drawable_for(parent_id, nil_ok: true) : nil
        peer.set_parent(parent)
        link_app(owning_app_id(drawable_id), document_root: peer) if peer.is_a?(DocumentRoot)
      end

      peer
    end

    def destroy
      App.instances.dup.each(&:destroy)
      DisplayService.instance = nil
    end

    private

    # The Shoes-side linkable_id of the Shoes::App a given drawable was
    # created under, from Lacci's own drawable registry. Only the
    # DocumentRoot needs this -- unlike every other drawable, it has no
    # parent_id linking it back to its app.
    def owning_app_id(drawable_id)
      Shoes::Drawable.drawable_by_id(drawable_id, none_ok: true)&.app&.linkable_id
    end

    # Lacci builds each app's document root *before* its App peer, so with
    # several apps in flight neither can simply look the other up on
    # creation, and there's no longer a single global @app/@document_root
    # pair to fall back on. Track them per app id instead, and link them
    # whichever order they arrive in -- the root is the app's canvas
    # contents but is not its child.
    def link_app(app_id, app: nil, document_root: nil)
      return unless app_id

      bucket = (@apps_by_id ||= {})[app_id] ||= {}
      bucket[:app] = app if app
      bucket[:document_root] = document_root if document_root

      if bucket[:app] && bucket[:document_root] && bucket[:app].document_root.nil?
        bucket[:app].document_root = bucket[:document_root]
      end
    end

    def build_peer(class_name, properties, is_widget)
      short = class_name.to_s.split("::").last
      return Widget.new(properties) if is_widget && !PEERS.key?(short)

      peer_name = PEERS[short]
      if peer_name
        Clogs.const_get(peer_name).new(properties)
      else
        # A Shoes drawable Clogs does not know about still needs a peer so the
        # tree stays consistent; it simply draws nothing.
        warn "Clogs: no peer for #{class_name}, ignoring it visually."
        Drawable.new(properties)
      end
    end
  end
end
