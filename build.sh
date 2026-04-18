#!/usr/bin/env bash
# Build the GDExtension PTY plugin.
# Usage: ./build.sh [platform] [target]
#   platform: linux (default), macos, windows
#   target:   template_debug (default), template_release
#
# Prerequisites: scons, g++/clang++, python3
# On Linux also: libutil-dev (or util-linux-dev on some distros)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON_DIR="$SCRIPT_DIR/addons/godot_pty"
PLATFORM="${1:-linux}"
TARGET="${2:-template_debug}"

if [ ! -d "$ADDON_DIR/godot-cpp" ]; then
    echo "==> Cloning godot-cpp (Godot 4.2 stable)..."
    git clone --recurse-submodules \
        https://github.com/godotengine/godot-cpp.git \
        "$ADDON_DIR/godot-cpp"
    pushd "$ADDON_DIR/godot-cpp" > /dev/null
    git checkout godot-4.2-stable
    popd > /dev/null
fi

echo "==> Building for platform=$PLATFORM target=$TARGET ..."
cd "$ADDON_DIR"
scons platform="$PLATFORM" target="$TARGET" -j"$(nproc 2>/dev/null || sysctl -n hw.logicalcpu)"
echo "==> Build complete: $ADDON_DIR/bin/"
