---
name: import-custom-pet
description: Imports, uploads, installs, resets, or troubleshoots custom Codex Pet packages on this project's ESP device through the local USB bridge. Use when the user mentions importing a pet, uploading a spritesheet, changing the ESP pet, xijingping pet, pet.json, spritesheet.webp, or the 127.0.0.1:8765 pet controls.
---

# Import Custom Pet

Use only this project's `aiclock-usb` service and USB control page. Never launch,
install, or route pet operations through AIClockBridge.

## Supported input

A pet directory must contain exactly one `pet.json` with a non-empty `id` and
its referenced `spritesheet.webp` or PNG.

- v1: 1536x1872, 8 columns x 9 rows, 192x208 per cell.
- v2: `spriteVersionNumber: 2`, 1536x2288, 8 columns x 11 rows. ESP imports the
  first nine rows.
- The current ESP payload is `AIPET1`: 57 frames, 144x144 RGB332, 1,182,080
  bytes, with CRC32. It requires firmware `0.4.14` or newer with the 2MB
  LittleFS partition. A protocol-3 device running an older firmware still
  rejects this payload.

The 144x144 converter lives only in `aiclock-usb`; do not use AIClockBridge or
its desktop Pet picker to import a current ESP pet. A legacy 120x120 AIPET1
file is invalid on current firmware.

Treat the source directory as read-only. Reject a `spritesheetPath` that escapes
the pet directory. Do not silently resize or repair a malformed package.

If the user only has character art rather than a complete package, say that a
Codex Pet package must be created first. Use `hatch-pet` when it is available
and the user also asks to create or repair the pet.

## Workflow

1. Resolve the pet directory from the user's path or the project context. Common
   installed packages live under `~/.codex/pets/<id>/`.
2. Build the CLI, then run the CLI preflight and inspect the local bridge in
   parallel:

   ```bash
   swift build -c release
   .build/release/aiclock-usb pet-preflight ~/.codex/pets/<id>
   curl -sS http://127.0.0.1:8765/api/status
   ```

   Preflight validates the manifest, path boundary, source dimensions, all 57
   frames, generated 1,182,080-byte AIPET1 payload, and payload CRC. Require
   `usb.connected: true`, `usb.protocol >= 3`, and firmware `0.4.14` or newer;
   report firmware, port, and current `custom_pet`.
3. Skip visual QA for a normal fast import. Inspect a QA contact sheet or source
   frames only when the user requests QA, the package is untrusted, or the
   preflight fails.
4. Choose one import path below. Do not run both.
5. Verify the final bridge response contains `usb.connected: true` and
   `usb.custom_pet: true`.

## Import paths

### User-driven control page

Use this only when the user asks to operate the UI or the package directory is
not accessible to the agent:

1. Open `http://127.0.0.1:8765/`.
2. In **Codex 九状态宠物**, choose the directory containing `pet.json`.
3. Click upload and keep USB connected until the page reports installation.
4. Poll `/api/status` until `pet_upload.active` is false; fail if
   `pet_upload.error` is non-null.

The browser performs conversion locally. Do not upload pet files to an external
service and do not modify Codex desktop pet settings.

### Agent-driven USB CLI

Use this by default when the user supplies an accessible v1 or v2 package and
asks the agent to complete the installation. The background bridge owns the
serial port, so stop it temporarily and always restore it afterward.

Run the provided script from any directory:

```bash
.agents/skills/import-custom-pet/scripts/install-pet.sh ~/.codex/pets/<id>
```

The script builds the release CLI, stops only `local.aiclock-usb`, runs
`aiclock-usb pet-install`, restores the 8765 LaunchAgent even after failure,
then waits up to 30 seconds for `usb.connected: true` and `usb.custom_pet: true`.
The CLI accepts both v1 and v2 packages; v2 imports the first nine rows. It
converts every package to the current 144x144 format. Request the required
local process/serial approval when the execution sandbox requires it.

## Firmware migration

Firmware `0.4.14` moves LittleFS from 1MB to 2MB to hold the 144x144 payload.
The first boot formats a legacy 1MB LittleFS volume. Before this firmware is
installed, warn that existing custom pets and LittleFS-backed display settings
will be removed; after installation, re-import the selected pet with this
skill. Do not attempt to upload a 144x144 payload before the firmware update.

## Reset

When the user explicitly asks to restore the firmware pet:

```bash
curl -sS -X POST http://127.0.0.1:8765/api/pet/reset
```

Verify `usb.custom_pet: false`. Do not reset a custom pet merely to diagnose an
upload problem because the device cannot retain two full 1.18MB payloads.

## Troubleshooting

- Control page unavailable: check `launchctl print gui/$(id -u)/local.aiclock-usb`
  and whether port 8765 is listening. Reinstall only the `aiclock-usb`
  LaunchAgent when necessary.
- USB disconnected: inspect `/dev/cu.usbserial*`; do not guess another serial
  device if more than one candidate exists.
- Firmware below `0.4.14` or protocol below 3: update the ESP firmware before
  importing; the current 144x144 payload will be rejected otherwise.
- A 120x120 payload or a preflight result other than `device_bytes: 1182080`:
  rebuild `aiclock-usb` from this repository. Do not use a desktop-app uploader
  as a fallback.
- Upload interrupted or CRC rejected: keep the built-in fallback, restore the
  bridge, and report the exact device error (including expected/actual CRC when
  provided). Retry only after the connection is stable.
- Serial busy: check for another `aiclock-usb` process. Do not start
  AIClockBridge as a workaround.

## Completion report

Lead with whether installation succeeded. Include:

- pet id/display name and source directory;
- USB port, firmware, and protocol;
- upload/CRC confirmation;
- final `custom_pet` value;
- the control-page link;
- any validation or build commands that failed.

Do not claim the device knows the pet's name: its status reports only whether a
custom pet is installed.
