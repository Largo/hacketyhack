#!/bin/sh
# Build the Qt shim that Clogs' qt backend drives through Fiddle.
#
#   clogs/ext/qt/build.sh            # writes clogs/ext/qt/libclogs_qt.so
#
# Needs Qt 6's development packages (qt6-base-dev on Debian and Ubuntu,
# qt6-base on Homebrew) and a C++ compiler. See clogs/docs/backends.md.
set -e
dir=$(dirname "$0")
pkgs="Qt6Widgets Qt6Gui Qt6Core"

if ! pkg-config --exists $pkgs 2>/dev/null; then
  echo "clogs: Qt 6 development files not found (looked for: $pkgs)." >&2
  echo "       Debian/Ubuntu: sudo apt-get install qt6-base-dev" >&2
  echo "       macOS:         brew install qt" >&2
  exit 1
fi

out="$dir/libclogs_qt.so"
[ "$(uname)" = "Darwin" ] && out="$dir/libclogs_qt.dylib"

${CXX:-g++} -O2 -fPIC -shared -std=c++17 \
  "$dir/clogs_qt.cpp" -o "$out" \
  $(pkg-config --cflags --libs $pkgs)

echo "clogs: built $out"
