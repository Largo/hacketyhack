# frozen_string_literal: true

# OpenSSL is a C extension, so it is not there in wasm. Nothing can open a TLS
# connection from inside a browser sandbox anyway -- see web/shims/net/http.rb
# -- but code that builds a request still reads these constants before it
# discovers there is no socket. Supplying them lets that code reach the
# honest "there are no sockets here" error instead of dying on a missing
# constant several frames earlier.
module OpenSSL
  module SSL
    VERIFY_NONE = 0
    VERIFY_PEER = 1
    VERIFY_FAIL_IF_NO_PEER_CERT = 2
    VERIFY_CLIENT_ONCE = 4

    class SSLError < StandardError; end
    class SSLContext; end
  end

  module X509
    class Store; end
    class Certificate; end
  end

  module Digest; end
end
