# ActiveTrack

Lightweight macOS menu bar app to manually track active time on your laptop. Start when working, pause when stepping away. No daily resets — time is attributed to whichever calendar day it occurs on.

## Features

- **Menu bar popover** — start/pause timer, see today's total at a glance
- **Live indicator** — red dot + elapsed time when running, yellow dot + time when paused
- **Auto-pause on sleep** — closing the lid pauses the timer automatically
- **Midnight rollover** — running timer auto-restarts at midnight, saving the previous day's time
- **Survives restarts** — open intervals recover automatically on launch, including cross-day recovery
- **Dashboard** — day list sidebar with daily/weekly/monthly bar charts
- **Persistent storage** — all data stored locally with SwiftData

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+ to build from source

## Install

```bash
git clone https://github.com/andresdefi/ActiveTrack.git
cd ActiveTrack
xcodebuild -scheme ActiveTrack -configuration Release build
```

Then copy the built `.app` from `DerivedData` to `/Applications`.

## Tech

SwiftUI · SwiftData · Swift Charts · @Observable
