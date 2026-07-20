// ESP8266 WiFi clock: shows local time plus live Claude Code / Codex CLI
// working status and usage quota, polled from a small bridge service that
// runs on the developer's Mac (see ../bridge/bridge.py).
//
// Display: 240x240 SPI ST7789 (TFT_eSPI). Pin mapping is set via build_flags
// in platformio.ini - edit those if your wiring differs.

#include <Arduino.h>
#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <ESP8266HTTPClient.h>
#include <WiFiClient.h>
#include <WiFiManager.h>
#include <LittleFS.h>
#include <ArduinoJson.h>
#include <TFT_eSPI.h>
#include <AnimatedGIF.h>
#include <time.h>

#include "config.h"
#include "img/claude_sprite.h"
#include "img/codex_sprite.h"
#include "img/claude_logo.h"
#include "img/codex_logo.h"
#include "img/weather_icons.h"

TFT_eSPI tft = TFT_eSPI();
ESP8266WebServer webServer(80);

// ---------- custom sprite storage (LittleFS) ----------
// Custom uploads replace the compiled-in default animation without needing a
// firmware rebuild. You POST a raw .gif straight to /sprite/claude or
// /sprite/codex (the device serves its own upload page at "/"); the ESP8266
// decodes and rescales the GIF *on-device* (AnimatedGIF, line-by-line so it
// never needs a full-canvas buffer) into the wire format below, which the
// display path then reads back frame-by-frame:
//   [1 byte frame count][frame0 bytes][frame1 bytes]...
// Each frame is exactly CLAUDE_SPRITE_W x H (or CODEX_SPRITE_W x H) RGB565
// pixels, byte order matching tools/convert_sprites.py's to_rgb565() so the
// compiled-in defaults and custom uploads share one draw path.
const char *CLAUDE_SPRITE_FILE = "/c.bin";
const char *CODEX_SPRITE_FILE = "/x.bin";
const char *CLAUDE_GIF_FILE = "/c.gif"; // raw upload, decoded then removed
const char *CODEX_GIF_FILE = "/x.gif";
const int MAX_CUSTOM_FRAMES = 8;
const size_t CLAUDE_FRAME_BYTES = (size_t)CLAUDE_SPRITE_W * CLAUDE_SPRITE_H * 2;
const size_t CODEX_FRAME_BYTES = (size_t)CODEX_SPRITE_W * CODEX_SPRITE_H * 2;

// We never hold a whole sprite frame in RAM. Decoding a GIF needs ~24KB of
// heap for AnimatedGIF's own buffers, which wouldn't fit alongside a static
// full-frame buffer (a 120x120 frame is ~28KB) on the ESP8266's ~80KB. So both
// the display path and the decoder work one screen-row at a time through these
// two small scratch rows (SCREEN_W is the widest we ever need).
uint16_t rowBuf[SCREEN_W];     // current row being drawn / decoded
uint16_t prevRowBuf[SCREEN_W]; // decode only: same row from the previous frame

bool claudeCustom = false;
int claudeCustomFrames = 0;
bool codexCustom = false;
int codexCustomFrames = 0;
uint32_t spriteRev = 0; // bumped on upload/reset so the Mac mirror re-fetches

const int SCREEN_CX = 120, SCREEN_CY = 120;
const int RING_MARGIN = 4;      // inset from screen edge
const int RING_THICKNESS = 10;  // ring bar thickness
const unsigned long ANIM_INTERVAL_MS = 120;  // sprite frame advance
const unsigned long FLASH_INTERVAL_MS = 400; // "urgent" flash speed
const unsigned long SWITCH_BOTH_MS = 2000;   // both apps working: alternate fast
const unsigned long SWITCH_IDLE_MS = 6000;   // neither working: alternate slow

enum ActiveApp { APP_CLAUDE, APP_CODEX };
ActiveApp currentApp = APP_CLAUDE;
unsigned long lastSwitchMs = 0;

// Display override, settable from the Mac app via POST /api/display:
// auto = follow working status, claude/codex = pin that app on screen,
// net/music = show Mac-side telemetry pages instead of the pet.
enum DisplayMode { MODE_AUTO, MODE_CLAUDE, MODE_CODEX, MODE_NET, MODE_MUSIC, MODE_STOCK, MODE_CLOCK };
DisplayMode displayMode = MODE_CLOCK; // default: weather clock page

// When AUTO and the Mac reports audio playing, the screen auto-switches to the
// music page and back when it stops — same spirit as the Claude/Codex auto
// switch. Only AUTO does this; a pinned mode is always honored as-is.
bool statusMusicPlaying = false;
DisplayMode lastEffectiveMode = MODE_AUTO;

// ---------- net speed mode state ----------
// Rendering is decoupled from the network: pollNet() fetches every 2s and
// only refills a queue of 250ms samples (the bridge samples at 4Hz and tags
// them with a running seq, so nothing is drawn twice or skipped). The sweep
// itself consumes exactly one queued sample every NET_DRAW_INTERVAL_MS, so
// the trace advances at a constant rate no matter how long HTTP takes.
const unsigned long NET_POLL_INTERVAL_MS = 2000; // queue refill cadence
const unsigned long NET_DRAW_INTERVAL_MS = 250;  // one chart step per bridge sample
const int NET_QUEUE = 32;
long netQRx[NET_QUEUE], netQTx[NET_QUEUE]; // ring buffer of pending samples
int netQHead = 0, netQCount = 0;
long netSeq = -1;                          // last bridge sample seq consumed into the queue
long netCurRx = 0, netCurTx = 0;           // smoothed readout for the header
int netCpuPct = -1, netMemPct = -1;        // Mac CPU/MEM row; -1 = bridge sends none (hidden)
String netLastCpuVal, netLastMemVal;       // change detection for the CPU/MEM values
bool netSysLabelsDrawn = false;
unsigned long lastNetPollMs = 0;
unsigned long lastNetDrawMs = 0;
bool netChromeDrawn = false;
bool netHeaderDirty = false;

// Chart layout (task-manager style scrolling area chart, newest at the right)
const int NET_CHART_X = 8, NET_CHART_Y = 60, NET_CHART_W = 224, NET_CHART_H = 128;
long netHistRx[NET_CHART_W], netHistTx[NET_CHART_W]; // one 250ms sample per column
long netScale = 10240;    // current "nice" full-scale value (whole chart shares it)
String netLastDl, netLastUl, netLastScaleText; // change detection for partial redraws

// ---------- music mode state ----------
const int MUSIC_COVER_W = 128;
const int MUSIC_COVER_H = 128;
// Title/artist come as a Mac-rendered bitmap strip (232x44) because the
// panel fonts are ASCII-only and CJK titles would render as blanks.
const int MUSIC_TEXT_W = 232;
const int MUSIC_TEXT_H = 44;
const int MUSIC_TEXT_X = 4, MUSIC_TEXT_Y = 150;
const unsigned long MUSIC_POLL_INTERVAL_MS = 2000;
// ---------- stock watchlist mode state ----------
// Rows come pre-formatted from the bridge (GET /stock or serial #STOCK):
// ASCII code + price/pct strings + up flag, so the firmware just paints.
const unsigned long STOCK_POLL_INTERVAL_MS = 5000;
const int MAX_STOCKS = 4;
struct StockRow {
  String code, price, pct;
  int up = 0; // 1 rising (red, CN convention) / -1 falling (green) / 0 flat
};
StockRow stocks[MAX_STOCKS];
int stockCount = 0;
bool stockEverLoaded = false;
bool stockDirty = false;
bool stockChromeDrawn = false;
String stockLastCode[MAX_STOCKS]; // top line (code + CJK name strip)
String stockLastVal[MAX_STOCKS];  // value line (price + pct)
unsigned long lastStockPollMs = 0;
// CJK names come as Mac-rendered RGB565 strips (GET /stock/names.raw, one
// 156x16 strip per row) - names_rev says when to re-fetch. -1 = not drawn.
const int STOCK_NAME_W = 156, STOCK_NAME_H = 16;
int stockNamesRev = -1;
int stockNamesDrawnRev = -1;

String musicTitle, musicArtist, musicAlbum;
bool musicPlaying = false;
int musicElapsed = 0, musicDuration = 0;
int musicArtworkRev = -1;
int musicTextRev = -1;
bool musicHasArtwork = false;
bool musicChromeDrawn = false;
unsigned long lastMusicPollMs = 0;

// Wired (serial) music art: the bridge pushes cover + title strip as
// #COVER/#MTEXT bulk transfers that land in LittleFS and blit from there
// (the WiFi path fetches /music/cover.raw + /music/text.raw instead).
const char *COVER_TMP = "/cover.tmp";
const char *COVER_FILE = "/cover.bin";
const char *MTEXT_TMP = "/mtext.tmp";
const char *MTEXT_FILE = "/mtext.bin";
const size_t MUSIC_COVER_BYTES = 128 * 128 * 2;
const size_t MUSIC_TEXT_BYTES = 232 * 44 * 2;
int coverFileRev = -1; // rev stored in COVER_FILE (-1 = none this boot)
int mtextFileRev = -1; // rev stored in MTEXT_FILE
bool musicCoverDirty = false, musicTextDirty = false;
bool coverEverDrawn = false, mtextEverDrawn = false;
bool blitMusicFile(const char *path, int x, int y, int w, int h); // defined with the wired bulk receiver

int claudeFrame = 0;
int codexFrame = 0;
unsigned long lastAnimMs = 0;

bool flashOn = true;
unsigned long lastFlashMs = 0;

// Bridge host is not asked for during first-time WiFi setup: the Mac/Windows
// bridge discovers the device and pairs automatically (or set via /api/bridge).
String bridgeHost;

struct ClaudeStatus {
  String status = "unknown";
  long tokensToday = 0;
  int sessionMin = 0;
  int sessionWindowMin = 300;
  float fiveHourPct = -1; // real OAuth quota from the bridge, -1 = unknown
  int fiveHourResetMin = -1; // minutes until the 5h window resets
  float sevenDayPct = -1;
  int sevenDayResetMin = -1; // minutes until the 7-day window resets
  bool needsInput = false; // waiting on a permission/approval prompt
};

struct CodexStatus {
  String status = "unknown";
  long tokensToday = 0;
  float primaryPct = -1;
  int primaryResetMin = -1;
  float weeklyPct = -1;
  int weeklyResetMin = -1;
  bool needsInput = false;
};

ClaudeStatus claudeStatus;
CodexStatus codexStatus;

unsigned long lastPollMs = 0;
unsigned long lastSuccessMs = 0;
bool everPolled = false;
bool mainUiShown = false;      // false while the config-portal screen is up
bool webServerStarted = false; // deferred: port 80 clashes with the portal

// ---------- backlight brightness ----------
// The panel backlight (TFT_BL, active LOW) is PWM-dimmable — the vendor's own
// firmware does the same. 0 = off, 100 = full. Persisted so it survives reboot.

int brightness = BRIGHTNESS_DEFAULT; // 0-100

void applyBrightness() {
  // analogWriteRange(100) is set in setup(), so the duty value is just the
  // inverted percentage (active LOW: 0 duty = always LOW = full on).
  analogWrite(TFT_BL, 100 - brightness);
}

void loadBrightness() {
  if (!LittleFS.exists(BRIGHTNESS_FILE)) return;
  File f = LittleFS.open(BRIGHTNESS_FILE, "r");
  if (!f) return;
  int v = f.readStringUntil('\n').toInt();
  f.close();
  if (v >= 0 && v <= 100) brightness = v;
}

void saveBrightness() {
  File f = LittleFS.open(BRIGHTNESS_FILE, "w");
  if (!f) return;
  f.println(brightness);
  f.close();
}

// ---------- persistence for the bridge host ----------

void loadBridgeHost() {
  if (LittleFS.exists(WIFI_CONFIG_FILE)) {
    File f = LittleFS.open(WIFI_CONFIG_FILE, "r");
    bridgeHost = f.readStringUntil('\n');
    bridgeHost.trim();
    f.close();
  }
}

void saveBridgeHost(const String &host) {
  File f = LittleFS.open(WIFI_CONFIG_FILE, "w");
  f.println(host);
  f.close();
}

// ---------- custom sprite loading ----------

// Checks LittleFS for a previously-uploaded custom sprite and validates its
// size before trusting it (frame count byte + exact expected byte length).
void loadCustomSpriteState() {
  claudeCustom = false;
  if (LittleFS.exists(CLAUDE_SPRITE_FILE)) {
    File f = LittleFS.open(CLAUDE_SPRITE_FILE, "r");
    if (f && f.size() >= 1) {
      uint8_t cnt = f.read();
      size_t expected = 1 + (size_t)cnt * CLAUDE_FRAME_BYTES;
      if (cnt > 0 && cnt <= MAX_CUSTOM_FRAMES && (size_t)f.size() == expected) {
        claudeCustom = true;
        claudeCustomFrames = cnt;
      }
    }
    if (f) f.close();
  }

  codexCustom = false;
  if (LittleFS.exists(CODEX_SPRITE_FILE)) {
    File f = LittleFS.open(CODEX_SPRITE_FILE, "r");
    if (f && f.size() >= 1) {
      uint8_t cnt = f.read();
      size_t expected = 1 + (size_t)cnt * CODEX_FRAME_BYTES;
      if (cnt > 0 && cnt <= MAX_CUSTOM_FRAMES && (size_t)f.size() == expected) {
        codexCustom = true;
        codexCustomFrames = cnt;
      }
    }
    if (f) f.close();
  }

  Serial.printf("[sprite] claude custom=%d frames=%d | codex custom=%d frames=%d\n", claudeCustom,
                claudeCustomFrames, codexCustom, codexCustomFrames);
}

int claudeFrameCount() { return claudeCustom ? claudeCustomFrames : CLAUDE_SPRITE_FRAMES; }
int codexFrameCount() { return codexCustom ? codexCustomFrames : CODEX_SPRITE_FRAMES; }

// Draws one sprite frame centered on screen, one row at a time so we never
// need a full-frame buffer: each row comes either from the custom LittleFS
// file (streamed) or the compiled-in PROGMEM default (copied row-by-row).
void drawSpriteFrame(bool custom, const char *file, const uint16_t *const *progmemFrames, int frameIdx, int w,
                     int h, size_t frameBytes) {
  int x0 = SCREEN_CX - w / 2, y0 = SCREEN_CY - h / 2;
  size_t rowBytes = (size_t)w * 2;
  if (custom) {
    File f = LittleFS.open(file, "r");
    if (!f) return;
    f.seek(1 + (size_t)frameIdx * frameBytes);
    for (int r = 0; r < h; r++) {
      f.read((uint8_t *)rowBuf, rowBytes);
      tft.pushImage(x0, y0 + r, w, 1, rowBuf);
    }
    f.close();
  } else {
    const uint16_t *frame = progmemFrames[frameIdx];
    for (int r = 0; r < h; r++) {
      memcpy_P(rowBuf, frame + (size_t)r * w, rowBytes);
      tft.pushImage(x0, y0 + r, w, 1, rowBuf);
    }
  }
}

// ---------- helpers ----------

String formatTokens(long tokens) {
  if (tokens >= 1000000) {
    char buf[16];
    snprintf(buf, sizeof(buf), "%.1fM", tokens / 1000000.0);
    return String(buf);
  }
  if (tokens >= 1000) {
    char buf[16];
    snprintf(buf, sizeof(buf), "%.1fk", tokens / 1000.0);
    return String(buf);
  }
  return String(tokens);
}

// ---------- drawing ----------

void drawStaticChrome() {
  tft.fillScreen(TFT_BLACK);
}

// Bridge unreachable / data stale -> flashing red overrides everything else,
// matches the "urgent, look now" state from the reference signal-light design.
bool bridgeStale() {
  if (!everPolled) return true;
  return (millis() - lastSuccessMs) >= 2UL * BRIDGE_POLL_INTERVAL_MS;
}

// True when the app currently on screen is waiting on a permission/approval
// prompt — drives the red "look now, act" border flash.
bool currentAppNeedsInput() {
  return currentApp == APP_CLAUDE ? claudeStatus.needsInput : codexStatus.needsInput;
}

// Working vs idle is now conveyed by the sprite animation itself (moving vs
// still), not by ring color. The ring just stays steady green, except
// bridge-stale which flashes red ("check it now") and overrides everything.
uint16_t currentStatusColor() {
  if (bridgeStale()) return flashOn ? TFT_RED : TFT_BLACK;
  return TFT_GREEN;
}

// The ring is skipped when nothing changed (see drawSquareRing) so the 5s
// poll doesn't visibly blank-and-repaint it. Anything that paints over the
// ring area must invalidate this cache.
float ringLastPct = -1000;
uint16_t ringLastColor = 1;

// Paints the full square border in one color (all four sides), used for the
// attention flash so the whole edge blinks, not just the filled quota arc.
void drawFullBorder(uint16_t color) {
  ringLastPct = -1000; // ring got painted over; next ring draw must repaint
  int x0 = RING_MARGIN, y0 = RING_MARGIN;
  int side = SCREEN_W - 2 * RING_MARGIN;
  tft.fillRect(x0, y0, side, RING_THICKNESS, color);                              // top
  tft.fillRect(x0, SCREEN_H - RING_MARGIN - RING_THICKNESS, side, RING_THICKNESS, color); // bottom
  tft.fillRect(x0, y0, RING_THICKNESS, side, color);                              // left
  tft.fillRect(SCREEN_W - RING_MARGIN - RING_THICKNESS, y0, RING_THICKNESS, side, color); // right
}

