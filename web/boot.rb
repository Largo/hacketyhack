# frozen_string_literal: true

# The first Ruby the browser runs.
#
# Everything here is about making a wasm process look enough like a normal one
# for an unmodified Hackety Hack to boot in it: a load path, a working
# directory, a home directory to write into, and the two C extensions the app
# requires replaced by shims (see web/shims).

$LOAD_PATH.unshift("/shims", "/gems/lacci", "/gems/scarpe-components", "/gems/chunky_png", "/clogs", "/hh")

ENV["CLOGS_BACKEND"] = "wasm"

require "js"

module ClogsBoot
  module_function

  def report(status, message = nil)
    JS.global[:window][:__clogsStatus] = status
    JS.global[:window][:__clogsError] = message if message
    JS.global[:console].call(status == "error" ? :error : :log, "[clogs] #{status}#{message ? ": #{message}" : ""}")
  end

  def run
    # Hackety Hack takes HH::HOME from Dir.pwd, and its own directory is what
    # that has to be.
    Dir.chdir("/hh")

    require "clogs"

    entry = ENV["CLOGS_ENTRY"].to_s
    entry = "/hh/hacketyhack.rb" if entry.empty?

    # Hackety Hack's own entry point loads the Shoes 3 compatibility layer
    # itself. A bundled sample does not -- they are Shoes 3-era programs and
    # need it to run at all -- so put it in front of them, which is what
    # `rake samples` and the `clogs` executable both do.
    require "lib/compat/shoes3" unless entry.end_with?("hacketyhack.rb", "h-ety-h.rb")

    report("loading")
    load entry
    report("ready")
  rescue Exception => e
    report("error", "#{e.class}: #{e.message}")
    warn "#{e.class}: #{e.message}"
    warn e.backtrace.first(30).join("\n") if e.backtrace
  end
end

ClogsBoot.run
