# frozen_string_literal: true

require_relative "bridge"

module Clogs
  # The shared Clipboard shells out to xclip, pbpaste or PowerShell. A wasm
  # process has no shell and no processes to start, so `system` there is not
  # slow or unavailable -- it raises. Replace the platform detection with the
  # page's clipboard instead.
  #
  # Reading is the awkward half: navigator.clipboard.readText is asynchronous
  # and permission-gated, and Shoes' `app.clipboard` is neither, so the page
  # keeps the last thing Clogs itself copied and answers with that. Copy and
  # paste inside a Shoes program therefore work; pasting something copied from
  # another application does not, and quietly gives back the last internal
  # value rather than raising in the middle of someone's keystroke.
  module Clipboard
    module_function

    def read
      Wasm::Bridge.clipboard_read
    rescue StandardError
      ""
    end

    def write(text)
      Wasm::Bridge.clipboard_write(text.to_s)
    rescue StandardError
      nil
    end
  end
end
