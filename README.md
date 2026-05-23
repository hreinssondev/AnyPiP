# AnyPiP


AnyPiP is a macOS menu-bar app that turns the frontmost app window into an always-on-top picture-in-picture window. It is built with SwiftUI, AppKit, ScreenCaptureKit, and the macOS Accessibility APIs.

https://github.com/user-attachments/assets/4e27c05c-18d4-44f4-bad9-2c2ffea8da56

## Features

- Start or stop PiP with a configurable global shortcut.
- Restore PIP or exit the last PiP window with a shortcut.
- Auto PiP for selected apps when they lose focus.
- Hover PIP window switching as an option

## Requirements

- macOS 26.4 or later.
- Screen Recording permission.
- Accessibility permission.

You can also verify the project from Terminal:

## First Startup

AnyPiP needs macOS permissions to capture and manage windows:

- Screen Recording: required by ScreenCaptureKit.
- Accessibility: required to move, restore, and focus source windows.

## License

MIT. See [LICENSE](LICENSE).
