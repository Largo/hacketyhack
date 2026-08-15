# frozen_string_literal: true

# The paint-cost benchmark: a full-size bitmap on a page that keeps repainting,
# which is what a Shoes program with artwork on an animated page actually costs.
require "clogs"

IMAGE = ENV.fetch("BENCH_IMAGE", "static/splash-hand.png")

Shoes.app(title: "image bench", width: 640, height: 700) do
  image IMAGE
  @dot = oval 0, 660, 20, 20
  # Moving a drawable dirties the document, so every tick is a real repaint.
  animate(60) do |i|
    @dot.left = (i * 7) % 600
  end
end