// Square progress ring hugging the screen edge. `pct` of the perimeter
// (clockwise from top-left) is drawn in `color`, the rest in dark grey.
void drawSquareRing(float pct, uint16_t color) {
  if (pct < 0) pct = 0;
  if (pct > 100) pct = 100;
  if (pct == ringLastPct && color == ringLastColor) return; // nothing changed
  ringLastPct = pct;
  ringLastColor = color;

  int x0 = RING_MARGIN, y0 = RING_MARGIN;
  int x1 = SCREEN_W - RING_MARGIN, y1 = SCREEN_H - RING_MARGIN;
  int side = x1 - x0;
  float perimeter = side * 4.0;

  // Unfilled track is drawn black (not grey) so it blends into the background
  // and only the active quota portion is visible - still needs to be actively
  // repainted each time though, to erase a previously longer fill if the
  // percentage drops (e.g. a quota window reset).
  tft.fillRect(x0, y0, side, RING_THICKNESS, TFT_BLACK);                  // top
  tft.fillRect(x1 - RING_THICKNESS, y0, RING_THICKNESS, side, TFT_BLACK); // right
  tft.fillRect(x0, y1 - RING_THICKNESS, side, RING_THICKNESS, TFT_BLACK); // bottom
  tft.fillRect(x0, y0, RING_THICKNESS, side, TFT_BLACK);                  // left

  // filled portion, clockwise: top -> right -> bottom -> left
  float remaining = perimeter * (pct / 100.0);
  if (remaining <= 0) return;

  float seg = min(remaining, (float)side);
  tft.fillRect(x0, y0, (int)seg, RING_THICKNESS, color);
  remaining -= side;
  if (remaining <= 0) return;

  seg = min(remaining, (float)side);
  tft.fillRect(x1 - RING_THICKNESS, y0, RING_THICKNESS, (int)seg, color);
  remaining -= side;
  if (remaining <= 0) return;

  seg = min(remaining, (float)side);
  tft.fillRect(x1 - (int)seg, y1 - RING_THICKNESS, (int)seg, RING_THICKNESS, color);
  remaining -= side;
  if (remaining <= 0) return;

  seg = min(remaining, (float)side);
  tft.fillRect(x0, y1 - (int)seg, RING_THICKNESS, (int)seg, color);
}

void drawClaudeSprite(int frameIdx) {
  drawSpriteFrame(claudeCustom, CLAUDE_SPRITE_FILE, claude_sprite_frames, frameIdx, CLAUDE_SPRITE_W,
                  CLAUDE_SPRITE_H, CLAUDE_FRAME_BYTES);
}

void drawCodexSprite(int frameIdx) {
  drawSpriteFrame(codexCustom, CODEX_SPRITE_FILE, codex_sprite_frames, frameIdx, CODEX_SPRITE_W, CODEX_SPRITE_H,
                  CODEX_FRAME_BYTES);
}

String pctText(float pct) {
  return pct >= 0 ? String((int)pct) + "%" : "-";
}

// Quota readout below the sprite: two columns ("5h" / "Wk"), small grey label
// over a big font-4 percentage. Values repaint only when their text changes
// (force = after a full-screen clear), so the 5s poll never flashes them.
const int QUOTA_LABEL_Y = 183, QUOTA_VALUE_Y = 199;
const int QUOTA_COL1_X = 70, QUOTA_COL2_X = 170;
String lastQuota5h, lastQuotaWk;

// Faux-bold: the packed TFT_eSPI fonts have no bold face, so draw twice with
// a 1px x offset. Transparent draws - the caller must have cleared the region.
void drawBoldString(const String &s, int x, int y, int font, uint16_t color) {
  tft.setTextColor(color);
  tft.drawString(s, x, y, font);
  tft.drawString(s, x + 1, y, font);
}

void drawQuotaText(float hourPct, float weekPct, bool force) {
  // Codex dropped the 5h window (2026-07): the bridge then sends
  // primary_pct=null, so collapse to a single centered "Wk" column.
  bool single = hourPct < 0 && weekPct >= 0;
  static int8_t lastSingle = -1;
  if ((int8_t)single != lastSingle) {
    lastSingle = (int8_t)single;
    force = true;
    tft.fillRect(0, QUOTA_LABEL_Y, 240, QUOTA_VALUE_Y + 26 - QUOTA_LABEL_Y, TFT_BLACK);
  }
  tft.setTextDatum(TC_DATUM);
  if (single) {
    if (force) drawBoldString("Wk", 120, QUOTA_LABEL_Y, 2, TFT_LIGHTGREY);
    String v = pctText(weekPct);
    if (force || v != lastQuotaWk) {
      lastQuotaWk = v;
      lastQuota5h = "";
      tft.fillRect(120 - 50, QUOTA_VALUE_Y, 100, 26, TFT_BLACK);
      drawBoldString(v, 120, QUOTA_VALUE_Y, 4, TFT_WHITE);
    }
    return;
  }
  if (force) {
    drawBoldString("5h", QUOTA_COL1_X, QUOTA_LABEL_Y, 2, TFT_LIGHTGREY);
    drawBoldString("Wk", QUOTA_COL2_X, QUOTA_LABEL_Y, 2, TFT_LIGHTGREY);
  }
  String v1 = pctText(hourPct), v2 = pctText(weekPct);
  if (force || v1 != lastQuota5h) {
    lastQuota5h = v1;
    tft.fillRect(QUOTA_COL1_X - 50, QUOTA_VALUE_Y, 100, 26, TFT_BLACK);
    drawBoldString(v1, QUOTA_COL1_X, QUOTA_VALUE_Y, 4, TFT_WHITE);
  }
  if (force || v2 != lastQuotaWk) {
    lastQuotaWk = v2;
    tft.fillRect(QUOTA_COL2_X - 50, QUOTA_VALUE_Y, 100, 26, TFT_BLACK);
    drawBoldString(v2, QUOTA_COL2_X, QUOTA_VALUE_Y, 4, TFT_WHITE);
  }
}

// ---------- quota-exhausted countdown ----------
// When the current app's 5h or weekly window is used up, the pet is replaced
// by a countdown to that window's reset (bridge sends minutes-until-reset).
// A spent weekly window blocks usage even after the 5h one resets, so the
// weekly countdown takes priority when both are exhausted.

enum CdType { CD_NONE, CD_5H, CD_WEEK };

float currentHourPct() {
  return currentApp == APP_CLAUDE ? claudeStatus.fiveHourPct : codexStatus.primaryPct;
}

int currentHourResetMin() {
  return currentApp == APP_CLAUDE ? claudeStatus.fiveHourResetMin : codexStatus.primaryResetMin;
}

float currentWeekPct() {
  return currentApp == APP_CLAUDE ? claudeStatus.sevenDayPct : codexStatus.weeklyPct;
}

int currentWeekResetMin() {
  return currentApp == APP_CLAUDE ? claudeStatus.sevenDayResetMin : codexStatus.weeklyResetMin;
}

CdType desiredCountdown() {
  if (currentWeekPct() >= 99.9f && currentWeekResetMin() >= 0) return CD_WEEK;
  if (currentHourPct() >= 99.9f && currentHourResetMin() >= 0) return CD_5H;
  return CD_NONE;
}

CdType showingCd = CD_NONE; // what's on screen now (vs desiredCountdown())
String lastCountdown;

// The bridge only reports whole minutes, so the seconds tick locally against
// a deadline anchored at millis(). Re-anchor only when the bridge disagrees
// by more than ~a minute (new window, big clock drift), otherwise a poll
// landing mid-minute would make the seconds jump around.
unsigned long cdDeadlineMs = 0; // 0 = not anchored
ActiveApp cdApp = APP_CLAUDE;   // which app/window the anchor belongs to
CdType cdAnchorType = CD_NONE;

void syncCountdownDeadline() {
  int m = showingCd == CD_WEEK ? currentWeekResetMin() : currentHourResetMin();
  if (m < 0) {
    cdDeadlineMs = 0;
    return;
  }
  long bridgeSec = (long)m * 60 + 30; // bridge floors to minutes: assume mid-minute
  long ourSec = (long)(cdDeadlineMs - millis()) / 1000;
  if (cdDeadlineMs == 0 || cdApp != currentApp || cdAnchorType != showingCd || ourSec < 0 ||
      labs(ourSec - bridgeSec) > 90) {
    cdDeadlineMs = millis() + (unsigned long)bridgeSec * 1000UL;
    cdApp = currentApp;
    cdAnchorType = showingCd;
  }
}

void drawCountdown(bool force) {
  long remain = cdDeadlineMs ? (long)(cdDeadlineMs - millis()) / 1000
                             : (long)(showingCd == CD_WEEK ? currentWeekResetMin() : currentHourResetMin()) * 60;
  if (remain < 0) remain = 0;
  char buf[16];
  long hours = remain / 3600;
  if (hours >= 100) // weekly can be up to 168h: h:mm:ss wouldn't fit the ring
    snprintf(buf, sizeof(buf), "%ld:%02ld", hours, (remain % 3600) / 60);
  else
    snprintf(buf, sizeof(buf), "%ld:%02ld:%02ld", hours, (remain % 3600) / 60, remain % 60);
  String t(buf);
  if (!force && t == lastCountdown) return;
  // in-place glyph overwrite can't erase a shrinking string (h:mm:ss width is
  // constant, but 100:00 -> 99:59:59 changes layout once) - clear on any
  // length change
  if (t.length() != lastCountdown.length()) force = true;
  lastCountdown = t;
  tft.setTextDatum(TC_DATUM);
  if (force) {
    tft.fillRect(SCREEN_CX - 99, 66, 198, 84, TFT_BLACK);
    drawBoldString(showingCd == CD_WEEK ? "Wk RESET IN" : "5h RESET IN", SCREEN_CX, 72, 2, TFT_LIGHTGREY);
  }
  // Background-color draw overwrites glyphs in place (no clear-then-draw
  // flash between seconds).
  tft.setTextColor(TFT_ORANGE, TFT_BLACK);
  tft.drawString(t, SCREEN_CX, 102, 6);
}

// App logo in the top-left corner (inside the quota ring) so a glance tells
// which app the screen is currently showing. Drawn row-by-row from PROGMEM
// through rowBuf, same as the sprite path.
const int LOGO_X = 14, LOGO_Y = 18;

void drawAppLogo() {
  const uint16_t *logo = (currentApp == APP_CLAUDE) ? claude_logo_0 : codex_logo_0;
  int w = (currentApp == APP_CLAUDE) ? CLAUDE_LOGO_W : CODEX_LOGO_W;
  int h = (currentApp == APP_CLAUDE) ? CLAUDE_LOGO_H : CODEX_LOGO_H;
  for (int r = 0; r < h; r++) {
    memcpy_P(rowBuf, logo + (size_t)r * w, (size_t)w * 2);
    tft.pushImage(LOGO_X, LOGO_Y + r, w, 1, rowBuf);
  }
}

// Codex's ring percentage: the 5h window when it exists, otherwise the
// weekly one (Codex removed the 5h limit in 2026-07).
float codexRingPct() {
  if (codexStatus.primaryPct >= 0) return codexStatus.primaryPct;
  return max(codexStatus.weeklyPct, 0.0f);
}

// Claude's ring percentage: real 5h OAuth quota from the bridge when known,
// otherwise fall back to elapsed session time as a rough stand-in.
float claudeRingPct() {
  if (claudeStatus.fiveHourPct >= 0) return claudeStatus.fiveHourPct;
  return claudeStatus.sessionWindowMin > 0
             ? (100.0 * claudeStatus.sessionMin / claudeStatus.sessionWindowMin)
             : 0;
}

// Redraws whichever app is currently active, full screen: quota ring +
// sprite (or the reset countdown while the 5h window is exhausted).
// Full clear + repaint - only for real transitions (app switch, mode return,
// sprite change); steady-state data updates go through refreshActiveApp().
void drawActiveApp() {
  tft.fillScreen(TFT_BLACK);
  ringLastPct = -1000; // screen was cleared: force the ring repaint
  showingCd = desiredCountdown();
  if (showingCd != CD_NONE) syncCountdownDeadline();
  else cdDeadlineMs = 0;
  if (currentApp == APP_CLAUDE) {
    drawSquareRing(claudeRingPct(), currentStatusColor());
    if (showingCd == CD_NONE) drawClaudeSprite(claudeFrame);
    drawQuotaText(claudeRingPct(), claudeStatus.sevenDayPct, true);
  } else {
    drawSquareRing(codexRingPct(), currentStatusColor());
    if (showingCd == CD_NONE) drawCodexSprite(codexFrame);
    drawQuotaText(codexStatus.primaryPct, codexStatus.weeklyPct, true);
  }
  if (showingCd != CD_NONE) drawCountdown(true);
  drawAppLogo();
}

// In-place refresh after a bridge poll: ring repaint + only the text that
// actually changed. No fillScreen, so the 5s poll doesn't blank the screen.
void refreshActiveApp() {
  if (desiredCountdown() != showingCd) { // pet <-> countdown (or 5h <-> weekly) swap
    drawActiveApp();
    return;
  }
  if (currentApp == APP_CLAUDE) {
    drawSquareRing(claudeRingPct(), currentStatusColor());
    drawQuotaText(claudeRingPct(), claudeStatus.sevenDayPct, false);
  } else {
    drawSquareRing(codexRingPct(), currentStatusColor());
    drawQuotaText(codexStatus.primaryPct, codexStatus.weeklyPct, false);
  }
  if (showingCd != CD_NONE) {
    syncCountdownDeadline();
    drawCountdown(false);
  }
}

// Redraws just the ring (cheap) - used for status color animation ticks
// between full redraws.
void redrawRingOnly() {
  if (currentApp == APP_CLAUDE) {
    drawSquareRing(claudeRingPct(), currentStatusColor());
  } else {
    drawSquareRing(codexRingPct(), currentStatusColor());
  }
}

// Who gets the screen:
//   - display mode pinned (Mac app) -> that app, always
//   - exactly one app working       -> that app, immediately
//   - both working                  -> alternate every SWITCH_BOTH_MS (2s)
//   - neither working               -> alternate slowly (SWITCH_IDLE_MS)
bool updateActiveApp() {
  ActiveApp desired = currentApp;

  if (displayMode == MODE_CLAUDE) {
    desired = APP_CLAUDE;
  } else if (displayMode == MODE_CODEX) {
    desired = APP_CODEX;
  } else if (claudeStatus.needsInput && !codexStatus.needsInput) {
    desired = APP_CLAUDE; // approval prompt wins the screen
  } else if (codexStatus.needsInput && !claudeStatus.needsInput) {
    desired = APP_CODEX;
  } else {
    bool claudeWorking = claudeStatus.status == "working";
    bool codexWorking = codexStatus.status == "working";
    if (claudeWorking && !codexWorking) {
      desired = APP_CLAUDE;
    } else if (codexWorking && !claudeWorking) {
      desired = APP_CODEX;
    } else {
      unsigned long interval = (claudeWorking && codexWorking) ? SWITCH_BOTH_MS : SWITCH_IDLE_MS;
      if (millis() - lastSwitchMs >= interval) {
        lastSwitchMs = millis();
        desired = (currentApp == APP_CLAUDE) ? APP_CODEX : APP_CLAUDE;
      }
    }
  }

  if (desired != currentApp) {
    currentApp = desired;
    lastSwitchMs = millis();
    return true;
  }
  return false;
}

// ---------- net speed screen ----------

String speedText(long bps) {
  char buf[16];
  if (bps >= 1000000) snprintf(buf, sizeof(buf), "%.1fM", bps / 1000000.0);
  else if (bps >= 1000) snprintf(buf, sizeof(buf), "%.0fK", bps / 1000.0);
  else snprintf(buf, sizeof(buf), "%ldB", bps);
  return String(buf);
}

// pushImage() colors must be pre-byte-swapped (this firmware never enables
// setSwapBytes; see the sprite pipeline). Natural RGB565 -> wire order:
inline uint16_t swap565(uint16_t c) { return (uint16_t)((c << 8) | (c >> 8)); }

void resetNetChart() {
  memset(netHistRx, 0, sizeof(netHistRx));
  memset(netHistTx, 0, sizeof(netHistTx));
  netScale = 10240;
  netLastDl = "";
  netLastUl = "";
  netLastScaleText = "";
  netLastCpuVal = "";
  netLastMemVal = "";
  netSysLabelsDrawn = false;
  netQHead = 0;
  netQCount = 0;
  netSeq = -1;
}

// Adaptive full scale: the window's peak always lands at ~87% of the chart
// height, so the undulation stays visible no matter the absolute speed.
// (The old 1/2/5 stepped scale could squash everything to under half height.)
long adaptiveNetScale(long maxV) {
  long s = maxV + maxV / 7; // ~1.15x headroom above the peak
  return s > 10240 ? s : 10240;
}

// Static chrome: labels that never change while in net mode.
void drawNetChrome() {
  tft.fillScreen(TFT_BLACK);
  tft.setTextDatum(TL_DATUM);
  tft.setTextColor(0x7BEF, TFT_BLACK);
  tft.drawString("DOWN", 14, 10, 1);
  tft.drawString("UP", 134, 10, 1);
  tft.setTextDatum(TC_DATUM);
  tft.drawString("MAC NET  -  56s", SCREEN_CX, 226, 1); // below the CPU/MEM row
}

// Mac CPU / memory usage row between the chart and the footer: small grey
// labels at fixed positions, big font-4 values left-aligned at fixed x so a
// width change (5% -> 30%) never shifts the rest of the row around.
// Hidden only if an old bridge doesn't send the fields yet.
const int NET_SYS_Y = 192;                          // row top (26px tall, font 4)
const int NET_CPU_LABEL_X = 28, NET_CPU_VAL_X = 62; // value region 62..126 ("100%" = 63px)
const int NET_MEM_LABEL_X = 130, NET_MEM_VAL_X = 164;

