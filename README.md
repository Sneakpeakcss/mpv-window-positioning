# window-positioning.lua

mpv Lua script that restores window position and size on startup.


## Requirements

* Windows 10 or later.
* mpv built with LuaJIT.


## Installation

1. Copy `window-positioning.lua` into your mpv scripts directory:

   ```text
    mpv/
    └── scripts/
        └── window-positioning.lua
   ```


## Configuration

| Option                    | Description                                               |
| ------------------------- | --------------------------------------------------------- |
| `restore_window_position` | Enable or disable window restoration entirely             |
| `restore_window_size`     | Restore window size on startup (optional)                 |
| `clamp_bottom`            | Prevent window from extending below the monitor work area |


## Notes

* mpv launched with user-specified `--geometry` or `--screen` skips window restoration.
* Window geometry is saved to a `windowpos` file in mpv’s directory.
* This script is primarily intended for [Pseudo GUI](https://mpv.io/manual/master/#pseudo-gui-mode) mode. Running mpv from a terminal generally works as long as `--idle=yes` is not enabled.

## Limitations

* Fighting with mpv’s internal geometry logic is prone to timing issues.

* The script attempts to override mpv’s default window centering on startup,
  but a brief repositioning flicker may still occur depending on system load and startup timing.

* There’s no reliable way to obtain the correct restore geometry before mpv enters fullscreen. Since mpv only exposes this information in verbose logs, the script parses that output to avoid saving incorrect values.
