# frozen_string_literal: true

# Hackety Hack was written against Hpricot, which has not been maintained since
# 2010 and does not build on modern Ruby. Nokogiri provides the same shape of
# API, so this shim maps the small part of Hpricot that Hackety Hack actually
# uses -- `Hpricot(html)`, `Hpricot.XML(xml)`, and the Doc/Elem/Text classes it
# reopens -- onto Nokogiri.
#
# Note that everything using this shim talks to hackety.org, which no longer
# exists. The code is kept loadable so the rest of the app boots; the online
# features themselves are inert.

require "nokogiri"

module Hpricot
  Doc = Nokogiri::HTML4::Document
  Elem = Nokogiri::XML::Element
  Text = Nokogiri::XML::Text

  # Hpricot's `attributes` returned plain strings; Nokogiri returns Attr
  # objects. Hackety Hack only ever reads them as strings.
  module StringyAttributes
    def attributes
      super.transform_values(&:to_s)
    end
  end

  def self.XML(input)
    Nokogiri::XML(input.to_s)
  end
end

Nokogiri::XML::Element.prepend(Hpricot::StringyAttributes)

# Hpricot's top-level parse function.
def Hpricot(input)
  Nokogiri::HTML(input.respond_to?(:read) ? input.read : input.to_s)
end
