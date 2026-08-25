# frozen_string_literal: true

# Nokogiri is a C extension, so it cannot be there in wasm. Hackety Hack
# requires it at boot through lib/compat/hpricot.rb, but every caller is one of
# the online features that talk to hackety.org -- a server that has not existed
# for years. This supplies the class shapes that shim needs to load (it
# aliases three constants and prepends a module to a fourth), and raises if
# anything actually tries to parse, so the dead code fails where it is written
# rather than pretending to have parsed something.
module Nokogiri
  module XML
    class Node
      def attributes
        {}
      end
    end

    class Element < Node; end
    class Text < Node; end

    class Document < Node; end
  end

  module HTML4
    class Document < Nokogiri::XML::Document; end
  end

  class << self
    def HTML(*)
      raise NotImplementedError, "Nokogiri is not available in wasm; this is one of Hackety Hack's dead hackety.org features"
    end

    def XML(*)
      raise NotImplementedError, "Nokogiri is not available in wasm; this is one of Hackety Hack's dead hackety.org features"
    end
  end
end
