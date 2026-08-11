# frozen_string_literal: true

# Proves a Shoes.app can open another Shoes.app: both windows share one
# process and one libui event loop, rather than the second one raising
# Shoes::Errors::TooManyInstancesError. Run it with:
#
#   ruby -Iclogs/lib clogs/examples/nested_app.rb

require "clogs"

Shoes.app(title: "Outer", width: 300, height: 160) do
  para "This is the outer window."

  @opened_child = false
  animate(2) do
    next if @opened_child
    @opened_child = true

    Shoes.app(title: "Inner", width: 220, height: 120) do
      para "This is the nested window."
    end
  end
end
