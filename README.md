# GodotPTY

A high-performance PTY (Pseudo-Terminal) terminal emulator for Godot 4.2+, implemented as a GDExtension in C++.

## Features
- Native PTY support (forkpty) for Linux and macOS.
- Integrated terminal emulator widget (`GodotTerminal`).
- ANSI escape sequence support (basic).
- Scrollback history.

## Prerequisites
- Godot 4.2 or later.
- SCons (for building the GDExtension).
- A C++17 compiler (g++, clang++, or MSVC).
- **Linux only**: `libutil` (usually part of glibc, but may need `libutil-dev` on some distros).

## Building

To build the GDExtension binaries, run the provided `build.sh` script:

```bash
./build.sh
```

This script will:
1. Clone the `godot-cpp` repository (if missing) at `addons/godot_pty/godot-cpp`.
2. Build `godot-cpp` for your platform.
3. Build the `GodotPTY` GDExtension.

The resulting binaries will be placed in `addons/godot_pty/bin/`.

### Manual Build
If you prefer to run SCons manually:
```bash
cd addons/godot_pty
scons platform=linux target=template_debug
```

## Running

1. Build the GDExtension (see above).
2. Open the project in Godot 4.2+.
3. Run the main scene (`scenes/terminal.tscn`).

## Project Structure
- `addons/godot_pty/core/`: C++ source code for the PTY node.
- `addons/godot_pty/ui/`: GDScript and Scene files for the terminal widget.
- `addons/godot_pty/godot_pty.gdextension`: GDExtension configuration file.
- `scenes/`: Demo/Main scenes.
