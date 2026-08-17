# Task Plan: Restore project with only selected features

**Goal:** Start from v0.4.9, add only: AppIcon, Weather/Clock page, Original cow sprite, DeepSeek balance.

## Phases

| # | Phase | Status |
|---|-------|--------|
| 1 | Restore firmware to v0.4.9 base | complete |
| 2 | Add weather page + DeepSeek to firmware (minimal) | complete |
| 3 | Restore mac-app to v0.4.9 + AppIcon | complete |
| 4 | Add weather/DeepSeek to mac-app | complete |
| 5 | Clean firmware: remove wallpaper/bulk/clockAnim | complete |
| 6 | Compile, flash, verify | complete |
| 2 | Add weather page + DeepSeek to firmware (minimal) | pending |
| 3 | Restore mac-app to v0.4.9 + AppIcon | pending |
| 4 | Add weather/DeepSeek to mac-app | pending |
| 5 | Compile, flash, verify | pending |

## Design decisions
- Weather page top-right: built-in weather icon (no GIF upload slot)
- Corner pet: original Claude/Codex cow sprite
- No serial bulk push, no wallpaper, no custom clock GIF
- Mode: MODE_CLOCK for the weather/clock page
