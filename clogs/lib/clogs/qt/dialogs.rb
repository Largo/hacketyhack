# frozen_string_literal: true

require_relative "shim"

module Clogs
  # Shoes' `alert`, `confirm`, `ask` and the file pickers, all native Qt.
  module Dialogs
    class << self
      def alert(window, message)
        Shim.alert(window || nil, message.to_s)
        nil
      end

      def confirm(window, message)
        Shim.confirm(window || nil, message.to_s) != 0
      end

      def ask(window, message)
        Shim.string(Shim.ask(window || nil, message.to_s))
      end

      def open_file(window)
        Shim.string(Shim.ask_open_file(window || nil))
      end

      def save_file(window)
        Shim.string(Shim.ask_save_file(window || nil))
      end

      def open_folder(window)
        Shim.string(Shim.ask_open_folder(window || nil))
      end
    end
  end
end
