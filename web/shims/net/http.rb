# frozen_string_literal: true

# Net::HTTP, for a Ruby with no sockets.
#
# wasm has no TCP, and the stdlib's net/http reaches for `socket` on the first
# line. That would be a problem if Hackety Hack's networking still went
# anywhere -- but every call goes to hackety.org, which stopped answering years
# ago, so on a real machine these requests already fail with a SocketError from
# DNS. This shim raises the same error at the same points, which means the app
# takes exactly the code paths it takes on a normal offline machine rather than
# a new set nobody has tested.
require "uri"

module Net
  class HTTPError < StandardError; end

  # Lacci's own `download` rescues these by name, so they have to exist even
  # though nothing here will ever raise one.
  class OpenTimeout < StandardError; end
  class ReadTimeout < StandardError; end
  class WriteTimeout < StandardError; end
  class HTTPBadResponse < StandardError; end
  class HTTPFatalError < HTTPError; end
  class HTTPServerException < HTTPError; end

  class HTTPResponse
    attr_reader :code, :body

    def initialize(code = "500", body = "")
      @code = code
      @body = body
    end

    def [](_name)
      nil
    end
  end

  class HTTP
    OFFLINE = "hackety.org is unreachable from wasm: there are no sockets in a browser, " \
      "and the server this asks for has not answered since 2013"

    class << self
      def start(*_args, **_kwargs)
        raise SocketError, OFFLINE
      end

      def get(*_args)
        raise SocketError, OFFLINE
      end

      def get_response(*_args)
        raise SocketError, OFFLINE
      end

      def post_form(*_args)
        raise SocketError, OFFLINE
      end

      def new(*_args)
        allocate
      end
    end

    def start(*_args)
      raise SocketError, OFFLINE
    end

    def request(*_args)
      raise SocketError, OFFLINE
    end

    def request_get(*_args)
      raise SocketError, OFFLINE
    end

    def post(*_args)
      raise SocketError, OFFLINE
    end

    def use_ssl=(_value); end

    def open_timeout=(_value); end

    def read_timeout=(_value); end

    def finish; end
  end
end

# SocketError is defined by the socket library, which is exactly what is
# missing here; the callers rescue it by name.
SocketError = Class.new(StandardError) unless defined?(SocketError)