void drawNetSysinfoIfChanged() {
  if (netCpuPct < 0) {
    if (netSysLabelsDrawn) { // bridge stopped sending: erase the whole row
      tft.fillRect(0, NET_SYS_Y, SCREEN_W, 26, TFT_BLACK);
      netSysLabelsDrawn = false;
      netLastCpuVal = "";
      netLastMemVal = "";
    }
    return;
  }
  tft.setTextDatum(TL_DATUM);
  if (!netSysLabelsDrawn) {
    netSysLabelsDrawn = true;
    tft.setTextColor(0x7BEF, TFT_BLACK);
    tft.drawString("CPU", NET_CPU_LABEL_X, NET_SYS_Y + 6, 2);
    tft.drawString("MEM", NET_MEM_LABEL_X, NET_SYS_Y + 6, 2);
  }
  String c = String(netCpuPct) + "%", m = String(netMemPct) + "%";
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  if (c != netLastCpuVal) {
    netLastCpuVal = c;
    tft.fillRect(NET_CPU_VAL_X, NET_SYS_Y, 64, 26, TFT_BLACK);
    tft.drawString(c, NET_CPU_VAL_X, NET_SYS_Y, 4);
  }
  if (m != netLastMemVal) {
    netLastMemVal = m;
    tft.fillRect(NET_MEM_VAL_X, NET_SYS_Y, 64, 26, TFT_BLACK);
    tft.drawString(m, NET_MEM_VAL_X, NET_SYS_Y, 4);
  }
}

// Header readouts (1s-averaged), each repainted only when its text changes.
void drawNetHeaderIfChanged() {
  String dl = speedText(netCurRx) + "/s";
  String ul = speedText(netCurTx) + "/s";
  tft.setTextDatum(TL_DATUM);
  if (dl != netLastDl) {
    netLastDl = dl;
    tft.fillRect(12, 20, 116, 28, TFT_BLACK);
    tft.setTextColor(TFT_GREEN, TFT_BLACK);
    tft.drawString(dl, 12, 20, 4);
  }
  if (ul != netLastUl) {
    netLastUl = ul;
    tft.fillRect(132, 20, 108, 28, TFT_BLACK);
    tft.setTextColor(TFT_YELLOW, TFT_BLACK);
    tft.drawString(ul, 132, 20, 4);
  }
}

// Repaints the whole chart region from the sample ring, one row at a time
// through rowBuf (a single pushImage per row = no clear-then-draw flicker).
// Download is a dim-green filled area with a bright top edge; upload is a
// 2px yellow line on top; faint gridlines at 25/50/75%.
void drawNetChart() {
  static const uint16_t COL_GRID = swap565(0x2104);   // very dark grey
  static const uint16_t COL_FILL = swap565(0x02A0);   // dim green
  static const uint16_t COL_EDGE = swap565(TFT_GREEN);
  static const uint16_t COL_UL = swap565(TFT_YELLOW);
  static const uint16_t COL_BLACK = swap565(TFT_BLACK);

  long maxV = 0;
  for (int i = 0; i < NET_CHART_W; i++) {
    if (netHistRx[i] > maxV) maxV = netHistRx[i];
    if (netHistTx[i] > maxV) maxV = netHistTx[i];
  }
  netScale = adaptiveNetScale(maxV);

  // Per-column heights (3-tap smoothed), then per-column line "bands": each
  // band spans from the previous column's height to this one's, so steep
  // rises/falls render as connected vertical strokes instead of detached
  // stair-step dots — that's what makes the undulation read as a continuous
  // line, like the Mac mirror's stroked polyline.
  static uint8_t hRx[NET_CHART_W], hTx[NET_CHART_W];
  static uint8_t dlLo[NET_CHART_W], dlHi[NET_CHART_W]; // DL edge band, incl. 3px weight
  static uint8_t ulLo[NET_CHART_W], ulHi[NET_CHART_W]; // UL line band
  // The panel is physically tiny (2.7cm across), so the stroke must be much
  // thicker than the Mac mirror's to read at the same visual weight.
  const int LINE_T = 10; // stroke thickness in px
  for (int i = 0; i < NET_CHART_W; i++) {
    int lo = i > 0 ? i - 1 : 0, hi = i < NET_CHART_W - 1 ? i + 1 : NET_CHART_W - 1;
    long rx = (netHistRx[lo] + netHistRx[i] + netHistRx[hi]) / 3;
    long tx = (netHistTx[lo] + netHistTx[i] + netHistTx[hi]) / 3;
    int hr = (int)((float)rx / netScale * (NET_CHART_H - 2));
    int ht = (int)((float)tx / netScale * (NET_CHART_H - 2));
    hRx[i] = (uint8_t)constrain(hr, 0, NET_CHART_H - 1);
    hTx[i] = (uint8_t)constrain(ht, 0, NET_CHART_H - 1);
  }
  for (int i = 0; i < NET_CHART_W; i++) {
    int prevR = i > 0 ? hRx[i - 1] : hRx[0];
    int prevT = i > 0 ? hTx[i - 1] : hTx[0];
    dlHi[i] = (uint8_t)max((int)hRx[i], prevR);
    dlLo[i] = (uint8_t)max(0, min((int)hRx[i], prevR) - (LINE_T - 1));
    ulHi[i] = (uint8_t)max((int)hTx[i], prevT);
    ulLo[i] = (uint8_t)max(0, min((int)hTx[i], prevT) - (LINE_T - 1));
  }

  for (int row = 0; row < NET_CHART_H; row++) {
    int yFromBot = NET_CHART_H - 1 - row;
    bool gridRow = (row == NET_CHART_H / 4 || row == NET_CHART_H / 2 || row == 3 * NET_CHART_H / 4);
    for (int i = 0; i < NET_CHART_W; i++) {
      uint16_t c = gridRow ? COL_GRID : COL_BLACK;
      if (yFromBot <= dlHi[i] && yFromBot >= dlLo[i]) c = COL_EDGE;
      else if (yFromBot < dlLo[i]) c = COL_FILL;
      if (ulHi[i] > 0 && yFromBot <= ulHi[i] && yFromBot >= ulLo[i]) c = COL_UL;
      rowBuf[i] = c;
    }
    tft.pushImage(NET_CHART_X, NET_CHART_Y + row, NET_CHART_W, 1, rowBuf);
    if ((row & 31) == 31) yield();
  }

  // axis label (outside the chart, so it never gets repainted over)
  String scaleText = speedText(netScale);
  if (scaleText != netLastScaleText) {
    netLastScaleText = scaleText;
    tft.fillRect(120, 48, 112, 10, TFT_BLACK);
    tft.setTextDatum(TR_DATUM);
    tft.setTextColor(0x7BEF, TFT_BLACK);
    tft.drawString(scaleText, NET_CHART_X + NET_CHART_W, 48, 1);
    tft.setTextDatum(TL_DATUM);
  }
}

// Chart tick, every NET_DRAW_INTERVAL_MS: shift in queued sample(s), then
// one atomic repaint. If the queue backs up after a slow poll, it works off
// up to three samples per tick until it's back in step.
void netDrawTick() {
  if (!netChromeDrawn) {
    resetNetChart();
    drawNetChrome();
    netChromeDrawn = true;
    netHeaderDirty = true;
  }
  if (netHeaderDirty) {
    drawNetHeaderIfChanged();
    drawNetSysinfoIfChanged();
    netHeaderDirty = false;
  }
  if (netQCount == 0) return;
  int steps = min(netQCount, netQCount > 16 ? 3 : 1);
  while (steps-- > 0 && netQCount > 0) {
    memmove(netHistRx, netHistRx + 1, sizeof(long) * (NET_CHART_W - 1));
    memmove(netHistTx, netHistTx + 1, sizeof(long) * (NET_CHART_W - 1));
    netHistRx[NET_CHART_W - 1] = netQRx[netQHead];
    netHistTx[NET_CHART_W - 1] = netQTx[netQHead];
    netQHead = (netQHead + 1) % NET_QUEUE;
    netQCount--;
  }
  drawNetChart();
}

// Ingests one /net payload (from HTTP polling or a serial #NET frame) into
// the sample queue. The seq field tells us which samples we've already
// queued, so overlapping tails are fine.
bool handleNetPayload(const String &payload) {
  JsonDocument doc;
  if (deserializeJson(doc, payload)) return false;
  netCurRx = doc["rx_bps"] | 0L;
  netCurTx = doc["tx_bps"] | 0L;
  netCpuPct = doc["cpu_pct"] | -1;
  netMemPct = doc["mem_pct"] | -1;
  netHeaderDirty = true;
  long seq = doc["seq"] | -1L;
  JsonArray rx = doc["rx"], tx = doc["tx"];
  int n = min(rx.size(), tx.size());
  // how many of the tail samples are new to us
  int fresh = (netSeq < 0) ? min(n, 8) : (int)min((long)n, seq - netSeq);
  if (fresh < 0) fresh = 0;
  for (int i = n - fresh; i < n; i++) {
    if (netQCount >= NET_QUEUE) break; // queue full: drop the excess
    int tail = (netQHead + netQCount) % NET_QUEUE;
    netQRx[tail] = rx[i].as<long>();
    netQTx[tail] = tx[i].as<long>();
    netQCount++;
  }
  if (seq >= 0) netSeq = seq;
  return true;
}

// Refills the sample queue from the bridge's /net endpoint.
void pollNet() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) return;
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + "/net";
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);
  if (!http.begin(client, url)) return;
  int code = http.GET();
  if (code == HTTP_CODE_OK) handleNetPayload(http.getString());
  http.end();
}

String timeText(int sec) {
  if (sec < 0) sec = 0;
  char buf[12];
  snprintf(buf, sizeof(buf), "%d:%02d", sec / 60, sec % 60);
  return String(buf);
}

String fitText(String s, int maxPx, int font) {
  if (tft.textWidth(s, font) <= maxPx) return s;
  while (s.length() > 0 && tft.textWidth(s + "...", font) > maxPx) {
    s.remove(s.length() - 1);
  }
  return s + "...";
}

void drawMusicCoverPlaceholder() {
  const int x = (SCREEN_W - MUSIC_COVER_W) / 2;
  const int y = 14;
  tft.fillRect(x, y, MUSIC_COVER_W, MUSIC_COVER_H, TFT_DARKGREY);
  tft.drawRect(x, y, MUSIC_COVER_W, MUSIC_COVER_H, TFT_DARKGREY);
  tft.setTextDatum(MC_DATUM);
  tft.setTextColor(TFT_LIGHTGREY, TFT_DARKGREY);
  tft.drawString("No Art", SCREEN_CX, y + MUSIC_COVER_H / 2, 2);
}

bool drawMusicCoverFromBridge() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0 || !musicHasArtwork) return false;
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + "/music/cover.raw";
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);
  if (!http.begin(client, url)) return false;
  int code = http.GET();
  if (code != HTTP_CODE_OK) {
    http.end();
    return false;
  }
  WiFiClient *stream = http.getStreamPtr();
  const int x = (SCREEN_W - MUSIC_COVER_W) / 2;
  const int y = 14;
  const size_t rowBytes = (size_t)MUSIC_COVER_W * 2;
  bool ok = true;
  for (int r = 0; r < MUSIC_COVER_H; r++) {
    int got = stream->readBytes((uint8_t *)rowBuf, rowBytes);
    if (got != (int)rowBytes) {
      ok = false;
      break;
    }
    tft.pushImage(x, y + r, MUSIC_COVER_W, 1, rowBuf);
    yield();
  }
  http.end();
  return ok;
}

// Streams the Mac-rendered 232x44 title/artist strip and blits it row by
// row — the only way to get CJK on screen without shipping a font.
bool drawMusicTextFromBridge() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) return false;
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + "/music/text.raw";
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);
  if (!http.begin(client, url)) return false;
  int code = http.GET();
  if (code != HTTP_CODE_OK) {
    http.end();
    return false;
  }
  WiFiClient *stream = http.getStreamPtr();
  const size_t rowBytes = (size_t)MUSIC_TEXT_W * 2;
  bool ok = true;
  for (int r = 0; r < MUSIC_TEXT_H; r++) {
    int got = stream->readBytes((uint8_t *)rowBuf, rowBytes);
    if (got != (int)rowBytes) {
      ok = false;
      break;
    }
    tft.pushImage(MUSIC_TEXT_X, MUSIC_TEXT_Y + r, MUSIC_TEXT_W, 1, rowBuf);
    yield();
  }
  http.end();
  return ok;
}

// ASCII-only fallback if the strip fetch fails (CJK will stay blank, but at
// least latin titles show something).
void drawMusicTextFallback() {
  tft.fillRect(MUSIC_TEXT_X, MUSIC_TEXT_Y, MUSIC_TEXT_W, MUSIC_TEXT_H, TFT_BLACK);
  tft.setTextDatum(TC_DATUM);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  String title = musicTitle.length() ? musicTitle : "No Music";
  tft.drawString(fitText(title, 216, 2), SCREEN_CX, MUSIC_TEXT_Y + 4, 2);
  tft.setTextColor(TFT_LIGHTGREY, TFT_BLACK);
  tft.drawString(fitText(musicArtist, 216, 2), SCREEN_CX, MUSIC_TEXT_Y + 24, 2);
}

// Regions repaint independently: cover / text strip only when their rev
// changes, progress bar + time on every poll (partial fill, no flicker
// elsewhere).
void drawMusicProgress() {
  const int bx = 20, by = 204, bw = 200, bh = 8;
  tft.fillRect(0, by - 2, SCREEN_W, SCREEN_H - by + 2, TFT_BLACK);
  tft.fillRect(bx, by, bw, bh, TFT_DARKGREY);
  float progress = musicDuration > 0 ? (float)musicElapsed / (float)musicDuration : 0;
  if (progress < 0) progress = 0;
  if (progress > 1) progress = 1;
  uint16_t color = musicPlaying ? TFT_GREEN : TFT_LIGHTGREY;
  tft.fillRect(bx, by, (int)(bw * progress), bh, color);
  tft.setTextDatum(TC_DATUM);
  tft.setTextColor(TFT_LIGHTGREY, TFT_BLACK);
  tft.drawString(timeText(musicElapsed) + " / " + timeText(musicDuration), SCREEN_CX, 220, 1);
}

void drawMusicScreen(bool coverChanged, bool textChanged) {
  if (!musicChromeDrawn) {
    tft.fillScreen(TFT_BLACK);
    coverChanged = true;
    textChanged = true;
    musicChromeDrawn = true;
  }
  if (coverChanged) {
    if (!drawMusicCoverFromBridge()) drawMusicCoverPlaceholder();
  }
  if (textChanged) {
    if (!drawMusicTextFromBridge()) drawMusicTextFallback();
  }
  drawMusicProgress();
}

// Shared field update for the /music payload (HTTP poll) and the wired
// "#MUSIC " frame; reports which revs moved so the caller can repaint.
bool applyMusicJson(const String &json, bool *coverChanged, bool *textChanged) {
  JsonDocument doc;
  if (deserializeJson(doc, json)) return false;
  musicTitle = doc["title"] | "";
  musicArtist = doc["artist"] | "";
  musicAlbum = doc["album"] | "";
  musicPlaying = doc["playing"] | false;
  statusMusicPlaying = musicPlaying; // fast stop-detection while music shows
  musicElapsed = doc["elapsed"] | 0;
  musicDuration = doc["duration"] | 0;
  musicHasArtwork = doc["has_artwork"] | false;
  int rev = doc["artwork_rev"] | -1;
  *coverChanged = rev != musicArtworkRev;
  musicArtworkRev = rev;
  int tRev = doc["text_rev"] | -1;
  *textChanged = tRev != musicTextRev;
  musicTextRev = tRev;
  return true;
}

// Wired-mode music page: metadata arrives as #MUSIC frames, cover + text
// strip as #COVER/#MTEXT bulk pushes into LittleFS. Progress updates every
// frame; art repaints when its file catches up to the wanted rev (the old
// art stays up while a push is in flight — no placeholder flash).
void drawMusicScreenWired() {
  if (!musicChromeDrawn) {
    tft.fillScreen(TFT_BLACK);
    musicChromeDrawn = true;
    musicCoverDirty = true;
    musicTextDirty = true;
  }
  if (musicCoverDirty) {
    musicCoverDirty = false;
    if (!musicHasArtwork) {
      drawMusicCoverPlaceholder();
      coverEverDrawn = true;
    } else if (coverFileRev == musicArtworkRev &&
               blitMusicFile(COVER_FILE, (SCREEN_W - MUSIC_COVER_W) / 2, 14, MUSIC_COVER_W, MUSIC_COVER_H)) {
      coverEverDrawn = true;
    } else if (!coverEverDrawn) {
      drawMusicCoverPlaceholder();
      coverEverDrawn = true;
    }
  }
  if (musicTextDirty) {
    musicTextDirty = false;
    if (mtextFileRev == musicTextRev &&
        blitMusicFile(MTEXT_FILE, MUSIC_TEXT_X, MUSIC_TEXT_Y, MUSIC_TEXT_W, MUSIC_TEXT_H)) {
      mtextEverDrawn = true;
    } else if (!mtextEverDrawn) {
      drawMusicTextFallback();
      mtextEverDrawn = true;
    }
  }
  drawMusicProgress();
}

