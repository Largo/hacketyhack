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
# The default libui backend needs none of that; see clogs/docs/backends.md.
group :fox, optional: true do
  gem "fxruby", "~> 1.6"
end

# Clogs' wx backend (CLOGS_BACKEND=wx). wxRuby3 is a SWIG-generated C++
# extension: it needs wxWidgets 3.2's development headers, SWIG and doxygen,
# and a post-install `wxruby setup` step that compiles for several minutes.
# On Debian and Ubuntu that is libwxgtk3.2-dev, libwxgtk-webview3.2-dev,
# libwxgtk-media3.2-dev, swig and doxygen. Optional for the same reason:
#
#   bundle config set --local with wx && bundle install && wxruby setup
#
group :wx, optional: true do
  gem "wxruby3", "~> 1.8"
end

# Clogs' gtk3 backend (CLOGS_BACKEND=gtk3). ruby-gnome's binding is a C
# extension needing GTK 3's development files -- libgtk-3-dev on Debian and
# Ubuntu, gtk+3 on Homebrew -- so it is optional like the others:
#
#   bundle config set --local with gtk3 && bundle install
#
group :gtk3, optional: true do
  gem "gtk3", "~> 4.3"
end

# Spike: an alternate Clogs backend on Scarpe's own webview display service
# instead of libui (see clogs/lib/clogs/webview.rb). Neither gem has a
# released version compatible with our `lacci >= 0.5.0` pin yet -- the
# released `scarpe` wants `lacci ~> 0.4.0`, and released `lacci` 0.5.0 wants
# `scarpe-components ~> 0.4.0` while scarpe's git main wants `~> 0.5.0` --
# so both come from the local scarpe checkout until upstream cuts matching
# releases. `bundle config set --local without webview` and re-resolving
# drops this group entirely.
group :webview do
  gem "scarpe", path: "../scarpe"
  gem "lacci", path: "../scarpe/lacci"
end
