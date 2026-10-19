# USB full-control design

## Goal

Let AIClockBridge provide the same device controls through USB serial when the clock cannot join the Mac's network. Wi-Fi HTTP remains the preferred transport when available.

## Scope

- Read device information.
- Control display mode, brightness, and sprite reset.
- Upload GIF sprites over USB.
- Keep the existing status, network, and stock pushes working.
- Expose an explicit serial `stop()` lifecycle; external flashing still requires quitting the bridge first.

## Protocol

The current newline parser accepts at most 1,599 data bytes. Acknowledged control and transfer frames have an integer `id`; existing fire-and-forget `#STATUS`, `#NET`, and `#STOCK` frames remain unchanged. Base64 chunks have at most 768 raw bytes (1,024 encoded bytes), leaving room for envelope fields below that limit.

- `#HELLO {"protocol":2}` -> `#DEVICE {"protocol":2,"caps":["info","cmd","upload","sprite_raw"],...}`: negotiation is required before serial control is selected.
- `#INFO? {"id":n}` -> `#INFO {"id":n,...}`: return the serial equivalent of `/api/info`.
- `#CMD {"id":n,"display":"...","brightness":n,"sprite_reset":"..."}` -> `#ACK {"id":n,"ok":true}` or `#ACK {"id":n,"ok":false,"error":"..."}`.
- An upload starts with `#UPLOAD_BEGIN {"id":n,"upload":"uuid","slot":"claude|codex","bytes":n,"sha256":"..."}`. `bytes` is capped at 256 KiB and is accepted only when LittleFS has enough free space for the raw GIF, the largest generated sprite, and a small margin. The app sends `#UPLOAD_CHUNK {"id":n,"upload":"uuid","seq":n,"data":"base64"}` in strictly increasing order, followed by `#UPLOAD_END {"id":n,"upload":"uuid"}`. The device responds to every upload request with `#ACK {"id":n,"upload":"uuid","seq":n,"ok":true}` (omit `seq` for begin/end) or the same shape with `ok:false,error`. It verifies the final byte count and SHA-256 before decode.
- The mirror requests `#SPRITE_RAW_BEGIN {"id":n,"stream":"uuid","slot":"claude|codex"}`. The device responds `#SPRITE_RAW_BEGIN {"id":n,"stream":"uuid","bytes":n,"sha256":"..."}`, then sends ordered `#SPRITE_RAW_CHUNK {"id":n,"stream":"uuid","seq":n,"data":"base64"}` frames. The app acknowledges every one with `#ACK {"id":n,"stream":"uuid","seq":n,"ok":true}`. The device ends with `#SPRITE_RAW_END {"id":n,"stream":"uuid","bytes":n,"sha256":"..."}`; the app verifies both totals before replacing its cache and returns a final ACK. A wrong id, stream, or sequence aborts the transfer and preserves the cache.

The app serializes writes with a write-all queue that handles partial writes, `EINTR`, and `EAGAIN`. During an acknowledged command or transfer it pauses periodic status/network/stock frames. It sends at most one acknowledged request at a time, matches replies by `id`, and reports a timeout without retrying a side-effecting command blindly. The serial scheduler processes transfer acknowledgements at 25ms cadence, not the current 250ms status cadence. Per-chunk timeout is 3 seconds; raw-sprite total timeout is 90 seconds and GIF upload/decode total timeout is 180 seconds. The UI shows phase plus transferred/total bytes throughout.

Uploads write only to a temporary GIF and decode into a temporary sprite binary. A decode failure, checksum mismatch, timeout, disconnect, or oversized input deletes temporary files and preserves the live sprite. Successful decode swaps in the new binary using a recoverable backup/rename sequence; boot recovery restores a backup left by an interrupted swap.

## App transport behavior

`SerialLink` owns USB framing, request IDs, acknowledgements, upload progress, and an explicit `stop()`. `DeviceClient` first selects a reachable HTTP endpoint before starting an operation; only when no endpoint is available and the linked device advertises the required serial capability does it delegate to `SerialLink`. It never retries an ambiguous HTTP operation over serial.

The existing serial status pushes are unchanged. Menu controls use the same UI and automatically select the available transport.

## Validation

- Unit-test the frame parser, capability negotiation, write queue, Base64 chunk sequencing, timeout/abort, and replug handling.
- Build the macOS app and ESP8266 firmware.
- Flash the connected device with AIClockBridge stopped.
- Verify serial handshake, device info, mode change, brightness change, sprite reset, mirror sprite read, and one GIF upload over USB.
- Verify oversized lines, out-of-order chunks, checksum mismatch, failed GIF decode, and interrupted upload preserve the prior sprite.
- Exercise the no-Wi-Fi/no-host UI path and confirm it selects USB rather than showing a host error.