void pollMusic() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) return;
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + "/music";
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);
  if (!http.begin(client, url)) return;
  int code = http.GET();
  if (code == HTTP_CODE_OK) {
    bool coverChanged = false, textChanged = false;
    if (applyMusicJson(http.getString(), &coverChanged, &textChanged))
      drawMusicScreen(coverChanged, textChanged);
  }
  http.end();
}

// ---------- stock watchlist screen ----------

bool handleStockPayload(const String &payload) {
  JsonDocument doc;
  if (deserializeJson(doc, payload)) return false;
  JsonArray arr = doc["stocks"];
  stockCount = 0;
  for (JsonObject s : arr) {
    if (stockCount >= MAX_STOCKS) break;
    stocks[stockCount].code = s["code"] | "";
    stocks[stockCount].price = s["price"] | "";
    stocks[stockCount].pct = s["pct"] | "";
    stocks[stockCount].up = s["up"] | 0;
    stockCount++;
  }
  stockNamesRev = doc["names_rev"] | -1;
  stockEverLoaded = true;
  stockDirty = true;
  return true;
}

// Streams the Mac-rendered name strips and blits one per row (top line,
// right of the ASCII code). Wired-only mode has no HTTP: codes still show.
bool drawStockNames() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) return false;
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + "/stock/names.raw";
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);
  if (!http.begin(client, url)) return false;
  int code = http.GET();
  if (code != HTTP_CODE_OK) {
    http.end();
    return false;
  }
  WiFiClient *stream = http.getStreamPtr();
  uint8_t cnt = 0;
  if (stream->readBytes(&cnt, 1) != 1) {
    http.end();
    return false;
  }
  const size_t rowBytes = (size_t)STOCK_NAME_W * 2;
  bool ok = true;
  for (int i = 0; i < cnt && ok; i++) {
    int y0 = 10 + i * 54;
    for (int r = 0; r < STOCK_NAME_H; r++) {
      if (stream->readBytes((uint8_t *)rowBuf, rowBytes) != (int)rowBytes) {
        ok = false;
        break;
      }
      if (i < stockCount) tft.pushImage(70, y0 + r, STOCK_NAME_W, 1, rowBuf);
      yield();
    }
  }
  http.end();
  return ok;
}

void pollStock() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) return;
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + "/stock";
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);
  if (!http.begin(client, url)) return;
  int code = http.GET();
  if (code == HTTP_CODE_OK) handleStockPayload(http.getString());
  http.end();
}

// 54px per row: small grey code on top, big font-4 price (white) on the left
// and change% on the right - red rising / green falling (CN convention).
// Rows repaint only when their text changes, same trick as everywhere else.
void drawStockScreen() {
  if (!stockChromeDrawn) {
    tft.fillScreen(TFT_BLACK);
    stockChromeDrawn = true;
    for (int i = 0; i < MAX_STOCKS; i++) {
      stockLastCode[i] = "\x01"; // force repaint
      stockLastVal[i] = "\x01";
    }
    stockNamesDrawnRev = -1;
    tft.setTextDatum(TC_DATUM);
    tft.setTextColor(0x7BEF, TFT_BLACK);
    tft.drawString("STOCKS", SCREEN_CX, 228, 1);
  }
  stockDirty = false;

  if (stockCount == 0) {
    if (stockLastCode[0] != "") {
      for (int i = 0; i < MAX_STOCKS; i++) {
        stockLastCode[i] = "";
        stockLastVal[i] = "";
      }
      tft.fillRect(0, 0, SCREEN_W, 226, TFT_BLACK);
      tft.setTextDatum(TC_DATUM);
      tft.setTextColor(TFT_LIGHTGREY, TFT_BLACK);
      tft.drawString(stockEverLoaded ? "No stocks configured" : "Waiting for bridge...", SCREEN_CX, 100, 2);
      if (stockEverLoaded) tft.drawString("Mac menu: Set watchlist", SCREEN_CX, 124, 2);
    }
    return;
  }

  for (int i = 0; i < MAX_STOCKS; i++) {
    int y0 = 10 + i * 54;
    bool has = i < stockCount;
    // top line (code + name strip) and value line refresh independently, so
    // a price tick never wipes the name bitmap
    String codeKey = has ? stocks[i].code : "";
    if (codeKey != stockLastCode[i]) {
      stockLastCode[i] = codeKey;
      tft.fillRect(0, y0, SCREEN_W, 17, TFT_BLACK);
      stockNamesDrawnRev = -1; // strip area wiped: re-fetch names
      if (has) {
        tft.setTextDatum(TL_DATUM);
        tft.setTextColor(0x7BEF, TFT_BLACK);
        tft.drawString(stocks[i].code, 14, y0, 2);
      }
    }
    String valKey = has ? stocks[i].price + "|" + stocks[i].pct + "|" + String(stocks[i].up) : "";
    if (valKey != stockLastVal[i]) {
      stockLastVal[i] = valKey;
      tft.fillRect(0, y0 + 18, SCREEN_W, 36, TFT_BLACK); // value line + inter-row gap
      if (has) {
        tft.setTextDatum(TL_DATUM);
        tft.setTextColor(TFT_WHITE, TFT_BLACK);
        tft.drawString(stocks[i].price, 14, y0 + 18, 4);
        uint16_t pc = stocks[i].up > 0 ? TFT_RED : (stocks[i].up < 0 ? TFT_GREEN : TFT_LIGHTGREY);
        tft.setTextDatum(TR_DATUM);
        tft.setTextColor(pc, TFT_BLACK);
        tft.drawString(stocks[i].pct, 226, y0 + 18, 4);
      }
    }
  }

  // CJK name strips, re-fetched when the watchlist (names_rev) changes
  if (stockNamesRev >= 0 && stockNamesDrawnRev != stockNamesRev) {
    if (drawStockNames()) stockNamesDrawnRev = stockNamesRev;
  }
}

// ---------- clock mode (SNTP wall clock; works without the bridge) ----------
// Time comes from the ESP8266 core's built-in SNTP (configTime) once WiFi is
// up; in wired-only mode (no WiFi -> no SNTP) the bridge pushes an "epoch"
// field inside /status (and #STATUS) that we settimeofday() from instead.
// The clock page deliberately never red-flashes on bridge loss: a stale
// bridge is not an alert condition for a wall clock.
const unsigned long CLOCK_TICK_MS = 500; // 2Hz tick -> 1Hz colon blink
bool ntpConfigured = false;
bool clockChromeDrawn = false;
String clockLastTime, clockLastDate;
unsigned long lastClockTickMs = 0;
bool clockColonOn = true;

void setupNtp() {
  if (ntpConfigured) return;
  configTime(CLOCK_TZ, CLOCK_NTP_SERVER1, CLOCK_NTP_SERVER2);
  ntpConfigured = true;
  Serial.println("[clock] SNTP configured, tz=" CLOCK_TZ);
}

// Bridge-supplied epoch. Accept only sane values so a garbage payload can't
// scramble the display.
void setClockFromEpoch(long epoch) {
  if (epoch < 1700000000L) return; // before 2023-11: clearly bogus
  timeval tv;
  tv.tv_sec = epoch;
  tv.tv_usec = 0;
  settimeofday(&tv, nullptr);
}

bool clockTimeValid() { return time(nullptr) > 1700000000L; }

// ASCII-only: the panel fonts have no CJK glyphs. FONT7 is a 48px 7-segment
// face containing digits, '-' and ':' - perfect for HH:MM. The colon blinks
// at 1Hz as the seconds indicator. Repaints are change-detected, so a steady
// minute only draws once; the blink only repaints 5 glyphs.
const char *WEEKDAY_EN[] = {"SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"};

// ---------- weather (clock page companion) ----------
// Data comes from the bridge (GET /weather + /weather/name.raw); the bridge
// fetches Open-Meteo every 10 minutes. The clock page polls it every 60s
// while visible and degrades to "--" when the bridge has no weather (old
// bridge, offline, wired-only mode). The CJK city/condition text arrives as a
// bridge-rendered RGB565 strip, same trick as stock names / music titles.
const unsigned long WEATHER_POLL_INTERVAL_MS = 60000;

// Clock page v3, modeled on the reference product face (black, no hairlines):
// top-left city/condition strip + "最高33° 最低26°" strip, colored icon
// top-right; center: big white HH + blinking colon + orange MM + small
// seconds; "7月25日 周一" date strip; then data rows (glyph + rounded bar +
// value): temperature, humidity, agent 5H, agent WK; DeepSeek line at bottom.
const int WEATHER_NAME_W = 108, WEATHER_NAME_H = 16;
const int WEATHER_HILO_W = 108, WEATHER_HILO_H = 16;
const int DATE_STRIP_W = 120, DATE_STRIP_H = 16;
const int CITY_STRIP_X = 16, CITY_STRIP_Y = 8;
const int HILO_STRIP_X = 16, HILO_STRIP_Y = 28;
const int WEATHER_ICON_X = 196, WEATHER_ICON_Y = 6;
const int CLOCK_TIME_Y = 52;
const int DATE_STRIP_X = 16, DATE_STRIP_Y = 108;
const int ROW_LABEL_X = 10;
const int ROW_BAR_X = 34, ROW_BAR_W = 58, ROW_BAR_H = 9;
const int ROW_VAL_X = 96; // LEFT edge of every value (temp, humidity, DS balance)

// Corner pet on the clock page: the current app's sprite (custom upload or
// built-in) downscaled into the bottom-right box, floating over the
// wallpaper (pure-black pixels transparent). Left column keeps the data rows.
const int PET_BOX = 80;
const int PET_X = 240 - PET_BOX - 4;  // 156
const int PET_Y = 240 - PET_BOX;      // 160, flush with the bottom edge
int clockPetFrame = 0;
unsigned long lastClockPetMs = 0;


// ---------- desktop wallpaper background (clock page) ----------
// The bridge composites the Mac's current desktop wallpaper (aspect-fill,
// darkened for legibility) plus the CJK text lines into one
// 240x240 RGB565 bitmap, served as /clockbg.raw with bg_rev inside /weather
// (or pushed over serial as #BG frames when the wired link owns the path).
// Downloaded to LittleFS once per rev; every repaint then blits regions from
// that file instead of filling black. Off or unavailable -> plain black.
const char *CLOCKBG_FILE = "/bg.bin";
const char *WALLPAPER_CFG = "/wallpaper.cfg";
const size_t CLOCKBG_BYTES = 240 * 240 * 2;
bool wallpaperOn = true;     // user toggle (device web page)
bool wallpaperReady = false; // /bg.bin exists and is complete
int bgRev = -1;              // newest rev the bridge reported
int bgDrawnRev = -1;         // rev currently stored in /bg.bin
unsigned long lastBgTryMs = 0;
unsigned long lastBgNeedMs = 0; // wired-mode #NEED re-request pacing

void blitBg(int x, int y, int w, int h); // defined below, next to the bg file
bool wiredActive();       // defined below with the wired serial link section
extern int fileRxType;    // serial bulk file transfer in progress (0=none)

void loadWallpaperCfg() {
  wallpaperReady = false;
  if (LittleFS.exists(WALLPAPER_CFG)) {
    File f = LittleFS.open(WALLPAPER_CFG, "r");
    if (f) {
      wallpaperOn = f.readStringUntil('\n').toInt() != 0;
      bgDrawnRev = f.readStringUntil('\n').toInt();
      f.close();
    }
  }
  if (LittleFS.exists(CLOCKBG_FILE)) {
    File f = LittleFS.open(CLOCKBG_FILE, "r");
    if (f) {
      wallpaperReady = (size_t)f.size() == CLOCKBG_BYTES;
      f.close();
    }
  }
  if (!wallpaperReady) bgDrawnRev = -1; // refetch after any truncation
  Serial.printf("[wallpaper] on=%d ready=%d rev=%d\n", wallpaperOn, wallpaperReady, bgDrawnRev);
}

void saveWallpaperCfg() {
  File f = LittleFS.open(WALLPAPER_CFG, "w");
  if (!f) return;
  f.println(wallpaperOn ? 1 : 0);
  f.println(bgDrawnRev);
  f.close();
}

// Downloads the composited background into LittleFS: 115200 bytes, one
// screen row at a time (rowBuf is exactly 240*2 bytes).
bool downloadWallpaper() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) return false;
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + "/clockbg.raw";
  http.setTimeout(20000); // far longer than the 2s poll timeout: 115KB body
  if (!http.begin(client, url)) return false;
  int code = http.GET();
  if (code != HTTP_CODE_OK) {
    http.end();
    return false;
  }
  File f = LittleFS.open(CLOCKBG_FILE, "w");
  if (!f) {
    http.end();
    return false;
  }
  WiFiClient *stream = http.getStreamPtr();
  size_t total = 0;
  bool ok = true;
  while (total < CLOCKBG_BYTES) {
    size_t want = min((size_t)(240 * 2), CLOCKBG_BYTES - total);
    if (stream->readBytes((uint8_t *)rowBuf, want) != (int)want) {
      ok = false;
      break;
    }
    f.write((uint8_t *)rowBuf, want);
    total += want;
    yield();
  }
  f.close();
  http.end();
  if (!ok) LittleFS.remove(CLOCKBG_FILE);
  Serial.printf("[wallpaper] download %s (%u bytes)\n", ok ? "ok" : "FAILED", (unsigned)total);
  return ok;
}

// Fills a region from the composited background, or plain black when the
// wallpaper is off/unavailable. Drop-in replacement for fillRect(TFT_BLACK).
void blitBg(int x, int y, int w, int h) {
  if (wallpaperOn && wallpaperReady) {
    File f = LittleFS.open(CLOCKBG_FILE, "r");
    if (f) {
      bool ok = true;
      for (int r = 0; r < h; r++) {
        f.seek(((size_t)(y + r) * 240 + x) * 2);
        if (f.read((uint8_t *)rowBuf, (size_t)w * 2) != (int)((size_t)w * 2)) {
          ok = false;
          break;
        }
        tft.pushImage(x, y + r, w, 1, rowBuf);
        if ((r & 31) == 31) yield();
      }
      f.close();
      if (ok) return;
    }
  }
  tft.fillRect(x, y, w, h, TFT_BLACK);
}

// Draws one frame of the current app's pet animation scaled (nearest, any
// ratio) into the bottom-right corner box. Each screen row is COMPOSITED in
// RAM first — background row from the wallpaper, then the sprite's non-black
// pixels laid over it — and pushed exactly once. No bg-then-sprite two-pass,
// so the pet never flickers even at the 120ms walk-cycle cadence.
void drawClockPet(int app, int frameIdx) {
  bool custom = (app == APP_CLAUDE) ? claudeCustom : codexCustom;
  const char *file = (app == APP_CLAUDE) ? CLAUDE_SPRITE_FILE : CODEX_SPRITE_FILE;
  const uint16_t *const *frames = (app == APP_CLAUDE) ? claude_sprite_frames : codex_sprite_frames;
  int w = (app == APP_CLAUDE) ? CLAUDE_SPRITE_W : CODEX_SPRITE_W;
  int h = (app == APP_CLAUDE) ? CLAUDE_SPRITE_H : CODEX_SPRITE_H;
  size_t frameBytes = (app == APP_CLAUDE) ? CLAUDE_FRAME_BYTES : CODEX_FRAME_BYTES;
  int big = max(w, h);
  int outW = (int)(((long)w * PET_BOX) / big), outH = (int)(((long)h * PET_BOX) / big);
  int xRel = (PET_BOX - outW) / 2, yRel = (PET_BOX - outH) / 2;
  bool bgActive = wallpaperOn && wallpaperReady;

  File bgf, f;
  bool bgOk = false;
  if (bgActive) {
    bgf = LittleFS.open(CLOCKBG_FILE, "r");
    bgOk = (bool)bgf;
  }
  if (custom) {
    f = LittleFS.open(file, "r");
    if (!f) {
      if (bgf) bgf.close();
      return;
    }
  }
  for (int r = 0; r < PET_BOX; r++) {
    // 1) background row (or plain black when the wallpaper is off)
    if (bgOk) {
      bgf.seek(((size_t)(PET_Y + r) * 240 + PET_X) * 2);
      if (bgf.read((uint8_t *)rowBuf, PET_BOX * 2) != PET_BOX * 2) bgOk = false;
    }
    if (!bgOk) memset(rowBuf, 0, PET_BOX * 2);
    // 2) overlay the sprite row's non-black pixels
    int ry = r - yRel;
    if (ry >= 0 && ry < outH) {
      int sr = (int)(((long)ry * h) / outH); // nearest source row
      bool got;
      if (custom) {
        f.seek(1 + (size_t)frameIdx * frameBytes + (size_t)sr * w * 2);
        got = f.read((uint8_t *)prevRowBuf, (size_t)w * 2) == (int)((size_t)w * 2);
      } else {
        memcpy_P(prevRowBuf, frames[frameIdx] + (size_t)sr * w, (size_t)w * 2);
        got = true;
      }
      if (got) {
        for (int c = 0; c < outW; c++) {
          uint16_t v = prevRowBuf[(int)(((long)c * w) / outW)];
          if (v != 0x0000) rowBuf[xRel + c] = v; // black = transparent
        }
      }
    }
    tft.pushImage(PET_X, PET_Y + r, PET_BOX, 1, rowBuf);
  }
  if (bgf) bgf.close();
  if (custom) f.close();
}
const int ROW_TEMP_Y = 148, ROW_HUM_Y = 172;
const int DS_Y = 204; // single-line DeepSeek row: dot + DPS CNY + balance

