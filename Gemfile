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

# Scarpe supplies two things here: Lacci, which is the Shoes API every Clogs
# backend is built on, and its own webview display service, which
# clogs/lib/clogs/webview.rb runs as an alternate backend
# (CLOGS_BACKEND=webview).
#
# Neither has a released version compatible with our `lacci >= 0.5.0` pin --
# released `scarpe` wants `lacci ~> 0.4.0`, and released `lacci` 0.5.0 wants
# `scarpe-components ~> 0.4.0` while scarpe's main wants `~> 0.5.0` -- so both
# come from git.
#
# They come from our fork rather than from scarpe-team/scarpe because running
# Hackety Hack on the webview backend turned up three bugs in Scarpe itself:
# periodic handlers (`animate`, `every`) could not be created once the app was
# running, colours lost their alpha so `nostroke` painted solid black, and a
# slot's background painted over its contents instead of behind them. The
# branch is three commits on top of upstream main, each one PR-shaped, and the
# intent is to send them upstream and come back here.
#
#   https://github.com/Largo/scarpe/tree/hacketyhack-webview-fixes
#
# Optional, like every other alternate backend here, and for the same reason:
# `scarpe` pulls in webview_ruby, a native extension that wants GTK 3's and
# WebKit's development packages. Every CI job that installs a *different*
# toolkit was failing to bundle because of it. Opt in with
#
#   bundle config set --local with webview && bundle install
#
# What being optional does not do is keep Lacci out. Scarpe's repo is a
# monorepo carrying Lacci's gemspec, and Lacci is a dependency of clogs as
# well, so there is one Lacci in the lockfile and it comes from git either way.
# It is pure Ruby, so it costs nothing to install -- but it is not the Lacci
# Hackety Hack's Shoes 3 compatibility layer was written against. `rake
# samples` and `rake boot` pass on both, since they only open a window and
# close it again; the browser suite drives the IDE, and on git main the side
# tabs stop opening. So the browser build pins released Lacci 0.5.0 for itself
# in web/Gemfile rather than inheriting whichever one this group last pulled
# in.
#
# Untangling that properly means either landing these fixes upstream and going
# back to released gems, or giving the webview spike its own bundle the way
# web/ now has one.
group :webview, optional: true do
  gem "scarpe", github: "Largo/scarpe", branch: "hacketyhack-webview-fixes"
  gem "lacci", github: "Largo/scarpe", branch: "hacketyhack-webview-fixes", glob: "lacci/*.gemspec"
end
