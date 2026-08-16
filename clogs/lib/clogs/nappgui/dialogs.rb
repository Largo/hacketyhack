# frozen_string_literal: true

require_relative "shim"

module Clogs
  # Shoes' `alert`, `confirm`, `ask` and the file pickers.
  #
  # NAppGUI has native file and folder pickers but no message box at all, so
  # the first three are a window, a label and a button or two that the shim
  # builds by hand -- which is what NAppGUI's own examples do.
  #
  # All six run a nested modal loop inside the SDK, so none of them can be
  # shown before it is up. Shoes 3 let `ask`/`alert` be called with no window
  # in sight -- Hackety Hack's Guessing Game sample is nothing else -- and
  # that is the one thing this backend cannot do.
  module Dialogs
    class << self
      def available?
        Shim.started?
      end

      # A dialog asked for before the loop is running has nowhere to go. Say
      # so on stderr rather than dropping it silently, and answer the way a
      # cancelled dialog would.
      def unavailable(kind, message)
        warn "Clogs: NAppGUI cannot show #{kind} before its event loop is running: #{message}"
        nil
      end

      def alert(window, message)
        return unavailable("an alert", message) unless available?

        Shim.alert(window || nil, message.to_s)
        nil
      end

      def confirm(window, message)
        return false unless available?

        Shim.confirm(window || nil, message.to_s) != 0
      end

      def ask(window, message)
        return unavailable("a prompt", message) unless available?

        Shim.string(Shim.ask(window || nil, message.to_s))
      end

      def open_file(window)
        return nil unless available?

        Shim.string(Shim.ask_open_file(window || nil))
      end

      def save_file(window)
        return nil unless available?

        Shim.string(Shim.ask_save_file(window || nil))
      end

      def open_folder(window)
        return nil unless available?

        Shim.string(Shim.ask_open_folder(window || nil))
      end
    end
  end
end
