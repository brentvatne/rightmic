# RightMic

A macOS menu bar app that automatically routes audio from your best available microphone. Define a priority-ordered list of input devices, and RightMic ensures the highest-priority connected mic is always active.

## Features

- **Virtual audio device** — apps using "System Default" always get the right mic
- **Priority-ordered device list** — drag to reorder, RightMic picks the best available
- **Real-time device monitoring** — instantly switches when devices connect/disconnect
- **Works with Loopback** — Rogue Amoeba virtual devices appear as selectable sources
- **Menu-bar-only** — no Dock icon, no window

## Requirements

- macOS 14 (Sonoma) or later
- Microphone permission

## Building

```bash
swift build
swift run
```

## License

MIT
