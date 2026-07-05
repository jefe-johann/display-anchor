# Display Anchor

Display Anchor is a small macOS menu bar utility that snapshots window layouts and restores them after sleep/wake or display reconfiguration.

If you use external monitors and frequently unplug your Mac or let it go to sleep, you've probably experienced the frustration of macOS moving your windows around. Display Anchor runs quietly in the background, keeping track of where your windows belong, and puts them back when your display setup is restored.

## Features

- **Automatic Snapshots**: Periodically saves window positions before system instability (sleep, display disconnects).
- **Smart Restoration**: Waits for displays to settle upon waking up or reconnecting, and only restores windows if the saved display topology matches the current one.
- **Menu Bar Integration**: Unobtrusive menu bar icon to pause, manually trigger snapshots, or check the current status.
- **Privacy First**: Snapshots are stored locally in Application Support as simple JSON files.

*Note: Display Anchor intentionally targets normal visible desktop windows. Fullscreen, minimized, Stage Manager, and windows on other Spaces are currently out of scope.*

## Requirements

- macOS 26.0 or later. (Note: This is the main difference between the original from Jeffrey Schumann and mine for now)
- **Accessibility Permissions**: The app requires Accessibility permission to inspect and move windows. macOS will prompt you when you first launch the app.

## Building and Running

Display Anchor supports both SwiftPM and Xcode builds.

### Quick Start (Script)

The easiest way to build and package the app is using the provided packaging script:

```bash
./Scripts/package_app.sh
```

This will compile the SwiftPM package in release mode and generate a ready-to-use application bundle at `dist/Display Anchor.app`.

### SwiftPM

You can open the project directory in Xcode, which will resolve the `Package.swift`, or use the command line:

```bash
swift build
```

### Xcode Project

Alternatively, you can open `DisplayAnchor.xcodeproj` and build the `DisplayAnchor` target directly.

*(Note: If you add, remove, or rename Swift source files, ensure you keep the explicit file references in `DisplayAnchor.xcodeproj/project.pbxproj` synced with the SwiftPM directory structure.)*

## Architecture

- **DisplayAnchorCore**: Shared models and logic containing AppKit-free code for snapshot data, topology matching, window matching, and restore readiness.
- **DisplayAnchor**: The thin macOS shell around the core logic that handles sleep/wake hooks, active display reading, menu bar UI, and AX-based window restores.

## Privacy Policy

Please review the [Privacy Policy](PRIVACY.md) to understand how your data is handled. Display Anchor is built with privacy in mind and stores all snapshots locally.

## License

Copyright © 2026 Jeffrey Schumann. All rights reserved.
