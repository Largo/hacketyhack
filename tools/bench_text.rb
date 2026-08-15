# frozen_string_literal: true

# The other half of the paint cost: styled, wrapped text. libui measures and
# renders it through Pango; the FOX backend asks FXFont for widths and draws
# each run itself.
require "clogs"

WORDS = %w[shoes clogs ruby hackety hack paint canvas widget slot flow stack]

Shoes.app(title: "text bench", width: 640, height: 700) do
  40.times do |i|
    para WORDS[i % WORDS.size], " ", strong(WORDS[(i + 1) % WORDS.size]), " ",
      em(WORDS[(i + 2) % WORDS.size]), " ", code(WORDS[(i + 3) % WORDS.size]),
      " ", del(WORDS[(i + 4) % WORDS.size]), " ", ins(WORDS[(i + 5) % WORDS.size])
  end
  @dot = oval 0, 670, 20, 20
  animate(60) { |i| @dot.left = (i * 7) % 600 }
end
