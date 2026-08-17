# frozen_string_literal: true

source "https://rubygems.org"

# Hackety Hack's UI. Clogs implements Shoes on libui; it lives in this repo so
# the two can be developed together.
gem "clogs", path: "clogs"

# Hackety Hack itself.
gem "nokogiri"   # replaces Hpricot, which no longer builds
gem "sqlite3"

group :development, :test do
  gem "rake"
  gem "minitest", "~> 5.0"
end

# Spike: an alternate Clogs backend on Scarpe's own webview display service
# instead of libui (see clogs/lib/clogs/webview.rb). Neither gem has a
# released version compatible with our `lacci >= 0.5.0` pin yet -- the
# released `scarpe` wants `lacci ~> 0.4.0`, and released `lacci` 0.5.0 wants
# `scarpe-components ~> 0.4.0` while scarpe's git main wants `~> 0.5.0` --
# so both come from scarpe-team/scarpe's git main until upstream cuts
# matching releases. `bundle config set --local without webview` and
# re-resolving drops this group entirely.
group :webview do
  gem "scarpe", github: "scarpe-team/scarpe"
  gem "lacci", github: "scarpe-team/scarpe", glob: "lacci/*.gemspec"
end
