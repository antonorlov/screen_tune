# ScreenTune

A lightweight macOS menu bar app for controlling external displays. Built in Swift, no Xcode required.

## Features

### Display Toggle
- Enable/disable external displays with a single click
- Uses undocumented `SLSConfigureDisplayEnabled` private API
- Works on Apple Silicon (M1/M2/M3/M4) + macOS Ventura and later
- Display names resolved via IOKit (AppleCLCD2 / DCPAVServiceProxy)
- Displays identified by stable hardware key (vendor/model/serial) — survives reboots

### Brightness Control
- Software brightness via gamma table manipulation (`CGSetDisplayTransferByTable`)
- Compatible with BetterDisplay — reads and writes using the same gamma table API
- Syncs with external brightness changes when the menu opens
- Full range: 0% (black) to 100%

### Resolution Picker
- Lists all available display modes via `CGDisplayCopyAllDisplayModes`
- Uses private `CGSConfigureDisplayMode` API to set resolution by mode ID
- Bypasses macOS bug where HiDPI modes disappear from the public API after mode switch
- Caches mode list on first load to preserve all options
- Resolution persists for the session (auto-reverts on logout for safety)

### Settings
- **HiDPI only** — filter resolution list to show only HiDPI modes
- **Native aspect only** — filter out resolutions that would stretch/distort the image (enabled by default)
- Native aspect ratio detected automatically via `kDisplayModeNativeFlag`
- Settings persist across app restarts via `@AppStorage`

### General
- Pure SwiftUI `MenuBarExtra` with `.menuBarExtraStyle(.window)`
- Single-file Swift app (~460 lines)
- No Xcode project needed — compiles with `swiftc` from the command line
- Starts at login (configurable via System Settings → Login Items)
- Menu bar only (no Dock icon)

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon (M1/M2/M3/M4)

## Build

```bash
swiftc -parse-as-library \
  -framework SwiftUI \
  -framework CoreGraphics \
  -framework IOKit \
  -F /System/Library/PrivateFrameworks \
  -o ScreenTune.app/Contents/MacOS/ScreenTune \
  menubar.swift
```

## Run

```bash
open ScreenTune.app
```

## Private APIs Used

| API | Purpose |
|-----|---------|
| `SLSConfigureDisplayEnabled` | Enable/disable displays |
| `SLSGetActiveDisplayList` | List active displays |
| `SLSGetDisplayList` | List all displays (including disabled) |
| `CGSConfigureDisplayMode` | Set display resolution by mode ID |

These are undocumented macOS APIs loaded via `dlsym` at runtime. They may break in future macOS updates.

## Known Limitations

- **HiDPI modes may disappear** after switching resolutions — this is a macOS bug (since Sonoma). The app works around it by caching the mode list on first load and using the private `CGSConfigureDisplayMode` API.
- **Brightness is software-only** (gamma dimming) — does not control the monitor's hardware backlight. Works on all displays but does not reduce power consumption.
- **DDC/CI is not supported** — most portable USB-C monitors do not support DDC/CI for hardware brightness control.

## License

MIT
