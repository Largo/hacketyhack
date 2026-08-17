# frozen_string_literal: true

# Spike: an alternate Clogs entry point that renders Shoes programs through
# Scarpe's own webview display service instead of Clogs' libui renderer.
#
#   require "clogs/webview"
#
# instead of `require "clogs"`. `require "scarpe"` does the heavy lifting --
# it requires Lacci (`shoes`) itself, then registers
# `Scarpe::Webview::DisplayService` via `Shoes::DisplayService.set_display_service_class`
# and loads every drawable peer it needs. What's left here is the same role
# lib/compat/shoes3.rb plays for the DSL layer: Hackety-Hack-specific patches
# appended on top, not a renderer of our own.
#
# See clogs/lib/clogs.rb for the libui entry point this parallels, and the
# :webview group in the root Gemfile for why this needs gems sourced from
# scarpe-team/scarpe's git main rather than a released version.
require "scarpe"

require_relative "lacci_compat"
