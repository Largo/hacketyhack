# frozen_string_literal: true

require_relative "lib/clogs/version"

Gem::Specification.new do |spec|
  spec.name = "clogs"
  spec.version = Clogs::VERSION
  spec.authors = ["Hackety Hack contributors"]
  spec.summary = "Shoes, worn over libui: a native display service for the Shoes GUI DSL"
  spec.description = <<~DESC
    Clogs runs Shoes programs on plain CRuby using libui, a small
    cross-platform native widget library. It implements the Shoes drawing and
    layout model as a display service for Lacci, the display-independent half
    of Scarpe, so it needs neither a browser engine nor a JVM.
  DESC
  spec.homepage = "https://github.com/largo/hacketyhack"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/largo/hacketyhack/tree/main/clogs"

  spec.files = Dir[
    "lib/**/*.rb",
    "exe/*",
    "examples/**/*.rb",
    "README.md",
    "LICENSE.txt"
  ]
  spec.bindir = "exe"
  spec.executables = ["clogs"]
  spec.require_paths = ["lib"]

  # The Shoes DSL itself.
  spec.add_dependency "lacci", ">= 0.5.0"
  # libui-ng plus prebuilt shared libraries for Linux, macOS and Windows.
  spec.add_dependency "libui", "~> 0.2"
  # Pure-Ruby PNG decoding, because libui cannot load an image file itself.
  spec.add_dependency "chunky_png", "~> 1.4"
end
