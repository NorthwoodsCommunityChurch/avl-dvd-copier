# DVD Copier

A simple macOS app for ripping DVD titles to MKV files using MakeMKV.

<!-- TODO: Add screenshot to docs/images/ and uncomment -->
<!-- ![DVD Copier](docs/images/dvd-copier-main.png) -->

## Features

- Automatic DVD detection when a disc is inserted
- Scans all titles with duration, chapter count, and file size
- Rip one or multiple titles to MKV
- Progress tracking with real-time status from MakeMKV
- Auto-selects the largest title (usually the main feature)
- Creates a subfolder when ripping multiple titles
- Eject disc when done
- Auto-updates via Sparkle

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon (aarch64)
- [MakeMKV](https://www.makemkv.com/) installed in `/Applications`
- External or internal DVD drive

## Installation

1. Download the latest `.zip` from [Releases](https://github.com/NorthwoodsCommunityChurch/avl-dvd-copier/releases)
2. Extract the zip
3. Move `DVD Copier.app` to `/Applications`
4. First launch: macOS will block it — go to **System Settings → Privacy & Security → "Open Anyway"**
5. The app will check for updates automatically after that

## Usage

1. Launch DVD Copier
2. Insert a DVD — the app detects it automatically and scans titles
3. Select which titles to rip (largest is pre-selected)
4. Choose an output folder
5. Click **Rip** — progress shows in real time
6. When done, click **Show in Finder** or **Eject Disc**

## Building from Source

```bash
git clone https://github.com/NorthwoodsCommunityChurch/avl-dvd-copier.git
cd avl-dvd-copier
bash build.sh
```

Requires Xcode Command Line Tools (`xcode-select --install`).

## Project Structure

```
DVD Tool/
├── Sources/DVDCopier/
│   ├── App.swift           # App entry point + Sparkle updater
│   ├── ContentView.swift   # Main UI
│   ├── DVDRipper.swift     # MakeMKV wrapper (scan + rip)
│   ├── DVDTitle.swift      # Title data model
│   ├── DiscWatcher.swift   # DiskArbitration disc detection
│   ├── Version.swift       # Version constants
│   └── Info.plist          # App metadata + Sparkle config
├── AppIcon.icns            # App icon
├── Package.swift           # SPM manifest
├── build.sh                # Build + bundle + sign script
├── CREDITS.md
└── LICENSE
```

## License

[MIT](LICENSE)

## Credits

See [CREDITS.md](CREDITS.md)
