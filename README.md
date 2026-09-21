<picture>
<img style="pointer-events:none"  alt="cover-milo_mac-github@2x" src="https://github.com/user-attachments/assets/b5907f49-818a-477f-8ba9-c96e4430c571" />
</picture>



# Milō Mac

Control Milō from your Mac, as if it had always been there.

Milō Mac is a menu-bar companion for [Milō](https://github.com/leodurandfr/Milo), the
Raspberry Pi audio appliance. It finds your Milō on the local network and gives you its
sources, its volume and its multiroom zones from a native macOS panel — no browser, no
window to keep open. It can also stream your Mac's own audio to it.

## Requirements

- macOS 26 (Tahoe) or later. The panel is built on macOS 26 API and does not run on
  earlier versions.
- A Milō device reachable on the same network as your Mac.

## Install

Download the latest `.dmg` from the [releases page](https://github.com/leodurandfr/Milo-Mac/releases),
open it, and drag `Milō.app` into your **Applications** folder. The app is signed and
notarized by Apple, so it opens without a warning.

Milō Mac finds your device by itself over Bonjour — there is nothing to configure.

## Using it

- **Click** the menu-bar icon to open the panel: sources, the track playing, volume, and
  multiroom if it is enabled on your Milō.
- **Option + Click** the icon to reveal Settings and Quit.
- **Right-Option + ↑ / ↓** changes the volume from anywhere, with an on-screen HUD. The
  step is configurable in Settings, and macOS will ask for Accessibility permission the
  first time.
- Sources are read from your Milō: whatever you enable and reorder on the device is what
  the panel shows.

The interface is available in English, French, German, Spanish, Italian, Portuguese,
Hindi and Simplified Chinese.

## Sending your Mac's audio to Milō

The **Mac** source plays your Mac's audio through Milō. It needs
[roc-vad](https://github.com/roc-streaming/roc-vad), a virtual audio driver, which
Settings can install for you. The driver only becomes active after a restart.

This is entirely optional. Without it, everything else works as usual and the Mac source
simply shows as unavailable.

## Building from source

Open `Milo Mac.xcodeproj` in Xcode 26 or later and build the `Milo Mac` scheme. The
deployment target is macOS 26.0, and the project builds warning-free at Swift 6 language
mode.

## Uninstalling

Run [`uninstall.sh`](uninstall.sh) to remove the app along with its preferences, its
login item and, if you installed it, the roc-vad driver.

## License

[GPL-3.0](LICENSE)

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
