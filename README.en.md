<p align="center">
  <img src="docs/images/logo.svg" width="72" alt="logo">
</p>

<h1 align="center">AI Mac Mini Display</h1>

<p align="center">A tiny AI status computer for your desk — ESP8266 · Open Source Hardware · Desktop Companion</p>

<p align="center">
  <a href="README.md">中文</a> ·
  English
</p>

<p align="center">
  <a href="https://mac.qust.me">Website</a> ·
  <a href="https://mac.qust.me/#flash">Web Flasher</a> ·
  <a href="https://github.com/pengchujin/esp8266-ai/releases/latest">Download</a>
</p>

<p align="center">
  <img src="docs/images/hero.jpg" width="640" alt="AI Mac Mini Display">
</p>

A retro mini-TV with a 240×240 screen that sits on your desk showing **what Claude Code / Codex CLI are doing right now and how much quota you have left**. No API key needed: everything comes from the CLI credentials and session logs already on your machine, served to the device over your LAN by the companion Mac / Windows bridge app.

## Features

| | |
|---|---|
| <img src="docs/images/feature1.jpg" width="360" alt="AI status"> | **AI status & quota**<br>Pet is walking = the AI is working. A square progress ring plus large digits show your real 5-hour / weekly quota usage; when a window is used up the pet becomes a reset countdown, and the border flashes red when the AI is waiting for your approval. |
| <img src="docs/images/feature2.jpg" width="360" alt="Network monitor"> | **Live network monitor**<br>Task-manager-style upload/download curves, 56-second rolling window, auto-scaling axis. |
| <img src="docs/images/music.jpg" width="360" alt="Now playing"> | **Now playing**<br>Album art, title, artist and progress bar in real time; switches in automatically when music starts, back when it stops. |
| <img src="docs/images/feature3.jpg" width="360" alt="Swappable pets"> | **Swappable pets**<br>Import a standard nine-state Codex Pet package from the local USB control page. Conversion stays on the Mac and transfer needs neither Wi-Fi nor reflashing. |

## Getting started

What you need: an "SD2 mini-TV" dev board ([open-source hardware](https://oshwhub.com/q21182889/sd2), or [buy one assembled](https://mobile.yangkeduo.com/goods.html?ps=OuBjGMWE82)) and a USB **data** cable.

### Step 1 · Flash the firmware (~30 s)

Open **[mac.qust.me/#flash](https://mac.qust.me/#flash)** in Chrome / Edge, plug the device in over USB, click "Connect & Flash", pick the serial port and wait. No tools to install.

> Serial port not showing up? On Windows install the [CH340 driver](https://www.wch.cn/downloads/CH341SER_EXE.html); macOS has it built in. Try another USB cable (many are charge-only). More troubleshooting in the [website FAQ](https://mac.qust.me/#flash-faq).
>
> Command-line folks can also flash `esp8266-ai-firmware-*.bin` from [Releases](https://github.com/pengchujin/esp8266-ai/releases/latest) to address `0x0` with esptool.

### Step 2 · Connect WiFi

On first boot the device opens a hotspot named **`AI-Clock-Setup`**: join it from your phone and the setup page pops up (or browse to `192.168.4.1`), pick your WiFi and enter the password. Done.

### Step 3 · Install the bridge app

Download from [Releases](https://github.com/pengchujin/esp8266-ai/releases/latest) and open:

- **macOS**: `AIClockBridge-*-macOS.dmg`, drag into Applications (ad-hoc signed; on first launch allow it in "System Settings → Privacy & Security" and grant local-network access)
- **Windows**: `AIClockBridge-*-Windows-x64.exe`, just double-click

The bridge lives in your menu bar / tray and **auto-discovers and pairs** with the device on the same LAN — at this point the screen comes alive.

<p align="center">
  <img src="docs/images/working.jpg" width="640" alt="In action">
</p>

Daily use is all on the tray icon: **left-click** opens a live mirror of the device screen (with a brightness slider at the bottom), **right-click** opens the full menu (quota details, screen switching, pet swapping, music/network pages, and more).

## FAQ

- **Screen border flashing red**: the device can't reach the bridge — make sure the app is running and on the same WiFi.
- **Quota shows `-` forever**: no Claude Code / Codex CLI login on this machine, so the bridge has no credentials to read.
- **Want a different Codex pet**: open `http://127.0.0.1:8765/`, choose the folder containing `pet.json` under “Codex nine-state pet”, then upload over USB.

## Development

```
firmware/     ESP8266 firmware (PlatformIO + Arduino, with on-board GIF decoding)
mac-app/      macOS menu bar bridge (Swift/SPM, zero third-party dependencies)
windows-app/  Windows tray bridge (C# / .NET 8 WinForms)
tools/        GIF → RGB565 built-in sprite conversion script
docs/         Developer docs (pinout, HTTP API, architecture details)
```

```bash
cd firmware && pio run -t upload   # firmware: build + flash over USB
cd mac-app && swift run            # Mac bridge: run locally
```

Hardware pinout, display-driver gotchas, the device HTTP API and the on-board GIF decoding architecture are documented in **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)** (Chinese).

Hardware, firmware and software are all open source — modify it, build it, even sell it.
