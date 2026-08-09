#!/usr/bin/env ruby
# frozen_string_literal: true

# Hackety Hack.
#
#   ruby hacketyhack.rb
#
# Runs on plain CRuby via Clogs (Shoes on libui). The Shoes 3 compatibility
# layer in lib/compat/shoes3.rb bridges the differences between the Shoes that
# Hackety Hack was written for and the Shoes API that Lacci defines.

$LOAD_PATH.unshift(__dir__)
$LOAD_PATH.unshift(File.join(__dir__, "clogs", "lib")) if File.directory?(File.join(__dir__, "clogs", "lib"))

require "lib/compat/shoes3"

load File.join(__dir__, "app", "ui", "mainwindow.rb")
