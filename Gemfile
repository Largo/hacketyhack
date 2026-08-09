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
