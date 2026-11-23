# Tuner

A fast, native macOS IPTV player. Add an **Xtream Codes** account or an **M3U** playlist and get your channels in a clean, Apple TV–style grid, with instant search and a player that shows the picture and nothing else.

- **Native:** SwiftUI and [libmpv](https://mpv.io), with hardware decoding through VideoToolbox. It plays MPEG-TS and HLS.
- **Fast with big lists:** tested with 13,000 channels. The catalog is cached on disk, so launch is instant, and it refreshes in the background every 12 hours (or with ⌘R).
- **Organized:** provider categories are grouped by prefix (`ARABIC …`, `EU …`, …), filler "channels" like `===== SPORTS =====` are hidden, and country tags like `|UK|` are stripped from tile names.
- **Search:** results update as you type, ignore case and accents, and list names that start with your query first. Press Return to play the top result.
- **Home:** Continue Watching and Favorites shelves, then every category as a card.
- **Grid or list:** big logo tiles, or a compact list when the name matters more than the logo.
- **Player:** glass controls appear only when the mouse moves and fade about a second after it stops. If the guide has data, the channel's now / next shows there.

## Keys (browsing)

| Key | Action |
| --- | --- |
| Arrows | Move between channels (→ from the sidebar enters the grid, ← at the edge goes back) |
| Return | Play the highlighted channel |
| Just type | Search; Backspace edits, Esc clears |
| ⌘1 / ⌘2 | Grid or list view |
| ⌘R | Refresh the channel list |

## Keys (while playing)

| Key | Action |
| --- | --- |
| ↑ / ↓ | Previous / next channel in the current list |
| ← / → | Volume |
| Space | Pause |
| M | Mute |
| F or double-click | Full screen |
| S | Favorite |
| Esc | Leave full screen, then back to channels |

## Build

Requires macOS 15+, Xcode 16+, and Homebrew.

```bash
brew install mpv xcodegen
xcodegen generate
open Tuner.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project Tuner.xcodeproj -scheme Tuner -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Tuner.app
```

The app links Homebrew's `libmpv` from `/opt/homebrew/lib`. A self-contained build that bundles mpv is on the to-do list.

## Privacy

Playlists, including Xtream credentials, are stored only on your Mac in `~/Library/Application Support/Tuner/sources.json` (readable only by you). The channel cache next to it never contains your password: stream URLs are built when you press play.

## License

MIT
