# RightMic

A macOS menu bar app that automatically routes audio from your best available microphone. Define a priority-ordered list of input devices, and RightMic ensures the highest-priority connected mic is always active — through a virtual audio device that any app can use.

## How It Works

RightMic installs a HAL audio driver that creates a virtual input device called "RightMic". The app captures audio from your highest-priority available mic and routes it to the virtual device via shared memory. Apps using the system default input always get the right mic without any reconfiguration.

## Features

- **Virtual audio device** — apps using "System Default" always get the right mic
- **Priority-ordered device list** — drag to reorder in the popover
- **Automatic switching** — instantly switches when devices connect/disconnect
- **Silence detection** — skips devices that are connected but producing no audio
- **Works with virtual devices** — Loopback, Instruments, and similar apps
- **Menu-bar-only** — no Dock icon, no window

## Requirements

- macOS 14 (Sonoma) or later
- Microphone permission
- Developer ID certificate (for signing the HAL driver)

## Building

Build the app:

```bash
swift build
```

Build the HAL driver (requires code signing):

```bash
./scripts/build-driver.sh
```

The driver build auto-detects your Developer ID certificate. You can also specify one:

```bash
./scripts/build-driver.sh --sign "Developer ID Application: Your Name (TEAMID)"
```

## Installing the Driver

The HAL driver must be installed to `/Library/Audio/Plug-Ins/HAL/` and requires admin privileges:

```bash
sudo ./scripts/install-driver.sh
```

This builds the driver, signs it, copies it to the system HAL directory, and restarts `coreaudiod`. After installation, "RightMic" will appear as an input device in System Settings > Sound.

## Running

Run directly from source:

```bash
swift run
```

Or build a full `.app` bundle:

```bash
./scripts/bundle-app.sh
```

The app bundle is output to `build/RightMic.app`.

## Uninstalling

Remove the driver:

```bash
sudo ./scripts/install-driver.sh --remove
```

To fully uninstall, also delete the app and its preferences:

```bash
rm -rf build/RightMic.app
defaults delete com.rightmic.app 2>/dev/null
```

## License

MIT
