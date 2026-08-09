# frozen_string_literal: true

# Lets `require "hpricot"` keep working in user programs and samples. The real
# implementation is the Nokogiri-backed shim in lib/compat/hpricot.rb.
require_relative "../compat/hpricot"
