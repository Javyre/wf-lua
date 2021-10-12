# wf-lua

[![IRC: #swayfire on libera](https://img.shields.io/badge/irc-%23swayfire-informational)](https://web.libera.chat/#swayfire)

*Experiment to use Lua as an advanced configuration language for wayfire.*

`wf-lua` is meant for use-cases where writing an actual wayfire plugin shouldn't
be necessary. These use-cases include:

- User configuration: setting options and defining custom keybinds.
- Window management automation scripts: listening for events and calling into
  the exposed lua api for wayfire and other plugins at a high level.
- (planned: Implementing ipc commands for an eventual `wf-msg <command> <args>`)

`wf-lua` is *not* meant for:

- Implementing anything that requires access to an OpenGL context. (e.g.:
	decorations, view transformers, custom surface implementations)
- Implementing anything requiring continuous calling-back of lua functions.
  (e.g.: animations)

For these use-cases, you should create a real wayfire plugin.

*NOTE*: `wf-lua` is still in very early development.

## Installation

Wf-lua depends on Wayfire's master branch. Please make sure it is installed
before building.

To build and install from source:
```sh
# Generate the build directory:
meson --prefix /usr --buildtype=release build

# Build and install wf-lua:
sudo ninja -C build install
```

## Contributing

Contributions are welcome.

Wf-lua uses the `c++17` standard and a modified `llvm` coding style
defined in `.clang_format`. Please run `ninja -C build clang-format`
to run the formatter before every commit.

We also use `lua-format` for lua source formatting (install from luarocks).
