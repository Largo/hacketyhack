# frozen_string_literal: true

require "gtk3"

module Clogs
  # Shoes' `alert`, `confirm`, `ask` and the file pickers, all native GTK.
  module Dialogs
    class << self
      def alert(window, message)
        run_dialog(Gtk::MessageDialog.new(
          parent: window, flags: :modal, type: :info, buttons: :ok, message: message.to_s
        ))
        nil
      end

      def confirm(window, message)
        run_dialog(Gtk::MessageDialog.new(
          parent: window, flags: :modal, type: :question, buttons: :yes_no, message: message.to_s
        )) == Gtk::ResponseType::YES
      end

      # GTK has no input dialog of its own, so this is the one place the
      # backend builds a window -- a message dialog with an entry in it, which
      # is what GTK applications do.
      def ask(window, message)
        dialog = Gtk::MessageDialog.new(
          parent: window, flags: :modal, type: :question, buttons: :ok_cancel, message: message.to_s
        )
        entry = Gtk::Entry.new
        entry.activates_default = true
        dialog.content_area.add(entry)
        dialog.set_default_response(Gtk::ResponseType::OK)
        dialog.show_all
        answer = dialog.run == Gtk::ResponseType::OK ? entry.text : nil
        dialog.destroy
        answer
      end

      def open_file(window)
        file_dialog(window, "Open File", :open, Gtk::Stock::OPEN)
      end

      def save_file(window)
        file_dialog(window, "Save File", :save, Gtk::Stock::SAVE)
      end

      def open_folder(window)
        file_dialog(window, "Open Folder", :select_folder, Gtk::Stock::OPEN)
      end

      private

      def run_dialog(dialog)
        response = dialog.run
        dialog.destroy
        response
      end

      def file_dialog(window, title, action, accept)
        dialog = Gtk::FileChooserDialog.new(
          title: title, parent: window, action: action,
          buttons: [[Gtk::Stock::CANCEL, :cancel], [accept, :accept]]
        )
        path = dialog.run == Gtk::ResponseType::ACCEPT ? dialog.filename : nil
        dialog.destroy
        path
      end
    end
  end
end
