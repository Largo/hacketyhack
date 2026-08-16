#!/bin/sh
# Build the NAppGUI shim that Clogs' nappgui backend drives through Fiddle.
#
#   NAPPGUI_SRC=/path/to/nappgui_src clogs/ext/nappgui/build.sh
#
# NAppGUI is not packaged by any distribution, so it has to be built from
# source first (cmake -S . -B build && cmake --build build). Point
# NAPPGUI_SRC at that checkout. See clogs/docs/backends.md.
set -e
dir=$(dirname "$0")
src=${NAPPGUI_SRC:-$dir/nappgui_src}

if [ ! -d "$src/src/gui" ]; then
  echo "clogs: NAppGUI sources not found at $src." >&2
  echo "       git clone --depth 1 https://github.com/frang75/nappgui_src" >&2
  echo "       cd nappgui_src && cmake -S . -B build && cmake --build build" >&2
  echo "       then re-run with NAPPGUI_SRC=/path/to/nappgui_src" >&2
  exit 1
fi

libdir=$(find "$src/build" -name "libgui.a" -exec dirname {} \; 2>/dev/null | head -1)
if [ -z "$libdir" ]; then
  echo "clogs: NAppGUI is checked out at $src but not built (no libgui.a)." >&2
  echo "       cd $src && cmake -S . -B build && cmake --build build" >&2
  exit 1
fi

out="$dir/libclogs_nappgui.so"
[ "$(uname)" = "Darwin" ] && out="$dir/libclogs_nappgui.dylib"

# NAppGUI's headers are spread across its module directories.
includes=""
for mod in sewer osbs core geom2d draw2d gui osgui osapp inet encode; do
  includes="$includes -I$src/src/$mod"
done

${CXX:-g++} -O2 -fPIC -shared -std=c++17 \
  "$dir/clogs_nappgui.cpp" -o "$out" \
  -I"$src/src" $includes \
  $(pkg-config --cflags gtk+-3.0) \
  -L"$libdir" \
  -Wl,--whole-archive -lgui -losapp -losgui -ldraw2d -lgeom2d -lcore -losbs -lsewer -lencode -linet \
  -Wl,--no-whole-archive \
  $(pkg-config --libs gtk+-3.0) -lcurl -lm -lpthread

echo "clogs: built $out"