bool weatherEverLoaded = false;
int weatherCode = -1; // WMO weather code from the bridge; -1 = no data
float weatherTempC = 0;
float weatherTMax = 0, weatherTMin = 0;
int weatherHumidity = -1;
int weatherNameRev = -1, weatherNameDrawnRev = -1;
int weatherHiloRev = -1, weatherHiloDrawnRev = -1;
int dateDrawnRev = -1; // local-date rev of the drawn date strip
unsigned long lastWeatherPollMs = 0;
// strip fetch retry pacing: an unreachable bridge must not stall the 2Hz tick
unsigned long lastNameTryMs = 0, lastHiloTryMs = 0, lastDateTryMs = 0;

// ---------- DeepSeek balance (clock page companion) ----------
// DeepSeek is pay-as-you-go, so the bridge reports the remaining account
// balance (GET /deepseek, or a serial #DEEPSEEK frame when wired). Refreshed
// every 5 minutes bridge-side; shown as one small line on the clock page.
bool dsEverLoaded = false;
bool dsAvailable = false;
float dsBalance = 0;
char dsCurrency[4] = "CNY";

// Shared parser for the /deepseek JSON, reached via HTTP poll or serial.
bool handleDeepSeekPayload(const String &json) {
  JsonDocument doc;
  if (deserializeJson(doc, json)) return false;
  dsEverLoaded = doc["ok"] | false;
  dsAvailable = doc["avail"] | false;
  dsBalance = doc["bal"] | 0.0f;
  strlcpy(dsCurrency, doc["cur"] | "CNY", sizeof(dsCurrency));
  return true;
}

void pollDeepSeek() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) return;
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + "/deepseek";
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);
  if (!http.begin(client, url)) return;
  int code = http.GET();
  if (code == HTTP_CODE_OK) handleDeepSeekPayload(http.getString());
  http.end();
}

int weatherIconIndex(int code) {
  if (code < 0) return 7;                          // unknown
  if (code <= 1) return 0;                         // clear / mainly clear
  if (code == 2) return 1;                         // partly cloudy
  if (code == 3) return 2;                         // overcast
  if (code == 45 || code == 48) return 3;          // fog
  if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) return 4; // rain
  if ((code >= 71 && code <= 77) || code == 85 || code == 86) return 5;   // snow
  if (code >= 95) return 6;                        // thunderstorm
  return 7;
}

void drawWeatherIcon(int idx) {
  const uint16_t *icon = weather_icons[idx];
  bool transparent = wallpaperOn && wallpaperReady; // black pixels float over wallpaper
  for (int r = 0; r < WEATHER_ICON_H; r++) {
    memcpy_P(rowBuf, icon + (size_t)r * WEATHER_ICON_W, WEATHER_ICON_W * 2);
    if (transparent) tft.pushImage(WEATHER_ICON_X, WEATHER_ICON_Y + r, WEATHER_ICON_W, 1, rowBuf, TFT_BLACK);
    else tft.pushImage(WEATHER_ICON_X, WEATHER_ICON_Y + r, WEATHER_ICON_W, 1, rowBuf);
  }
}

// Streams a bridge-rendered RGB565 strip (fixed size, no count byte) and
// blits it at (x, y) - used for the city, hi/lo and CJK date lines.
bool fetchStrip(const char *path, int x, int y, int w, int h) {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) return false;
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + path;
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);
  if (!http.begin(client, url)) return false;
  int code = http.GET();
  if (code != HTTP_CODE_OK) {
    http.end();
    return false;
  }
  WiFiClient *stream = http.getStreamPtr();
  const size_t rowBytes = (size_t)w * 2;
  bool ok = true;
  for (int r = 0; r < h; r++) {
    if (stream->readBytes((uint8_t *)rowBuf, rowBytes) != (int)rowBytes) {
      ok = false;
      break;
    }
    tft.pushImage(x, y + r, w, 1, rowBuf);
    yield();
  }
  http.end();
  return ok;
}

// Shared parser for the /weather JSON, reached via HTTP poll or a serial
// "#WEATHER " frame when the wired link owns the data path.
bool handleWeatherPayload(const String &json) {
  JsonDocument doc;
  if (deserializeJson(doc, json)) return false;
  weatherEverLoaded = doc["ok"] | false;
  weatherTempC = doc["temp"] | 0.0f;
  weatherCode = doc["code"] | -1;
  weatherHumidity = doc["humidity"] | -1;
  weatherTMax = doc["tmax"] | 0.0f;
  weatherTMin = doc["tmin"] | 0.0f;
  weatherNameRev = doc["name_rev"] | -1;
  weatherHiloRev = doc["hilo_rev"] | -1;
  bgRev = doc["bg_rev"] | -1;
  return true;
}

void pollWeather() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) return;
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + "/weather";
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);
  if (!http.begin(client, url)) return;
  int code = http.GET();
  if (code == HTTP_CODE_OK) handleWeatherPayload(http.getString());
  Serial.printf("[weather] GET -> %d ok=%d temp=%.1f code=%d hum=%d\n", code, weatherEverLoaded,
                weatherTempC, weatherCode, weatherHumidity);
  http.end();
}

// Usage level -> bar color: green while comfortable, amber past half,
// red past 80% (the pct is how much of the window is USED).
uint16_t quotaBarColor(float pct) {
  if (pct < 50) return TFT_GREEN;
  if (pct < 80) return TFT_YELLOW;
  return TFT_RED;
}

// Rounded data-row bar on a dark track; frac is 0..1, -1 = unknown (empty).
void drawRowBar(int y, float frac, uint16_t color) {
  tft.fillRoundRect(ROW_BAR_X, y + 3, ROW_BAR_W, ROW_BAR_H, 4, 0x2104);
  if (frac < 0) return;
  if (frac > 1) frac = 1;
  int fw = (int)lroundf(ROW_BAR_W * frac);
  if (fw >= 8) tft.fillRoundRect(ROW_BAR_X, y + 3, fw, ROW_BAR_H, 4, color);
  else if (fw > 0) tft.fillRect(ROW_BAR_X, y + 3, fw, ROW_BAR_H, color);
}

// 7x9 droplet glyph (humidity row).
void drawDroplet(int x, int y, uint16_t color) {
  tft.fillTriangle(x + 3, y, x, y + 5, x + 6, y + 5, color);
  tft.fillCircle(x + 3, y + 5, 3, color);
}

// 12x13 thermometer glyph (temperature row).
void drawThermoGlyph(int x, int y, uint16_t color) {
  tft.fillRoundRect(x + 4, y, 4, 8, 2, color); // stem
  tft.fillCircle(x + 6, y + 9, 4, color);      // bulb
}

// Repaint detectors for the data-driven zones.
int clockLastTempInt = -999, clockLastHumInt = -999;

void drawClockScreen(bool force) {
  if (!clockChromeDrawn) {
    if (wallpaperOn && wallpaperReady) blitBg(0, 0, 240, 240);
    else tft.fillScreen(TFT_BLACK);
    clockChromeDrawn = true;
    weatherNameDrawnRev = -1; // strip areas were wiped: re-fetch
    weatherHiloDrawnRev = -1;
    dateDrawnRev = -1;
    clockLastTempInt = -999;
    clockLastHumInt = -999;
    force = true;
  }

  // --- background: refresh the composited wallpaper when bg_rev bumps ---
  // (the CJK city/hi-lo/date lines are baked into that image, so when the
  // wallpaper is active the per-strip fetches below are skipped)
  unsigned long nowMs = millis();
  if (wallpaperOn && bgRev >= 0 && bgRev != bgDrawnRev && nowMs - lastBgTryMs >= 30000UL &&
      !wiredActive() && !fileRxType) { // wired: the serial #BG push owns this path
    lastBgTryMs = nowMs;
    if (downloadWallpaper()) {
      bgDrawnRev = bgRev;
      wallpaperReady = true;
      saveWallpaperCfg();
      clockChromeDrawn = false; // next tick repaints over the fresh background
      return;
    }
  }
  // Wired mode and out of sync (a push failed or the bridge restarted): ask
  // the bridge for a re-push, paced to once a minute.
  if (wallpaperOn && bgRev >= 0 && bgRev != bgDrawnRev && wiredActive() && !fileRxType &&
      nowMs - lastBgNeedMs >= 60000UL) {
    lastBgNeedMs = nowMs;
    Serial.println("#NEED");
  }
  bool bgActive = wallpaperOn && wallpaperReady;

  // --- center time: white HH + blinking colon + orange MM + small seconds ---
  int tmYdayRev = -1;
  char hh[3] = "--", mm[3] = "--", ss[3] = "--";
  if (clockTimeValid()) {
    struct tm tmNow;
    time_t now = time(nullptr);
    localtime_r(&now, &tmNow);
    tmYdayRev = tmNow.tm_year * 400 + tmNow.tm_yday;
    snprintf(hh, sizeof(hh), "%02d", tmNow.tm_hour);
    snprintf(mm, sizeof(mm), "%02d", tmNow.tm_min);
    snprintf(ss, sizeof(ss), "%02d", tmNow.tm_sec);
  }
  {
    // Per-glyph repaint: only the digits that actually changed get their
    // little background patch re-blitted and redrawn. The 1Hz seconds/colon
    // touch ~30px instead of the whole row, so nothing visibly flashes.
    int wHH = tft.textWidth("22", 7);
    int wColon = tft.textWidth(":", 7);
    int wSS = tft.textWidth("22", 2);
    const int gap = 6;
    int total = wHH + wColon + wHH + gap + wSS;
    int x = (240 - total) / 2;
    int xColon = x + wHH, xMM = xColon + wColon, xSS = xMM + wHH + gap;
    static char lastHH[3] = "", lastMM[3] = "", lastSS[3] = "";
    static bool lastColon = false;
    if (force) { lastHH[0] = lastMM[0] = lastSS[0] = 0; lastColon = !clockColonOn; }
    tft.setTextDatum(TL_DATUM);
    if (strcmp(hh, lastHH) != 0) {
      strcpy(lastHH, hh);
      blitBg(x - 2, CLOCK_TIME_Y - 4, wHH + 4, 56);
      tft.setTextColor(TFT_WHITE);
      tft.drawString(hh, x, CLOCK_TIME_Y, 7);
    }
    if (clockColonOn != lastColon) {
      lastColon = clockColonOn;
      blitBg(xColon, CLOCK_TIME_Y - 4, wColon, 56);
      if (clockColonOn) {
        tft.setTextColor(TFT_WHITE);
        tft.drawString(":", xColon, CLOCK_TIME_Y, 7);
      }
    }
    if (strcmp(mm, lastMM) != 0) {
      strcpy(lastMM, mm);
      blitBg(xMM, CLOCK_TIME_Y - 4, wHH + 2, 56);
      tft.setTextColor(TFT_ORANGE);
      tft.drawString(mm, xMM, CLOCK_TIME_Y, 7);
    }
    if (strcmp(ss, lastSS) != 0) {
      strcpy(lastSS, ss);
      blitBg(xSS, CLOCK_TIME_Y + 28, wSS + 2, 24);
      tft.setTextColor(TFT_WHITE);
      tft.drawString(ss, xSS, CLOCK_TIME_Y + 32, 2);
    }
  }

  // --- top-right icon slot: custom animation wins, else the weather icon ---
  static int weatherDrawnIcon = -1;
  static bool slotWasAnim = false;
  if (force) {
    weatherDrawnIcon = -1;
    slotWasAnim = false;
  }
  {
    int wantIcon = weatherEverLoaded ? weatherIconIndex(weatherCode) : 7;
    if (wantIcon != weatherDrawnIcon || slotWasAnim) {
      slotWasAnim = false;
      weatherDrawnIcon = wantIcon;
      blitBg(WEATHER_ICON_X - 4, WEATHER_ICON_Y - 4, 40, 40); // no chip: blend into the bg
      drawWeatherIcon(wantIcon);
    }
  }

  // --- CJK strips: only when the wallpaper background is OFF (when it's
  // on, those lines are baked into the composited background image). Wired
  // mode: strips arrive as #STRIP serial pushes instead of HTTP fetches. ---
  if (!bgActive && !wiredActive() && weatherEverLoaded && weatherNameRev >= 0 &&
      weatherNameDrawnRev != weatherNameRev && nowMs - lastNameTryMs >= 30000UL) {
    lastNameTryMs = nowMs;
    if (fetchStrip("/weather/name.raw", CITY_STRIP_X, CITY_STRIP_Y, WEATHER_NAME_W, WEATHER_NAME_H))
      weatherNameDrawnRev = weatherNameRev;
  }
  if (!bgActive && !wiredActive() && weatherEverLoaded && weatherHiloRev >= 0 &&
      weatherHiloDrawnRev != weatherHiloRev && nowMs - lastHiloTryMs >= 30000UL) {
    lastHiloTryMs = nowMs;
    if (fetchStrip("/weather/hilo.raw", HILO_STRIP_X, HILO_STRIP_Y, WEATHER_HILO_W, WEATHER_HILO_H))
      weatherHiloDrawnRev = weatherHiloRev;
  }
  if (!bgActive && !wiredActive() && tmYdayRev >= 0 && tmYdayRev != dateDrawnRev &&
      nowMs - lastDateTryMs >= 30000UL) {
    lastDateTryMs = nowMs;
    if (fetchStrip("/date.raw", DATE_STRIP_X, DATE_STRIP_Y, DATE_STRIP_W, DATE_STRIP_H))
      dateDrawnRev = tmYdayRev;
  }

  // --- temperature row: thermo glyph + bar (-10..40C) + value (values are
  // LEFT-aligned at ROW_VAL_X = 96, one shared numbers column) ---
  int tInt = weatherEverLoaded ? (int)lroundf(weatherTempC) : -999;
  if (force || tInt != clockLastTempInt) {
    clockLastTempInt = tInt;
    blitBg(0, ROW_TEMP_Y, PET_X, 20);
    drawThermoGlyph(ROW_LABEL_X, ROW_TEMP_Y + 2, TFT_RED);
    drawRowBar(ROW_TEMP_Y, tInt == -999 ? -1 : (weatherTempC + 10.0f) / 50.0f, TFT_RED);
    tft.setTextDatum(TL_DATUM);
    tft.setTextColor(TFT_WHITE);
    if (tInt == -999) {
      tft.drawString("--", ROW_VAL_X, ROW_TEMP_Y, 2);
    } else {
      String t = String(tInt);
      tft.drawString(t, ROW_VAL_X, ROW_TEMP_Y, 2);
      tft.drawCircle(ROW_VAL_X + tft.textWidth(t, 2) + 3, ROW_TEMP_Y + 3, 2, TFT_WHITE); // degree dot
    }
  }

  // --- humidity row: droplet glyph + bar (0..100%) + value ---
  int hInt = weatherEverLoaded ? weatherHumidity : -1;
  if (force || hInt != clockLastHumInt) {
    clockLastHumInt = hInt;
    blitBg(0, ROW_HUM_Y, PET_X, 20);
    drawDroplet(ROW_LABEL_X + 2, ROW_HUM_Y + 4, TFT_GREEN);
    drawRowBar(ROW_HUM_Y, hInt >= 0 ? hInt / 100.0f : -1, TFT_GREEN);
    tft.setTextDatum(TL_DATUM);
    tft.setTextColor(TFT_WHITE);
    tft.drawString(hInt >= 0 ? String(hInt) + "%" : "--", ROW_VAL_X, ROW_HUM_Y, 2);
  }

  // --- DeepSeek single line: dot in the glyph column, "DPS" (16px) + "CNY"
  // (small suffix) left-aligned to the BAR column (34), balance LEFT-aligned
  // to the shared numbers column (ROW_VAL_X = 96), same 16px font.
  String dsVal = dsEverLoaded ? String(dsBalance, 2) : "--";
  uint16_t dotColor = !dsEverLoaded ? 0x4208 : (dsAvailable ? TFT_GREEN : TFT_RED);
  static String lastDsLabel = "\x01", lastDsVal = "\x01";
  static uint16_t lastDotColor = 0xFFFF;
  String dsLabel = "DPS " + String(dsCurrency);
  if (force || dsLabel != lastDsLabel || dsVal != lastDsVal || dotColor != lastDotColor) {
    lastDsLabel = dsLabel;
    lastDsVal = dsVal;
    lastDotColor = dotColor;
    blitBg(0, DS_Y - 2, PET_X, 20);
    tft.fillCircle(14, DS_Y + 8, 4, dotColor);
    tft.setTextDatum(TL_DATUM);
    if (bgActive) tft.setTextColor(0x9DF3); else tft.setTextColor(0x9DF3, TFT_BLACK);
    tft.drawString("DPS", ROW_BAR_X, DS_Y, 2);
    tft.drawString(dsCurrency, ROW_BAR_X + tft.textWidth("DPS", 2) + 5, DS_Y + 8, 1);
    tft.setTextColor(TFT_WHITE);
    tft.drawString(dsVal, ROW_VAL_X, DS_Y, 2);
  }

  // --- corner pet: the app currently "on duty", scaled into the big
  // bottom-right box. loop() advances clockPetFrame at the pet-page cadence.
  static int petDrawnApp = -1;
  if (force || petDrawnApp != (int)currentApp) {
    petDrawnApp = (int)currentApp;
    clockPetFrame = 0;
    drawClockPet(currentApp, clockPetFrame);
  }
}

void clockTick() {
  clockColonOn = !clockColonOn; // 1Hz blink; minute rollover caught by text compare
  drawClockScreen(false);
}

// ---------- WiFi / bridge polling ----------

WiFiManager wifiManager; // global: the config portal now runs non-blocking in loop()

