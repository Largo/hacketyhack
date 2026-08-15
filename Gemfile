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

# Clogs' alternative FOX backend (CLOGS_BACKEND=fox). FXRuby is a C++ extension
# that needs FOX 1.6's development headers to build -- libfox-1.6-dev on
# Debian and Ubuntu, fox on Homebrew -- so it is not installed by default:
#
#   bundle config set --local with fox && bundle install
#
# The default libui backend needs none of that; see clogs/docs/fox_vs_libui.md.
group :fox, optional: true do
  gem "fxruby", "~> 1.6"
end
