# Cliper

Cliper is a lightweight clipboard manager that lives in the macOS menu bar (macOS 14 Sonoma or later), written in SwiftUI and AppKit.

## Features

- Keeps a history of the last **50** clipboard entries — both **text** and **images**.
- Click the menu bar icon to open the history; click an entry to put it back on the clipboard, then paste with ⌘V.
- **Search** the text history.
- Right-click an entry to copy or **delete** it; clear the whole history with "Clear History…".
- Entries that password managers and other apps mark as concealed or transient (see [nspasteboard.org](http://nspasteboard.org)) are **not recorded**.
- Duplicates are detected, and the existing entry moves back to the top.
- No Dock icon: Cliper runs as a menu bar–only app.

History is stored locally in `~/Library/Application Support/<bundle id>/` (`history.json` plus an `Images/` folder of PNG files), readable only by your user account. Nothing leaves your Mac.

## Building

Requirements: macOS 14+, Xcode 16+.

Open `Cliper.xcodeproj` in Xcode and press **Run** (⌘R). You may need to choose your own development team under *Signing & Capabilities*.

Or build from the command line:

```bash
xcodebuild -project Cliper.xcodeproj -scheme Cliper -configuration Release -destination 'platform=macOS' -derivedDataPath ./build build
```

The app is then at `build/Build/Products/Release/Cliper.app`. To build without a signing certificate, add `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=`.

## License

License: GPL-3.0-or-later, see [LICENSE](LICENSE).