void configModeCallback(WiFiManager *wm) {
  tft.fillScreen(TFT_BLACK);
  tft.setTextDatum(TL_DATUM);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  tft.drawString("WiFi setup needed", 8, 32, 2);
  tft.drawString("Connect phone to AP:", 8, 62, 2);
  tft.setTextColor(TFT_YELLOW, TFT_BLACK);
  tft.drawString(WIFI_PORTAL_AP_NAME, 8, 87, 2);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  tft.drawString("then open 192.168.4.1", 8, 117, 2);
  tft.setTextColor(TFT_CYAN, TFT_BLACK);
  tft.drawString("Or: plug into the computer", 8, 155, 2);
  tft.drawString("via USB - no WiFi needed", 8, 178, 2);
  tft.setTextColor(TFT_DARKGREY, TFT_BLACK);
  tft.drawString("Firmware v" FW_VERSION, 8, 215, 2);
}

// Non-blocking: with saved credentials this still waits ~10s for the join,
// but a missing/failed WiFi no longer traps boot in the portal - the portal
// keeps running from loop() while the USB serial link can take over the
// screen (wired mode for APs with client isolation).
void setupWiFi() {
  wifiManager.setAPCallback(configModeCallback);
  wifiManager.setConfigPortalBlocking(false);

  tft.fillScreen(TFT_BLACK);
  tft.setTextDatum(TL_DATUM);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  tft.drawString("Connecting WiFi...", 8, 100, 2);

  Serial.println("[wifi] starting WiFiManager autoConnect (non-blocking portal)...");
  bool ok = wifiManager.autoConnect(WIFI_PORTAL_AP_NAME);
  Serial.printf("[wifi] autoConnect result=%d ssid=%s ip=%s\n", ok, WiFi.SSID().c_str(),
                WiFi.localIP().toString().c_str());
  Serial.printf("[wifi] bridge host = '%s'\n", bridgeHost.c_str());
}

bool parseStatusJson(const String &payload) {
  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, payload);
  if (err) return false;

  JsonObject c = doc["claude"];
  if (!c.isNull()) {
    claudeStatus.status = c["status"] | "unknown";
    claudeStatus.tokensToday = c["tokens_today"] | 0;
    claudeStatus.sessionMin = c["session_min"] | 0;
    claudeStatus.sessionWindowMin = c["session_window_min"] | 300;
    claudeStatus.fiveHourPct = c["five_hour_pct"] | -1.0;
    claudeStatus.fiveHourResetMin = c["five_hour_reset_min"] | -1;
    claudeStatus.sevenDayPct = c["seven_day_pct"] | -1.0;
    claudeStatus.sevenDayResetMin = c["seven_day_reset_min"] | -1;
    claudeStatus.needsInput = c["needs_input"] | false;
  }

  JsonObject x = doc["codex"];
  if (!x.isNull()) {
    codexStatus.status = x["status"] | "unknown";
    codexStatus.tokensToday = x["tokens_today"] | 0;
    codexStatus.primaryPct = x["primary_pct"] | -1.0;
    codexStatus.primaryResetMin = x["primary_reset_min"] | -1;
    codexStatus.weeklyPct = x["weekly_pct"] | -1.0;
    codexStatus.weeklyResetMin = x["weekly_reset_min"] | -1;
    codexStatus.needsInput = x["needs_input"] | false;
  }
  statusMusicPlaying = doc["music_playing"] | false;
  long epoch = doc["epoch"] | 0L; // bridge wall clock (wired mode has no SNTP)
  if (epoch > 0) setClockFromEpoch(epoch);
  return true;
}

// The mode actually rendered. In AUTO: a pending approval prompt wins (stay on
// the pet so its border can flash red at you), otherwise audio promotes to the
// music page.
DisplayMode effectiveMode() {
  if (displayMode == MODE_AUTO) {
    if (claudeStatus.needsInput || codexStatus.needsInput) return MODE_AUTO;
    // music page needs HTTP for cover/text bitmaps, so don't auto-promote
    // when running wired-only (no WiFi)
    if (statusMusicPlaying && WiFi.status() == WL_CONNECTED) return MODE_MUSIC;
  }
  // MODE_CLOCK with active work: auto-promote to pet page so the user sees
  // Claude/Codex working status. Falls back to clock when idle.
  if (displayMode == MODE_CLOCK) {
    bool claudeWorking = claudeStatus.status == "working";
    bool codexWorking = codexStatus.status == "working";
    if (claudeWorking || codexWorking || claudeStatus.needsInput || codexStatus.needsInput)
      return MODE_AUTO; // pet page: show the working agent
    if (statusMusicPlaying && WiFi.status() == WL_CONNECTED) return MODE_MUSIC;
  }
  return displayMode;
}

void pollBridge() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) {
    Serial.printf("[bridge] skip poll: wifi=%d host='%s'\n", WiFi.status() == WL_CONNECTED, bridgeHost.c_str());
    return;
  }

  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + BRIDGE_DEFAULT_PATH;
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);

  if (!http.begin(client, url)) {
    Serial.println("[bridge] http.begin() failed");
    return;
  }
  int code = http.GET();
  Serial.printf("[bridge] GET %s -> %d\n", url.c_str(), code);
  if (code == HTTP_CODE_OK) {
    String payload = http.getString();
    if (parseStatusJson(payload)) {
      lastSuccessMs = millis();
      everPolled = true;
      Serial.printf("[bridge] claude=%s tok=%ld | codex=%s tok=%ld primary=%.0f%%\n",
                    claudeStatus.status.c_str(), claudeStatus.tokensToday,
                    codexStatus.status.c_str(), codexStatus.tokensToday, codexStatus.primaryPct);
    } else {
      Serial.println("[bridge] JSON parse failed");
    }
  } else {
    claudeStatus.status = "offline";
    codexStatus.status = "offline";
  }
  http.end();
  DisplayMode eff = effectiveMode();
  if (eff != MODE_NET && eff != MODE_MUSIC && eff != MODE_STOCK && eff != MODE_CLOCK) {
    // Only a real app switch clears the screen; a plain data refresh paints
    // in place so the poll doesn't flash the whole display.
    if (updateActiveApp()) drawActiveApp();
    else refreshActiveApp();
  }
}

// ---------- wired (USB serial) bridge link ----------
// Fallback for WiFi networks with client isolation (device can't reach the
// bridge over LAN) - or for skipping WiFi setup entirely: when the clock is
// plugged into the computer over USB, the bridge pushes the same /status and
// /net payloads down the CH340 serial line as newline-terminated frames:
//   bridge -> device:  #HELLO   #STATUS {json}   #NET {json}   #CMD {json}
//   device -> bridge:  #DEVICE {"name":"aiclock","fw":"x.y.z"}
// Everything else the device prints (logs) is ignored by the bridge.
unsigned long lastSerialFrameMs = 0;
bool wiredEverLinked = false;
char serialLine[1600]; // biggest frame is #STATUS at ~600 bytes
size_t serialLineLen = 0;

bool wiredActive() { return wiredEverLinked && (millis() - lastSerialFrameMs) < 15000UL; }

// ----- wired bulk push: wallpaper + CJK strips + music art over serial -----
// Frames: "#BG <rev> <b64len>", "#STRIP <id> <rev> <b64len>" (0=city 1=hi/lo
// 2=date), "#COVER <rev> <b64len>" or "#MTEXT <rev> <b64len>" header, then
// "#C <base64>" chunk lines (each a multiple of 4 chars), then "#E". Big
// payloads stream into LittleFS staging files and replace the target only
// after the full transfer lands; small strips land in a RAM buffer and are
// blitted when complete. This gives wired-only devices (no WiFi at all) the
// full clock + music pages.
File bgRxFile;
int fileRxType = 0; // 0=none 1=wallpaper 2=music cover 3=music text strip
int bgRxRev = -1;
size_t bgRxBytes = 0;
const char *CLOCKBG_TMP = "/bg.tmp"; // staged until the full transfer lands
int stripRxId = -1; // 0=name 1=hilo 2=date
int stripRxRev = -1;
uint8_t stripRxBuf[DATE_STRIP_W * DATE_STRIP_H * 2]; // largest strip
size_t stripRxBytes = 0;

// Begins a file-target bulk transfer (wallpaper / cover / music text).
void startFileRx(int type, const char *tmpPath, int rev) {
  if (fileRxType) bgRxFile.close();
  stripRxId = -1; // one transfer at a time
  bgRxFile = LittleFS.open(tmpPath, "w");
  fileRxType = bgRxFile ? type : 0;
  bgRxRev = rev;
  bgRxBytes = 0;
}

int b64Val(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}

// Decodes one chunk (length a multiple of 4, '=' padding only at the very
// end of the stream) into out; returns the decoded byte count.
size_t b64Decode(const char *in, size_t n, uint8_t *out) {
  size_t o = 0;
  for (size_t i = 0; i + 4 <= n; i += 4) {
    int v0 = b64Val(in[i]), v1 = b64Val(in[i + 1]);
    int v2 = in[i + 2] == '=' ? -1 : b64Val(in[i + 2]);
    int v3 = in[i + 3] == '=' ? -1 : b64Val(in[i + 3]);
    if (v0 < 0 || v1 < 0) break;
    uint32_t t = ((uint32_t)v0 << 18) | ((uint32_t)v1 << 12) |
                 ((uint32_t)(v2 < 0 ? 0 : v2) << 6) | (uint32_t)(v3 < 0 ? 0 : v3);
    out[o++] = (t >> 16) & 0xFF;
    if (v2 >= 0) out[o++] = (t >> 8) & 0xFF;
    if (v3 >= 0) out[o++] = t & 0xFF;
  }
  return o;
}

void handleBulkChunk(char *b64) {
  size_t n = strlen(b64);
  uint8_t dec[724];
  size_t dn = b64Decode(b64, n, dec);
  if (fileRxType) {
    bgRxFile.write(dec, dn);
    bgRxBytes += dn;
  } else if (stripRxId >= 0) {
    if (stripRxBytes + dn <= sizeof(stripRxBuf)) {
      memcpy(stripRxBuf + stripRxBytes, dec, dn);
      stripRxBytes += dn;
    }
  }
}

// Blits a LittleFS-held RGB565 image (cover art / music text strip); false
// when the file is missing or truncated, so the caller can fall back.
bool blitMusicFile(const char *path, int x, int y, int w, int h) {
  File f = LittleFS.open(path, "r");
  if (!f) return false;
  if ((size_t)f.size() != (size_t)w * h * 2) {
    f.close();
    return false;
  }
  for (int r = 0; r < h; r++) {
    f.read((uint8_t *)rowBuf, (size_t)w * 2);
    tft.pushImage(x, y + r, w, 1, rowBuf);
  }
  f.close();
  return true;
}

void drawMusicScreenWired(); // defined next to drawMusicScreen

void handleBulkEnd() {
  if (fileRxType) {
    int type = fileRxType;
    fileRxType = 0;
    bgRxFile.close();
    const char *tmp = type == 1 ? CLOCKBG_TMP : type == 2 ? COVER_TMP : MTEXT_TMP;
    const char *final = type == 1 ? CLOCKBG_FILE : type == 2 ? COVER_FILE : MTEXT_FILE;
    size_t expect = type == 1 ? CLOCKBG_BYTES : type == 2 ? MUSIC_COVER_BYTES : MUSIC_TEXT_BYTES;
    if (bgRxBytes == expect) {
      LittleFS.remove(final);
      LittleFS.rename(tmp, final);
      if (type == 1) {
        bgDrawnRev = bgRxRev;
        wallpaperReady = true;
        saveWallpaperCfg();
        clockChromeDrawn = false; // full repaint over the new background
        Serial.printf("[wallpaper] serial push ok rev=%d\n", bgRxRev);
      } else if (type == 2) {
        coverFileRev = bgRxRev;
        musicCoverDirty = true;
        Serial.printf("[music] cover push ok rev=%d\n", bgRxRev);
        if (effectiveMode() == MODE_MUSIC) drawMusicScreenWired();
      } else {
        mtextFileRev = bgRxRev;
        musicTextDirty = true;
        Serial.printf("[music] text push ok rev=%d\n", bgRxRev);
        if (effectiveMode() == MODE_MUSIC) drawMusicScreenWired();
      }
    } else {
      LittleFS.remove(tmp); // old file (if any) survives a bad push
      Serial.printf("[bulk] serial push BAD type=%d size %u\n", type, (unsigned)bgRxBytes);
    }
    return;
  }
  if (stripRxId < 0) return;
  int id = stripRxId;
  stripRxId = -1;
  int w = id == 2 ? DATE_STRIP_W : WEATHER_NAME_W;
  int h = id == 2 ? DATE_STRIP_H : WEATHER_NAME_H;
  int x = id == 0 ? CITY_STRIP_X : id == 1 ? HILO_STRIP_X : DATE_STRIP_X;
  int y = id == 0 ? CITY_STRIP_Y : id == 1 ? HILO_STRIP_Y : DATE_STRIP_Y;
  if (stripRxBytes != (size_t)w * h * 2) {
    Serial.printf("[strip] serial push BAD id=%d size %u\n", id, (unsigned)stripRxBytes);
    return;
  }
  if (id == 0) weatherNameDrawnRev = stripRxRev;
  else if (id == 1) weatherHiloDrawnRev = stripRxRev;
  else dateDrawnRev = stripRxRev;
  // Draw now only when the clock page is up without the wallpaper (with the
  // wallpaper on, these lines are baked into it; the drawn-rev bump above
  // still stops the HTTP fallback from re-fetching).
  if (effectiveMode() == MODE_CLOCK && !(wallpaperOn && wallpaperReady)) {
    for (int r = 0; r < h; r++) {
      memcpy(rowBuf, stripRxBuf + (size_t)r * w * 2, (size_t)w * 2);
      tft.pushImage(x, y + r, w, 1, rowBuf);
    }
  }
}

// First data over either transport replaces the boot/portal screen.
void showMainUiIfNeeded() {
  if (mainUiShown) return;
  mainUiShown = true;
  drawStaticChrome();
  updateActiveApp();
  drawActiveApp();
}

void handleSerialFrame(char *line) {
  lastSerialFrameMs = millis();
  wiredEverLinked = true;
  if (!strncmp(line, "#HELLO", 6)) {
    Serial.printf("#DEVICE {\"name\":\"aiclock\",\"fw\":\"%s\"}\n", FW_VERSION);
    return;
  }
  if (!strncmp(line, "#STATUS ", 8)) {
    if (parseStatusJson(String(line + 8))) {
      lastSuccessMs = millis();
      everPolled = true;
      showMainUiIfNeeded();
      DisplayMode eff = effectiveMode();
      if (eff != MODE_NET && eff != MODE_MUSIC && eff != MODE_STOCK && eff != MODE_CLOCK) {
        if (updateActiveApp()) drawActiveApp();
        else refreshActiveApp();
      }
    }
    return;
  }
  if (!strncmp(line, "#NET ", 5)) {
    handleNetPayload(String(line + 5));
    return;
  }
  if (!strncmp(line, "#STOCK ", 7)) {
    handleStockPayload(String(line + 7));
    return;
  }
  if (!strncmp(line, "#WEATHER ", 9)) {
    // Wired mode owns the data path: weather arrives over serial instead of
    // HTTP. The CJK strips + wallpaper follow as #STRIP/#BG bulk pushes.
    if (handleWeatherPayload(String(line + 9))) {
      Serial.printf("[weather] serial ok=%d temp=%.1f code=%d hum=%d\n", weatherEverLoaded,
                    weatherTempC, weatherCode, weatherHumidity);
    }
    return;
  }
  if (!strncmp(line, "#BG ", 4)) {
    int rev;
    long len;
    if (sscanf(line + 4, "%d %ld", &rev, &len) == 2 && len > 0)
      startFileRx(1, CLOCKBG_TMP, rev);
    return;
  }
  if (!strncmp(line, "#COVER ", 7)) {
    int rev;
    long len;
    if (sscanf(line + 7, "%d %ld", &rev, &len) == 2 && len > 0)
      startFileRx(2, COVER_TMP, rev);
    return;
  }
  if (!strncmp(line, "#MTEXT ", 7)) {
    int rev;
    long len;
    if (sscanf(line + 7, "%d %ld", &rev, &len) == 2 && len > 0)
      startFileRx(3, MTEXT_TMP, rev);
    return;
  }
  if (!strncmp(line, "#STRIP ", 7)) {
    int id, rev;
    long len;
    if (sscanf(line + 7, "%d %d %ld", &id, &rev, &len) == 3 && id >= 0 && id <= 2 && len > 0 &&
        !fileRxType) {
      stripRxId = id;
      stripRxRev = rev;
      stripRxBytes = 0;
    }
    return;
  }
  if (!strncmp(line, "#MUSIC ", 7)) {
    bool cc = false, tc = false;
    if (applyMusicJson(String(line + 7), &cc, &tc)) {
      musicCoverDirty |= cc;
      musicTextDirty |= tc;
      if (effectiveMode() == MODE_MUSIC) drawMusicScreenWired();
    }
    return;
  }
  if (!strncmp(line, "#C ", 3)) {
    handleBulkChunk(line + 3);
    return;
  }
  if (!strcmp(line, "#E")) {
    handleBulkEnd();
    return;
  }
  if (!strncmp(line, "#DEEPSEEK ", 10)) {
    if (handleDeepSeekPayload(String(line + 10))) {
      Serial.printf("[deepseek] serial ok=%d bal=%.2f %s avail=%d\n", dsEverLoaded, dsBalance,
                    dsCurrency, dsAvailable);
    }
    return;
  }
  if (!strncmp(line, "#CMD ", 5)) {
    JsonDocument doc;
    if (deserializeJson(doc, line + 5)) return;
    if (doc["brightness"].is<int>()) {
      brightness = constrain(doc["brightness"].as<int>(), 0, 100);
      applyBrightness();
      saveBrightness();
    }
    const char *mode = doc["display"] | (const char *)nullptr;
    if (mode) {
      String m(mode);
      if (m == "auto") displayMode = MODE_AUTO;
      else if (m == "claude") displayMode = MODE_CLAUDE;
      else if (m == "codex") displayMode = MODE_CODEX;
      else if (m == "net") displayMode = MODE_NET;
      else if (m == "music") displayMode = MODE_MUSIC;
      else if (m == "stock") displayMode = MODE_STOCK;
      else if (m == "clock") displayMode = MODE_CLOCK;
      // the effectiveMode transition handler in loop() repaints the chrome
    }
    return;
  }
}

