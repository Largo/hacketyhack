# frozen_string_literal: true

# A tour of what Clogs can draw. Run it with:
#
#   ruby -Iclogs/lib clogs/examples/kitchen_sink.rb

require "clogs"

Shoes.app(title: "Clogs kitchen sink", width: 640, height: 620) do
  stack do
    background rgb(250, 250, 252)

    title "Clogs", stroke: rgb(40, 40, 90)
    para "Shoes drawables rendered by ", strong("libui"), ", with ", em("emphasis"),
      ", ", code("code"), " and a ", link("link") { @status.replace "You clicked the link!" }, "."

    flow do
      button("A button") { @status.replace "Button pushed." }
      check
      radio "group"
      radio "group"
    end

    @status = para "Nothing has happened yet.", stroke: rgb(120, 0, 0)

    flow do
      edit_line text: "edit me"
      list_box items: ["one", "two", "three"]
    end

    edit_box text: "A multi-line edit box.\nType into me.", width: 400, height: 90

    progress fraction: 0.35

    stack(width: 620, height: 170) do
      background rgb(255, 255, 255)
      border rgb(200, 200, 210), strokewidth: 2

      fill rgb(220, 60, 60)
      stroke rgb(60, 0, 0)
      rect 20, 20, 120, 60

      fill rgb(60, 120, 220)
      oval 170, 20, 100, 60

      nostroke
      fill rgb(250, 200, 40)
      star 320, 20, 6, 34, 16

      stroke rgb(0, 140, 0)
      strokewidth 4
      line 20, 110, 300, 130

      nofill
      stroke rgb(120, 60, 200)
      strokewidth 3
      shape do
        move_to 340, 100
        line_to 380, 60
        line_to 420, 140
        line_to 460, 90
      end
    end
  end
end
