# Implementation Plan: USB full control

## Overview

Add a versioned serial control transport so AIClockBridge keeps the current HTTP behavior when a device is reachable and otherwise provides the same supported controls through USB.

## Task List

### Task 1: Add safe firmware control and info frames

Implement capability negotiation, correlated `#INFO`, `#CMD`, and `#ACK` frames, with a strict parser and backwards-compatible status pushes.

**Acceptance criteria:**
- [ ] v0.4.11 host status frames still render.
- [ ] A protocol-v2 hello advertises capabilities.
- [ ] Info, display, brightness, and reset commands return matching success/error ACKs.

**Verification:** Build firmware and exercise the frames through `/dev/cu.usbserial-120`.

**Dependencies:** None.

**Files:** `firmware/src/main.cpp`.

### Task 2: Make SerialLink a reliable request transport

Add queued write-all behavior, capability state, correlated requests, and a public lifecycle. Retain periodic push behavior outside a control transfer.

**Acceptance criteria:**
- [ ] Partial writes and `EAGAIN` do not drop data.
- [ ] An unavailable or v0.4.11 device fails promptly without routing controls over serial.
- [ ] A command timeout produces one error and resumes periodic pushes.

**Verification:** Build macOS app and run serial protocol checks against the device.

**Dependencies:** Task 1.

**Files:** `mac-app/Sources/AIClockBridge/SerialLink.swift`.

### Task 3: Route app reads and basic controls to USB

Give `DeviceClient` a capability-aware serial fallback; connect mirror info and menu actions without changing their HTTP behavior.

**Acceptance criteria:**
- [ ] No-host UI reads device info via USB.
- [ ] Mode, brightness, and sprite reset work via USB.
- [ ] HTTP remains selected before an operation when it is reachable.

**Verification:** Build macOS app; test each action while the device has no Wi-Fi.

**Dependencies:** Tasks 1-2.

**Files:** `DeviceClient.swift`, `MenuBarController.swift`, `MirrorPopover.swift`, `main.swift`.

### Task 4: Add atomic GIF upload and sprite reads

Implement bounded, checksum-protected upload/download streams and temporary-file decode/commit on the firmware; wire them into the existing picker and mirror.

**Acceptance criteria:**
- [ ] Valid USB GIF upload replaces only the selected sprite.
- [ ] Bad checksum, decode failure, disconnect, and abort preserve the previous sprite.
- [ ] Mirror can refresh a custom sprite through USB.

**Verification:** Firmware/app builds plus a real GIF upload, reset, and raw-sprite mirror check.

**Dependencies:** Tasks 1-3.

**Files:** `firmware/src/main.cpp`, `SerialLink.swift`, `DeviceClient.swift`.

### Task 5: Validate and deploy

Compile both targets, flash with the bridge stopped, then run the USB-only end-to-end path.

**Acceptance criteria:**
- [ ] Firmware Flash verification passes.
- [ ] App displays status and controls the device with Wi-Fi unconfigured.
- [ ] Upload progress and failures are understandable to the user.

**Verification:** Build logs, `esptool verify_flash`, and manual device checks.

**Dependencies:** Tasks 1-4.

## Checkpoints

- After Task 2: firmware and macOS builds pass; old status protocol still works.
- After Task 4: malformed transfers retain the active sprite.
- After Task 5: physical device works without Wi-Fi.

## Risks

| Risk | Mitigation |
|---|---|
| USB serial is slow | 768-byte chunks, 25ms scheduler, progress, bounded 180s upload timeout. |
| Interrupted transfer damages a sprite | Decode and commit only from temporary files with backup recovery. |
| App/flash contention | Stop bridge before flashing; retain an explicit serial lifecycle. |