// Drains the UART, splitting on newlines; frames start with '#', everything
// else (line noise, echoes) is dropped.
void pumpSerial() {
  while (Serial.available()) {
    char ch = (char)Serial.read();
    if (ch == '\n' || ch == '\r') {
      if (serialLineLen > 0 && serialLine[0] == '#') {
        serialLine[serialLineLen] = 0;
        handleSerialFrame(serialLine);
      }
      serialLineLen = 0;
    } else if (serialLineLen < sizeof(serialLine) - 1) {
      serialLine[serialLineLen++] = ch;
    } else {
      serialLineLen = 0; // oversized line: drop it
    }
  }
}

// ---------- web admin ----------

String htmlEscape(const String &s) {
  String out = s;
  out.replace("&", "&amp;");
  out.replace("<", "&lt;");
  out.replace(">", "&gt;");
  out.replace("\"", "&quot;");
  return out;
}

void handleRoot() {
  String age = everPolled ? String((millis() - lastSuccessMs) / 1000) + "s ago" : "never";
  String html;
  html.reserve(3072);
  html += "<!DOCTYPE html><html><head><meta charset='utf-8'>";
  html += "<meta name='viewport' content='width=device-width, initial-scale=1'>";
  html += "<title>AI Clock 设置</title>";
  html += "<style>body{font-family:-apple-system,sans-serif;max-width:480px;margin:24px "
          "auto;padding:0 16px;color:#222} h1{font-size:20px} label{display:block;margin-top:16px;font-weight:600}"
          "input{width:100%;box-sizing:border-box;padding:8px;font-size:16px;margin-top:4px}"
          "button{margin-top:16px;padding:10px 20px;font-size:16px;background:#2563eb;color:#fff;"
          "border:none;border-radius:6px}"
          "table{margin-top:20px;border-collapse:collapse;width:100%}"
          "td{padding:4px 8px;border-bottom:1px solid #eee;font-size:14px}"
          ".dot{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:6px}"
          "</style></head><body>";
  html += "<h1>AI Clock 设置</h1>";

  html += "<form method='POST' action='/save'>";
  html += "<label>Bridge host (ip:port)</label>";
  html += "<input name='bridge' value='" + htmlEscape(bridgeHost) + "' placeholder='192.168.1.181:8765'>";
  html += "<button type='submit'>保存</button>";
  html += "</form>";

  // Backlight brightness slider: applies live on release (PWM, persisted).
  html += "<h2 style='font-size:16px;margin-top:28px'>屏幕亮度</h2>";
  html += "<input type='range' min='0' max='100' value='" + String(brightness) + "' id='bri' "
          "oninput=\"document.getElementById('briv').textContent=this.value+'%'\" "
          "onchange=\"fetch('/api/brightness',{method:'POST',headers:{'Content-Type':"
          "'application/x-www-form-urlencoded'},body:'level='+this.value})\">";
  html += "<div style='font-size:13px;color:#555'>当前：<span id='briv'>" + String(brightness) +
          "%</span>（0 = 熄屏，设置立即生效并记住）</div>";

  // Quick display-mode switch: pet page (auto) vs the new clock page. Uses the
  // same /api/display endpoint the Mac/Windows tray apps call.
  html += "<h2 style='font-size:16px;margin-top:28px'>屏幕显示</h2>";
  html += "<button onclick=\"fetch('/api/display',{method:'POST',headers:{'Content-Type':"
          "'application/x-www-form-urlencoded'},body:'mode=auto'})\">桌宠页（自动）</button> ";
  html += "<button onclick=\"fetch('/api/display',{method:'POST',headers:{'Content-Type':"
          "'application/x-www-form-urlencoded'},body:'mode=clock'})\" "
          "style='background:#059669'>时钟页</button>";

  // Desktop-wallpaper background for the clock page (Mac bridge renders it).
  html += "<h2 style='font-size:16px;margin-top:28px'>桌面壁纸背景</h2>";
  html += "<p style='font-size:13px;color:#555'>时钟页用 Mac 当前桌面壁纸做背景（自动变暗保证文字清晰，"
          "壁纸更换会自动同步）。需要 Mac 桥接程序在线（WiFi 或 USB 串口均可）。</p>";
  html += "<button onclick=\"fetch('/api/wallpaper',{method:'POST',headers:{'Content-Type':"
          "'application/x-www-form-urlencoded'},body:'on=" + String(wallpaperOn ? 0 : 1) +
          "'}).then(()=>location.reload())\" style='background:" +
          String(wallpaperOn ? "#6b7280" : "#059669") + "'>" +
          String(wallpaperOn ? "关闭壁纸背景" : "开启壁纸背景") + "</button>";

  // On-device GIF upload: replaces a character's animation without reflashing.
  html += "<h2 style='font-size:16px;margin-top:28px'>桌宠动画（上传 GIF）</h2>";
  html += "<p style='font-size:13px;color:#555'>上传一个 .gif，设备会在板上解码并缩放到对应角色的尺寸，"
          "立刻替换动画，无需重新编译或烧录。GIF 太大可能因内存不足解码失败，换小一点的即可。</p>";
  html += "<form id='gifForm' method='POST' enctype='multipart/form-data' onsubmit='return setGifAction()'>";
  html += "<label>角色</label>";
  html += "<select id='gifTarget'><option value='claude'>Claude</option><option value='codex'>Codex</option></select>";
  html += "<label>GIF 文件</label><input type='file' name='file' accept='.gif' required>";
  html += "<button type='submit'>上传并应用</button>";
  html += "</form>";
  html += "<script>function setGifAction(){"
          "document.getElementById('gifForm').action='/sprite/'+document.getElementById('gifTarget').value;"
          "return true;}</script>";

  html += "<table>";
  html += "<tr><td>WiFi SSID</td><td>" + htmlEscape(WiFi.SSID()) + "</td></tr>";
  html += "<tr><td>设备 IP</td><td>" + WiFi.localIP().toString() + "</td></tr>";
  html += "<tr><td>上次桥接更新</td><td>" + age + "</td></tr>";
  html += "<tr><td>Claude</td><td>" + htmlEscape(claudeStatus.status) + ", " +
          formatTokens(claudeStatus.tokensToday) + " tok</td></tr>";
  html += "<tr><td>Codex</td><td>" + htmlEscape(codexStatus.status) + ", " +
          formatTokens(codexStatus.tokensToday) + " tok, " +
          (codexStatus.primaryPct >= 0 ? "5h " + String(codexStatus.primaryPct, 0) + "%"
           : codexStatus.weeklyPct >= 0 ? "Wk " + String(codexStatus.weeklyPct, 0) + "%"
                                        : "5h ?") + "</td></tr>";
  html += "</table>";

  html += "<form method='POST' action='/reset-wifi' onsubmit=\"return confirm('清除 WiFi "
          "设置并重启？设备会开启配网热点。');\">";
  html += "<button type='submit' style='background:#dc2626'>重置 WiFi</button>";
  html += "</form>";

  html += "</body></html>";
  webServer.send(200, "text/html", html);
}

void handleSave() {
  String newHost = webServer.arg("bridge");
  newHost.trim();
  bridgeHost = newHost;
  saveBridgeHost(bridgeHost);
  Serial.printf("[web] bridge host updated to '%s'\n", bridgeHost.c_str());
  webServer.sendHeader("Location", "/");
  webServer.send(303);
}

// ---------- JSON API for the Mac app ----------

const char *displayModeName(DisplayMode m) {
  if (m == MODE_CLAUDE) return "claude";
  if (m == MODE_CODEX) return "codex";
  if (m == MODE_NET) return "net";
  if (m == MODE_MUSIC) return "music";
  if (m == MODE_STOCK) return "stock";
  if (m == MODE_CLOCK) return "clock";
  return "auto";
}

void handleApiInfo() {
  JsonDocument doc;
  doc["ip"] = WiFi.localIP().toString();
  doc["ssid"] = WiFi.SSID();
  doc["bridge"] = bridgeHost;
  doc["mode"] = displayModeName(displayMode);           // configured mode
  doc["effective"] = displayModeName(effectiveMode());   // what's on screen now
  doc["music_playing"] = statusMusicPlaying;
  doc["showing"] = (currentApp == APP_CLAUDE) ? "claude" : "codex";
  doc["last_update_s"] = everPolled ? (long)((millis() - lastSuccessMs) / 1000) : -1;
  doc["sprite_rev"] = spriteRev;
  doc["brightness"] = brightness;
  doc["wired"] = wiredActive(); // true = data currently arrives over USB serial
  doc["fw"] = FW_VERSION;
  doc["wallpaper"] = wallpaperOn && wallpaperReady;
  doc["bg_drawn"] = bgDrawnRev; // rev actually stored in /bg.bin (== weather.bg_rev when in sync)
  JsonObject wth = doc["weather"].to<JsonObject>();
  wth["ok"] = weatherEverLoaded;
  wth["temp"] = weatherTempC;
  wth["code"] = weatherCode;
  wth["humidity"] = weatherHumidity;
  wth["name_rev"] = weatherNameRev;
  wth["bg_rev"] = bgRev;
  JsonObject dsj = doc["deepseek"].to<JsonObject>();
  dsj["ok"] = dsEverLoaded;
  dsj["avail"] = dsAvailable;
  dsj["bal"] = dsBalance;
  dsj["cur"] = dsCurrency;
  JsonObject c = doc["claude"].to<JsonObject>();
  c["status"] = claudeStatus.status;
  c["custom_sprite"] = claudeCustom;
  c["w"] = CLAUDE_SPRITE_W;
  c["h"] = CLAUDE_SPRITE_H;
  JsonObject x = doc["codex"].to<JsonObject>();
  x["status"] = codexStatus.status;
  x["custom_sprite"] = codexCustom;
  x["w"] = CODEX_SPRITE_W;
  x["h"] = CODEX_SPRITE_H;
  String out;
  serializeJson(doc, out);
  webServer.send(200, "application/json", out);
}

void handleApiDisplay() {
  String mode = webServer.arg("mode");
  if (mode == "auto") displayMode = MODE_AUTO;
  else if (mode == "claude") displayMode = MODE_CLAUDE;
  else if (mode == "codex") displayMode = MODE_CODEX;
  else if (mode == "net") displayMode = MODE_NET;
  else if (mode == "music") displayMode = MODE_MUSIC;
  else if (mode == "stock") displayMode = MODE_STOCK;
  else if (mode == "clock") displayMode = MODE_CLOCK;
  else {
    webServer.send(400, "text/plain", "mode must be auto|claude|codex|net|music|stock|clock");
    return;
  }
  Serial.printf("[api] display mode = %s\n", mode.c_str());
  if (displayMode == MODE_NET) {
    netChromeDrawn = false;
    lastNetPollMs = 0; // poll + draw on the next loop tick
  } else if (displayMode == MODE_MUSIC) {
    musicChromeDrawn = false;
    lastMusicPollMs = 0; // poll + draw on the next loop tick
  } else if (displayMode == MODE_STOCK) {
    stockChromeDrawn = false;
    lastStockPollMs = 0; // poll + draw on the next loop tick
  } else if (displayMode == MODE_CLOCK) {
    clockChromeDrawn = false;
    lastClockTickMs = 0; // draw on the next loop tick
    lastWeatherPollMs = 0;
  } else {
    updateActiveApp();
    drawActiveApp(); // unconditional: also repaints over a previous net chart
  }
  webServer.send(200, "text/plain", "ok");
}

void handleApiBrightness() {
  String levelArg = webServer.arg("level");
  if (levelArg.length() == 0) {
    webServer.send(400, "text/plain", "missing level (0-100)");
    return;
  }
  int level = levelArg.toInt();
  if (level < 0) level = 0;
  if (level > 100) level = 100;
  brightness = level;
  applyBrightness();
  saveBrightness();
  Serial.printf("[api] brightness = %d\n", brightness);
  webServer.send(200, "text/plain", "ok");
}

void handleApiWallpaper() {
  String onArg = webServer.arg("on");
  if (onArg.length() == 0) {
    webServer.send(400, "text/plain", "missing on (0/1)");
    return;
  }
  wallpaperOn = onArg.toInt() != 0;
  saveWallpaperCfg();
  clockChromeDrawn = false; // force a full clock repaint with/without the background
  Serial.printf("[api] wallpaper = %d\n", wallpaperOn);
  webServer.send(200, "text/plain", "ok");
}

void handleApiBridge() {
  String newHost = webServer.arg("host");
  newHost.trim();
  if (newHost.length() == 0) {
    webServer.send(400, "text/plain", "missing host");
    return;
  }
  bridgeHost = newHost;
  saveBridgeHost(bridgeHost);
  Serial.printf("[api] bridge host = '%s'\n", bridgeHost.c_str());
  webServer.send(200, "text/plain", "ok");
  lastPollMs = 0; // poll the new bridge on the next loop tick
}

// Streams the animation currently in use for a slot, in the same wire format
// as the custom .bin: [1 byte frame count][RGB565 frames...]. Lets the Mac
// app mirror exactly what the device is showing (custom upload or built-in).
void handleSpriteRaw(ActiveApp slot) {
  bool custom = (slot == APP_CLAUDE) ? claudeCustom : codexCustom;
  const char *binPath = (slot == APP_CLAUDE) ? CLAUDE_SPRITE_FILE : CODEX_SPRITE_FILE;
  if (custom) {
    File f = LittleFS.open(binPath, "r");
    if (f) {
      webServer.streamFile(f, "application/octet-stream");
      f.close();
      return;
    }
  }
  int frames = (slot == APP_CLAUDE) ? CLAUDE_SPRITE_FRAMES : CODEX_SPRITE_FRAMES;
  int w = (slot == APP_CLAUDE) ? CLAUDE_SPRITE_W : CODEX_SPRITE_W;
  int h = (slot == APP_CLAUDE) ? CLAUDE_SPRITE_H : CODEX_SPRITE_H;
  const uint16_t *const *arr = (slot == APP_CLAUDE) ? claude_sprite_frames : codex_sprite_frames;
  size_t frameBytes = (size_t)w * h * 2;
  webServer.setContentLength(1 + (size_t)frames * frameBytes);
  webServer.send(200, "application/octet-stream", "");
  uint8_t cnt = (uint8_t)frames;
  webServer.sendContent((const char *)&cnt, 1);
  for (int i = 0; i < frames; i++) {
    webServer.sendContent_P((PGM_P)arr[i], frameBytes);
    yield();
  }
}

// Removes a custom sprite so the compiled-in default animation comes back.
void handleSpriteReset(ActiveApp slot) {
  const char *binPath = (slot == APP_CLAUDE) ? CLAUDE_SPRITE_FILE : CODEX_SPRITE_FILE;
  LittleFS.remove(binPath);
  spriteRev++;
  loadCustomSpriteState();
  if (slot == APP_CLAUDE) claudeFrame = 0;
  else codexFrame = 0;
  if (currentApp == slot) drawActiveApp();
  webServer.send(200, "text/plain", "ok");
}

void handleResetWifi() {
  webServer.send(200, "text/html", "<html><body>Resetting WiFi, device will restart...</body></html>");
  delay(200);
  WiFiManager wm;
  wm.resetSettings();
  ESP.restart();
}

// ---------- on-device GIF decode (AnimatedGIF) ----------
// AnimatedGIF hands us the image one horizontal line at a time (via the draw
// callback) at the GIF's native resolution, so we never need a full-canvas
// buffer. We nearest-neighbour rescale into the target slot size and stream the
// result straight to the .bin one target row at a time. Because the .bin can't
// hold a whole frame in RAM to composite against, GIFs that only re-encode a
// changed sub-rectangle (the common optimizer output, disposal method 1) are
// composited by reading the *previous frame's* rows back out of the .bin we're
// writing. (Disposal method 2 "restore to background" isn't distinguished -
// uncovered pixels keep the previous frame instead of clearing; fine for the
// looping character animations this is for.)

struct GifDecodeCtx {
  int canvasW, canvasH; // GIF native size
  int targetW, targetH; // slot size we're rescaling down to
  size_t rowBytes;      // targetW * 2
  File out;             // output .bin, written sequentially
  File prevFile;        // previous frame in the .bin, read sequentially for compositing
  bool hasPrev;         // false for frame 0 (nothing to composite over -> black)
  int producedRow;      // next target row still owed for the current frame
};

static File gifReadFile; // one decode runs at a time, so a single handle is fine

void *gifOpenCB(const char *fname, int32_t *pSize) {
  gifReadFile = LittleFS.open(fname, "r");
  if (!gifReadFile) return nullptr;
  *pSize = (int32_t)gifReadFile.size();
  return (void *)&gifReadFile;
}

void gifCloseCB(void *) {
  if (gifReadFile) gifReadFile.close();
}

