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
        @app = peer
      else
        parent = parent_id ? query_display_drawable_for(parent_id, nil_ok: true) : nil
        peer.set_parent(parent)
        @document_root = peer if peer.is_a?(DocumentRoot)
      end

      # Lacci builds the document root *before* the app, so neither one can
      # simply look the other up on creation. Whichever arrives second links
      # them: the root is the app's canvas contents but is not its child.
      @app.document_root = @document_root if @app && @document_root && @app.document_root.nil?

      peer
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

    def destroy
      @app&.destroy
      DisplayService.instance = nil
    end
  end
end
