# frozen_string_literal: true

# A side-by-side of the drawing features the two backends disagree about:
# antialiasing, alpha compositing, gradients and rotation.
require "clogs"

Shoes.app(title: "fidelity", width: 620, height: 420) do
  background rgb(250, 250, 250)

  # Gradients: a libui brush, banded by hand on FOX.
  background lightblue..purple, width: 600, height: 60, top: 10, left: 10

  # Curves and diagonals, where antialiasing shows.
  nostroke
  fill black
  oval 20, 90, 90, 90
  fill red
  star 130, 90, 5, 45, 20

  # Alpha: overlapping translucent discs.
  fill rgb(0, 0, 255, 0.45)
  oval 240, 90, 90, 90
  fill rgb(0, 200, 0, 0.45)
  oval 285, 90, 90, 90

  # Rotation of geometry, and of text.
  fill orange
  stroke black
  strokewidth 2
  rotate 25
  rect 420, 95, 80, 80
  rotate 0

  para "Antialiasing, alpha, gradients, rotation", top: 200, left: 20, size: 16
  para strong("bold"), " ", em("italic"), " ", code("mono"), " ",
    ins("ins"), " ", del("del"), top: 230, left: 20, size: 16

  # Dashed and capped strokes.
  stroke green
  strokewidth 6
  line 20, 280, 580, 280
  stroke black
  strokewidth 1
  oval 20, 300, 560, 60
end
