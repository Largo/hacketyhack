require 'lib/web/api'
require 'net/http'

module Upgrade
  class << self
    include HH::API

    def check_latest_version &blk
      root = HH::API.root
      return unless root

      version_rel = root.at("//a[@rel='/rels/current-application-version']")
      # hackety.org no longer serves this API, so a missing link is the normal
      # case rather than an error worth crashing the whole app over.
      return unless version_rel

      HH::API.get(version_rel.attributes['href']) do |response|
        body = JSON.parse(response.body)
        blk[body]
      end
    end
  end
end
