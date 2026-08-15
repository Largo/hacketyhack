# frozen_string_literal: true

# Control for the image benchmark: same page, same repaint rate, no bitmap.
require "clogs"

Shoes.app(title: "no-image bench", width: 640, height: 700) do
  para "Control: no bitmap on the page.", size: 16
  @dot = oval 0, 660, 20, 20
  animate(60) { |i| @dot.left = (i * 7) % 600 }
end
