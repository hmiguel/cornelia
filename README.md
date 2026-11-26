<p align="center">
  <img src="Resources/icon.png" width="160" alt="Cornelia the cow">
</p>

<h1 align="center">Cornelia</h1>

<p align="center">A small, fast IPTV player for macOS.</p>

Cornelia plays M3U playlists with instant channel switching. It is a native SwiftUI app on top of [libmpv](https://mpv.io), with VideoToolbox hardware decoding, so it plays HLS, raw MPEG-TS and anything else mpv and FFmpeg can open.

Cornelia does not include or point to any channels. Bring your own playlist.

## Features

- Fast: a 100k channel playlist parses in under 100 ms, search filters as you type, and a local TS stream shows its first frame in about 150 ms
- Hardware decoding through VideoToolbox
- Automatic reconnect when live streams drop
- Groups, search, favorites and recents
- Video only fullscreen with auto hiding cursor
- Channel logos with memory and disk caching
- Remote playlists are cached and refreshed in the background, so launch is instant
- Remembers the last channel and resumes it on launch
- Per channel `User-Agent` and `Referer` from `#EXTVLCOPT`

## Download

Grab the latest `.dmg` from [Releases](../../releases/latest), open it and drag Cornelia onto Applications. A `.zip` is there too. Release builds bundle libmpv, so nothing else is needed.

The app is not notarized. On first launch, right click it and choose Open, or run:

    xattr -dr com.apple.quarantine /Applications/Cornelia.app

Release builds are for Apple Silicon and macOS 14 or later.

## Build from source

### Requirements

- macOS 14 or later
- [Homebrew](https://brew.sh) with `mpv` installed (the build script installs it if missing)
- Xcode command line tools (Swift 5.10 or later)

### Build

    git clone <this repo>
    cd cornelia
    ./build.sh

This builds `Cornelia.app` and installs it to `~/Applications`. This dev build links Homebrew's `libmpv`, so keep `mpv` installed.

`./build.sh --release 1.2.0` makes a self-contained build with libmpv and its dependencies bundled, packaged as `dist/Cornelia-1.2.0-arm64.dmg` and `.zip`.

## Releasing

Push a version tag and GitHub Actions builds the self-contained app and publishes a release with the DMG, the zip and their SHA-256 checksums:

    git tag v1.2.0
    git push origin v1.2.0

## Usage

Open a playlist with ⌘O (file) or ⌘L (URL), or drop an `.m3u` file onto the window. ⌘R reloads the playlist.

| Key | Action |
| --- | --- |
| ↑ ↓ (or ⌘↑ ⌘↓) | Previous or next channel |
| ⌫ | Jump back to the last watched channel |
| Space | Pause |
| ← → | Volume |
| M | Mute |
| F, double click | Video only fullscreen (Esc exits) |
| S (or ⌘D) | Toggle favorite |
| I | Stream info: resolution, codec, hardware decoding, fps |
| R | Retry stream |
| Return in search | Play first result |

Supported M3U tags: `#EXTINF` with `tvg-name`, `tvg-logo`, `group-title`, plus `#EXTGRP`, `#EXTVLCOPT:http-user-agent` and `#EXTVLCOPT:http-referrer`.

## Privacy

Playlists, favorites and settings stay on your Mac (`~/Library/Preferences/local.cornelia.player.plist` and `~/Library/Application Support/Cornelia`). Cornelia has no analytics and talks to no server other than the playlist, logo and stream URLs you give it.

## Development

    swift build -c release
    CORNELIA_DEBUG=1 .build/release/Cornelia

Debug mode logs mpv messages, playback events and render state to stderr.

| File | Purpose |
| --- | --- |
| `M3UParser.swift` | Byte level M3U parser |
| `MPVPlayer.swift` | libmpv wrapper, events, auto reconnect |
| `MPVVideoView.swift` | OpenGL layer fed by the libmpv render API |
| `AppModel.swift` | Playlist loading, caching, filtering, keyboard, fullscreen |
| `Views.swift` | SwiftUI interface |
| `scripts/make-icon.swift` | Generates the app icon |

To regenerate the icon:

    swift scripts/make-icon.swift /tmp/icon
    iconutil -c icns /tmp/icon/AppIcon.iconset -o Resources/AppIcon.icns

## Credits

Created by Hugo Conceicao ([@hmiguel](https://github.com/hmiguel)). Playback by [mpv](https://mpv.io) and [FFmpeg](https://ffmpeg.org).

## License

GPL-3.0. See [LICENSE](LICENSE). Cornelia links libmpv, which Homebrew builds under the GPL.
