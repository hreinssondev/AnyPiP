# AnyPiP

AnyPiP is a macOS menu-bar app that turns the frontmost app window into an always-on-top picture-in-picture window. It is built with SwiftUI, AppKit, ScreenCaptureKit, and the macOS Accessibility APIs.

## Features

- Start or stop PiP from the menu bar or a configurable global shortcut.
- Restore or exit the last PiP window with a second configurable shortcut.
- Automatically enter PiP for selected apps when they lose focus.
- Hover into the PiP window to temporarily switch back to the source app.
- Keep the original source window hidden while the PiP copy stays visible.

## Requirements

- macOS 26.4 or later.
- Xcode 26.5 or later.
- Screen Recording permission.
- Accessibility permission.

## Build From Source

1. Clone the repository.
2. Open `AppsPIP.xcodeproj` in Xcode.
3. Select the `AppsPIP` scheme.
4. Set your own development team in Signing & Capabilities if you want to run a signed local build.
5. Build and run.

You can also verify the project from Terminal:

```sh
xcodebuild -scheme AppsPIP -project AppsPIP.xcodeproj -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## First Run

AnyPiP needs macOS permissions to capture and manage windows:

- Screen Recording: required by ScreenCaptureKit.
- Accessibility: required to move, restore, and focus source windows.

The app links directly to the relevant System Settings panes when a permission is missing.

## Release Builds

For public distribution, archive the app from Xcode and sign it with your own Apple Developer ID certificate. If you distribute outside the Mac App Store, notarize the exported app before publishing it as a GitHub Release asset.

## License

MIT. See [LICENSE](LICENSE).