int32_t gifReadCB(GIFFILE *pFile, uint8_t *pBuf, int32_t iLen) {
  File *f = (File *)pFile->fHandle;
  // AnimatedGIF's own SD example keeps this one-byte-short guard near EOF.
  if ((pFile->iSize - pFile->iPos) < iLen) iLen = pFile->iSize - pFile->iPos - 1;
  if (iLen <= 0) return 0;
  int32_t n = (int32_t)f->read(pBuf, iLen);
  pFile->iPos = (int32_t)f->position();
  return n;
}

int32_t gifSeekCB(GIFFILE *pFile, int32_t iPosition) {
  File *f = (File *)pFile->fHandle;
  f->seek(iPosition);
  pFile->iPos = iPosition;
  return iPosition;
}

// Loads the next previous-frame row into prevRowBuf (black if there's no
// previous frame). Reads are sequential and stay aligned with producedRow.
static void readPrevRow(GifDecodeCtx *ctx) {
  if (ctx->hasPrev)
    ctx->prevFile.read((uint8_t *)prevRowBuf, ctx->rowBytes);
  else
    memset(prevRowBuf, 0, ctx->rowBytes);
}

// Appends the current rowBuf as the next output row.
static void emitRow(GifDecodeCtx *ctx) {
  ctx->out.write((const uint8_t *)rowBuf, ctx->rowBytes);
  ctx->producedRow++;
}

// Emits a row that this frame doesn't touch: a straight copy of the previous
// frame (top/bottom gaps of a partial frame).
static void emitPrevRow(GifDecodeCtx *ctx) {
  readPrevRow(ctx);
  memcpy(rowBuf, prevRowBuf, ctx->rowBytes);
  emitRow(ctx);
}

// Rescales one decoded native line into target rows, compositing over the
// previous frame, and streams every target row it can now finalize.
void gifDrawCB(GIFDRAW *pDraw) {
  GifDecodeCtx *ctx = (GifDecodeCtx *)pDraw->pUser;
  int sy = pDraw->iY + pDraw->y; // absolute source line on the GIF canvas
  if (sy < 0 || sy >= ctx->canvasH) return;

  const uint8_t *pal = pDraw->pPalette24; // RGB888, 256 entries
  const uint8_t *src = pDraw->pPixels;    // palette indices, one per pixel of this line
  bool hasTrans = pDraw->ucHasTransparency;
  uint8_t transIdx = pDraw->ucTransparent;

  // Emit every target row whose nearest source line is <= sy and isn't done yet.
  while (ctx->producedRow < ctx->targetH) {
    int ty = ctx->producedRow;
    int srcRow = (int)((long)ty * ctx->canvasH / ctx->targetH);
    if (srcRow > sy) break;                       // needs a later source line
    if (srcRow < sy) { emitPrevRow(ctx); continue; } // source line was skipped -> previous frame

    // srcRow == sy: composite this source line over the previous frame's row.
    readPrevRow(ctx);
    memcpy(rowBuf, prevRowBuf, ctx->rowBytes);
    for (int tx = 0; tx < ctx->targetW; tx++) {
      int sx = (int)((long)tx * ctx->canvasW / ctx->targetW);
      int rel = sx - pDraw->iX;
      if (rel < 0 || rel >= pDraw->iWidth) continue; // outside this frame's rect: keep previous pixel
      uint8_t idx = src[rel];
      if (hasTrans && idx == transIdx) continue;     // transparent: keep previous pixel
      uint8_t r = pal[idx * 3 + 0], g = pal[idx * 3 + 1], b = pal[idx * 3 + 2];
      uint16_t val = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3);
      rowBuf[tx] = (uint16_t)(((val & 0xFF) << 8) | (val >> 8)); // byte-swap to match convert_sprites.py
    }
    emitRow(ctx);
  }
}

// Decodes gifPath into binPath in the [count][frames...] wire format the
// display path reads. Returns false on open/decode failure.
bool decodeGifToBin(const char *gifPath, const char *binPath, int targetW, int targetH) {
  // AnimatedGIF's internal state (~24KB of LZW/line/palette buffers) is big, so
  // allocate it on the heap only for the duration of a decode rather than
  // paying for it in .bss for the whole uptime.
  AnimatedGIF *gif = new AnimatedGIF();
  if (!gif) return false;
  gif->begin(GIF_PALETTE_RGB888);
  if (!gif->open(gifPath, gifOpenCB, gifCloseCB, gifReadCB, gifSeekCB, gifDrawCB)) {
    Serial.printf("[gif] open failed err=%d\n", gif->getLastError());
    delete gif;
    return false;
  }

  GifDecodeCtx ctx;
  ctx.canvasW = gif->getCanvasWidth();
  ctx.canvasH = gif->getCanvasHeight();
  ctx.targetW = targetW;
  ctx.targetH = targetH;
  ctx.rowBytes = (size_t)targetW * 2;
  ctx.hasPrev = false;
  size_t frameBytes = (size_t)targetW * targetH * 2;

  ctx.out = LittleFS.open(binPath, "w");
  if (!ctx.out) {
    gif->close();
    delete gif;
    return false;
  }
  ctx.out.write((uint8_t)0); // placeholder frame count, patched once we know the total

  uint8_t count = 0;
  int delayMs = 0, more = 1;
  while (count < MAX_CUSTOM_FRAMES) {
    ctx.producedRow = 0;
    ctx.hasPrev = false;
    if (count > 0) {
      ctx.out.flush(); // make the just-written previous frame visible to the read handle
      ctx.prevFile = LittleFS.open(binPath, "r");
      ctx.hasPrev = (bool)ctx.prevFile;
      if (ctx.hasPrev) ctx.prevFile.seek(1 + (size_t)(count - 1) * frameBytes);
    }

    more = gif->playFrame(false, &delayMs, &ctx);

    if (more >= 0) {
      // finalize any bottom rows this frame never touched
      while (ctx.producedRow < ctx.targetH) emitPrevRow(&ctx);
      count++;
    }
    if (ctx.prevFile) ctx.prevFile.close();
    if (more <= 0) break; // 0 = last frame, <0 = decode error
    yield();              // feed the WDT between frames
  }
  gif->close();
  delete gif;
  ctx.out.close();

  if (count == 0) {
    LittleFS.remove(binPath);
    return false;
  }
  File patch = LittleFS.open(binPath, "r+");
  if (patch) {
    patch.seek(0);
    patch.write(count);
    patch.close();
  }
  Serial.printf("[gif] decoded %d frame(s) %dx%d -> %dx%d\n", count, ctx.canvasW, ctx.canvasH, targetW, targetH);
  return true;
}

// ---------- sprite upload (raw .gif -> on-device decode) ----------
// ESP8266WebServer fully buffers a plain POST body into a heap String before
// the handler runs, which a whole GIF would blow RAM on - so we take the
// upload over its streaming multipart/HTTPUpload path, writing the raw .gif to
// LittleFS in small chunks, then decode it on the done callback.
File uploadFile;

void handleSpriteUploadChunk(const char *gifPath) {
  HTTPUpload &upload = webServer.upload();
  if (upload.status == UPLOAD_FILE_START) {
    uploadFile = LittleFS.open(gifPath, "w");
  } else if (upload.status == UPLOAD_FILE_WRITE) {
    if (uploadFile) uploadFile.write(upload.buf, upload.currentSize);
  } else if (upload.status == UPLOAD_FILE_END || upload.status == UPLOAD_FILE_ABORTED) {
    if (uploadFile) uploadFile.close();
  }
}

void handleSpriteUploadDone(ActiveApp slot) {
  const char *gifPath = (slot == APP_CLAUDE) ? CLAUDE_GIF_FILE : CODEX_GIF_FILE;
  const char *binPath = (slot == APP_CLAUDE) ? CLAUDE_SPRITE_FILE : CODEX_SPRITE_FILE;
  int tw = (slot == APP_CLAUDE) ? CLAUDE_SPRITE_W : CODEX_SPRITE_W;
  int th = (slot == APP_CLAUDE) ? CLAUDE_SPRITE_H : CODEX_SPRITE_H;

  bool ok = decodeGifToBin(gifPath, binPath, tw, th);
  LittleFS.remove(gifPath); // temp raw gif no longer needed once decoded

  spriteRev++;
  loadCustomSpriteState();
  if (slot == APP_CLAUDE) claudeFrame = 0;
  else codexFrame = 0;
  if (currentApp == slot) drawActiveApp();

  if (ok) {
    webServer.send(200, "text/plain", "ok");
    Serial.println("[sprite] gif decoded & applied");
  } else {
    webServer.send(500, "text/plain", "gif decode failed (too large or unsupported?)");
    Serial.println("[sprite] gif decode FAILED");
  }
}


void setupWebServer() {
  webServer.on("/", HTTP_GET, handleRoot);
  webServer.on("/save", HTTP_POST, handleSave);
  webServer.on("/reset-wifi", HTTP_POST, handleResetWifi);
  webServer.on("/api/info", HTTP_GET, handleApiInfo);
  webServer.on("/api/display", HTTP_POST, handleApiDisplay);
  webServer.on("/api/bridge", HTTP_POST, handleApiBridge);
  webServer.on("/api/brightness", HTTP_POST, handleApiBrightness);
  webServer.on("/api/wallpaper", HTTP_POST, handleApiWallpaper);
  webServer.on("/sprite/claude/reset", HTTP_POST, []() { handleSpriteReset(APP_CLAUDE); });
  webServer.on("/sprite/codex/reset", HTTP_POST, []() { handleSpriteReset(APP_CODEX); });
  webServer.on("/sprite/claude/raw", HTTP_GET, []() { handleSpriteRaw(APP_CLAUDE); });
  webServer.on("/sprite/codex/raw", HTTP_GET, []() { handleSpriteRaw(APP_CODEX); });
  webServer.on(
      "/sprite/claude", HTTP_POST, []() { handleSpriteUploadDone(APP_CLAUDE); },
      []() { handleSpriteUploadChunk(CLAUDE_GIF_FILE); });
  webServer.on(
      "/sprite/codex", HTTP_POST, []() { handleSpriteUploadDone(APP_CODEX); },
      []() { handleSpriteUploadChunk(CODEX_GIF_FILE); });

  webServer.begin();
  Serial.printf("[web] admin server listening on http://%s/\n", WiFi.localIP().toString().c_str());
}

// ---------- Arduino entry points ----------

void setup() {
  Serial.setRxBufferSize(2048); // a serial #STATUS frame (~600B) must survive a slow draw
  Serial.begin(115200);
  LittleFS.begin();
  loadBridgeHost();
  loadBrightness();
  loadCustomSpriteState();

  loadWallpaperCfg();
  setenv("TZ", CLOCK_TZ, 1); // wired-only mode has no SNTP: localtime() still needs the zone
  tzset();

  tft.init();
  tft.setRotation(0);
  tft.fillScreen(TFT_BLACK);
  analogWriteFreq(BRIGHTNESS_PWM_FREQ);
  analogWriteRange(100); // duty maps 1:1 to a 0-100 percentage
  applyBrightness();

  setupWiFi();

  if (WiFi.status() == WL_CONNECTED) {
    setupWebServer();
    webServerStarted = true;
    setupNtp();

    tft.fillScreen(TFT_BLACK);
    tft.setTextDatum(TL_DATUM);
    tft.setTextColor(TFT_WHITE, TFT_BLACK);
    tft.drawString("WiFi connected", 8, 70, 2);
    tft.drawString("Admin page:", 8, 100, 2);
    tft.setTextColor(TFT_YELLOW, TFT_BLACK);
    tft.drawString("http://" + WiFi.localIP().toString(), 8, 125, 2);
    delay(3000);

    showMainUiIfNeeded();
    pollBridge();
  }
  // else: the config-portal screen stays up; either the user configures WiFi
  // (handled in loop) or serial #STATUS frames arrive and take the screen over
}

void loop() {
  wifiManager.process(); // keeps the config portal alive until WiFi is set up
  pumpSerial();          // wired (USB) bridge frames

  if (!webServerStarted && WiFi.status() == WL_CONNECTED) {
    // WiFi came up after boot (portal or slow AP); the portal has released
    // port 80 by now, so the admin server can bind it
    setupWebServer();
    webServerStarted = true;
    setupNtp();
    showMainUiIfNeeded();
    lastPollMs = 0; // poll the bridge right away
  }
  if (webServerStarted) webServer.handleClient();
  if (!mainUiShown) return; // config-portal screen is up, nothing to animate

  unsigned long nowMs = millis();

  // Effective mode may differ from the configured one (AUTO -> music while
  // audio plays). On a transition, reset the incoming mode's chrome so it
  // repaints cleanly, and repaint the pet immediately when returning to it.
  DisplayMode eff = effectiveMode();
  if (eff != lastEffectiveMode) {
    lastEffectiveMode = eff;
    if (eff == MODE_NET) {
      netChromeDrawn = false;
      lastNetPollMs = 0;
    } else if (eff == MODE_MUSIC) {
      musicChromeDrawn = false;
      lastMusicPollMs = 0;
    } else if (eff == MODE_STOCK) {
      stockChromeDrawn = false;
      lastStockPollMs = 0;
    } else if (eff == MODE_CLOCK) {
      clockChromeDrawn = false;
      lastClockTickMs = 0;
      lastWeatherPollMs = 0; // fetch weather right away on entering the page
    } else {
      updateActiveApp();
      drawActiveApp();
    }
  }

  if (eff == MODE_NET) {
    // net-speed mode: rendering (constant-rate sweep) is independent of the
    // bridge polls that refill its sample queue
    if (nowMs - lastNetDrawMs >= NET_DRAW_INTERVAL_MS) {
      lastNetDrawMs = nowMs;
      netDrawTick();
    }
    if (nowMs - lastNetPollMs >= NET_POLL_INTERVAL_MS) {
      lastNetPollMs = nowMs;
      pollNet();
    }
  } else if (eff == MODE_MUSIC) {
    // music now-playing mode: cover art + track metadata from the bridge
    // (wired: #MUSIC frames drive redraws, art lands as #COVER/#MTEXT pushes)
    if (nowMs - lastMusicPollMs >= MUSIC_POLL_INTERVAL_MS) {
      lastMusicPollMs = nowMs;
      if (!wiredActive()) pollMusic();
    }
  } else if (eff == MODE_STOCK) {
    // stock watchlist: HTTP poll unless the serial link is pushing #STOCK
    if (nowMs - lastStockPollMs >= STOCK_POLL_INTERVAL_MS) {
      lastStockPollMs = nowMs;
      if (!wiredActive()) pollStock();
    }
    if (!stockChromeDrawn || stockDirty) drawStockScreen();
  } else if (eff == MODE_CLOCK) {
    // wall clock page: SNTP keeps time locally, weather comes from the bridge
    if (nowMs - lastClockTickMs >= CLOCK_TICK_MS) {
      lastClockTickMs = nowMs;
      clockTick();
    }
    if (nowMs - lastWeatherPollMs >= WEATHER_POLL_INTERVAL_MS) {
      lastWeatherPollMs = nowMs;
      if (!wiredActive()) { // wired mode: data arrives via #WEATHER/#DEEPSEEK frames
        pollWeather();
        pollDeepSeek();
      }
    }
    // corner pet: free-running walk cycle, same cadence as the pet page
    if (nowMs - lastClockPetMs >= ANIM_INTERVAL_MS) {
      lastClockPetMs = nowMs;
      int frames = (currentApp == APP_CLAUDE) ? claudeFrameCount() : codexFrameCount();
      clockPetFrame = (clockPetFrame + 1) % frames;
      drawClockPet(currentApp, clockPetFrame);
    }
  } else {
    // sprite walk-cycle animation (only advances while that app is showing)
    if (nowMs - lastAnimMs >= ANIM_INTERVAL_MS) {
      lastAnimMs = nowMs;
      bool claudeWorking = claudeStatus.status == "working";
      bool codexWorking = codexStatus.status == "working";
      if (showingCd != CD_NONE) {
        // countdown owns the center area: no sprite frames over it
      } else if (currentApp == APP_CLAUDE && claudeWorking) {
        claudeFrame = (claudeFrame + 1) % claudeFrameCount();
        drawClaudeSprite(claudeFrame);
      } else if (currentApp == APP_CODEX && codexWorking) {
        codexFrame = (codexFrame + 1) % codexFrameCount();
        drawCodexSprite(codexFrame);
      }
    }

    // countdown seconds tick locally between bridge polls
    static unsigned long lastCdTickMs = 0;
    if (showingCd != CD_NONE && nowMs - lastCdTickMs >= 1000) {
      lastCdTickMs = nowMs;
      drawCountdown(false);
    }

    // "urgent" flash toggle (independent, faster cadence)
    if (nowMs - lastFlashMs >= FLASH_INTERVAL_MS) {
      lastFlashMs = nowMs;
      flashOn = !flashOn;
      if (bridgeStale()) {
        redrawRingOnly();
      } else if (currentAppNeedsInput()) {
        // approval needed: blink the whole border red, restore the quota ring
        // on the off-phase so it doesn't erase the normal chrome permanently
        if (flashOn) drawFullBorder(TFT_RED);
        else redrawRingOnly();
      }
    }

    // alternate which app is shown when neither/both are uniquely working
    if (updateActiveApp()) {
      drawActiveApp();
    }
  }

  // status poll continues in every mode (feeds /api/info and the web page).
  // Wired-first: while serial frames are flowing, skip HTTP polling entirely
  // (works around AP client isolation, and avoids double updates).
  if (nowMs - lastPollMs >= BRIDGE_POLL_INTERVAL_MS) {
    lastPollMs = nowMs;
    if (!wiredActive()) pollBridge();
  }
}
