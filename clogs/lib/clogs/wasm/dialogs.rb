# frozen_string_literal: true

require_relative "bridge"

module Clogs
  # Shoes' `alert`, `confirm` and `ask`, on the browser's own dialogs.
  #
  # `window.alert` and friends are the only synchronous UI a page has, and here
  # that is exactly the point: Shoes' `ask` returns the answer to the line that
  # called it, and nothing built out of promises can do that from inside wasm.
  # The file pickers have no synchronous equivalent at all, so they answer nil
  # rather than pretending -- see docs/backends.md.
  module Dialogs
    class << self
      def alert(_window, message)
        Wasm::Bridge.alert(message)
      end

      def confirm(_window, message)
        Wasm::Bridge.confirm(message)
      end

      def ask(_window, message)
        Wasm::Bridge.ask(message)
      end

      # A page cannot open a file picker without a user gesture and cannot wait
      # for its answer synchronously. Shoes programs that ask for a path get
      # nil, which is the same answer a cancelled dialog gives.
      def open_file(_window)
        nil
      end

      def save_file(_window)
        nil
      end

      def open_folder(_window)
        nil
      end
    end
  end
end
