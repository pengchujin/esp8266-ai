#!/usr/bin/env python3
"""
OTF -> VLW (TFT_eSPI smooth font) generator + verifier.

Replicates Processing's Create_Smooth_Font / PFont.save() output format using
freetype-py, then verifies the result by re-parsing it exactly the way
TFT_eSPI's Smooth_font.cpp does.

Format (all big-endian uint32):
  header  : gCount, version(11), fontSize, mboxY(0), ascent, descent      (24 bytes)
  metrics : gCount * [unicode, height, width, xAdvance, dY, dX, 0]        (28 bytes each)
  bitmaps : concatenated 8-bit alpha, row-major, no padding

gdY semantics (verified against TFT_eSPI v2.5.43 Smooth_font.cpp):
    drawGlyph(): cy = cursor_y + maxAscent - gdY[i]
    i.e. gdY = distance from BASELINE up to the TOP of the bitmap = FT bitmap_top.
"""

import os
import struct
import sys

import freetype
from PIL import Image

SCRATCH = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(SCRATCH)
OTF = os.path.join(SCRATCH, "fonts", "Inter-Medium.otf")
FONT_STEM = os.path.basename(OTF).split("-")[0].split(".")[0]
FONTS_DIR = os.path.join(SCRATCH, "fonts")
CHECK_DIR = os.path.join(SCRATCH, "fontcheck")
# Headers go straight where the firmware includes them from, so a run of this
# script reproduces the committed build inputs with no copy step in between.
HEADER_DIR = os.path.join(REPO, "firmware", "include", "fonts")

# digits, percent, A-Z, a-z, space, hyphen, dot, colon
CHARSET = sorted(set(
    "0123456789"
    "%"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "abcdefghijklmnopqrstuvwxyz"
    " -.:"
))

VLW_VERSION = 11


# ---------------------------------------------------------------- rendering

def render_glyph(face, ch):
    """Render one char to an 8-bit gray bitmap. Returns dict of metrics + rows."""
    face.load_char(ch, freetype.FT_LOAD_RENDER | freetype.FT_LOAD_TARGET_NORMAL)
    g = face.glyph
    bmp = g.bitmap

    if bmp.pixel_mode != freetype.FT_PIXEL_MODE_GRAY:
        raise RuntimeError(
            "char %r rendered as pixel_mode=%d, expected GRAY(2). "
            "Anti-aliasing did not happen." % (ch, bmp.pixel_mode)
        )
    if bmp.num_grays != 256 and bmp.width:
        raise RuntimeError("char %r: num_grays=%d, expected 256" % (ch, bmp.num_grays))

    w, h, pitch = bmp.width, bmp.rows, bmp.pitch
    buf = bmp.buffer

    # Un-pad: FreeType rows are `pitch` bytes apart, pitch >= width (can be negative).
    data = bytearray()
    for row in range(h):
        start = row * abs(pitch)
        if pitch < 0:  # bottom-up flow
            start = (h - 1 - row) * abs(pitch)
        data += bytes(buf[start:start + w])

    assert len(data) == w * h, "unpadding failed for %r" % ch

    adv = int(round(g.advance.x / 64.0))

    return {
        "char": ch,
        "unicode": ord(ch),
        "width": w,
        "height": h,
        "xadvance": adv,
        "dY": g.bitmap_top,     # baseline -> top of bitmap, positive up
        "dX": g.bitmap_left,
        "bitmap": bytes(data),
    }


def build_vlw(otf_path, size_px):
    face = freetype.Face(otf_path)
    face.set_pixel_sizes(0, size_px)

    glyphs = []
    for ch in CHARSET:
        gl = render_glyph(face, ch)

        # Processing's PFont emits a 1x1 transparent pixel for blank glyphs
        # (space) rather than a 0x0 bitmap. Match that.
        if gl["width"] == 0 or gl["height"] == 0:
            gl["width"] = 1
            gl["height"] = 1
            gl["dY"] = 0
            gl["dX"] = 0
            gl["bitmap"] = b"\x00"

        # Range checks: TFT_eSPI narrows these on read.
        if not (0 <= gl["width"] <= 255 and 0 <= gl["height"] <= 255):
            raise RuntimeError("%r: w/h exceeds uint8" % ch)
        if not (0 <= gl["xadvance"] <= 255):
            raise RuntimeError("%r: xAdvance %d exceeds uint8" % (ch, gl["xadvance"]))
        if not (-128 <= gl["dX"] <= 127):
            raise RuntimeError("%r: gdX %d exceeds int8" % (ch, gl["dX"]))
        if not (-32768 <= gl["dY"] <= 32767):
            raise RuntimeError("%r: gdY %d exceeds int16" % (ch, gl["dY"]))

        glyphs.append(gl)

    glyphs.sort(key=lambda g: g["unicode"])

    # Header ascent/descent, Processing semantics: "top of d" / "bottom of p".
    # TFT_eSPI only uses these for spaceWidth = (ascent + descent) * 2/7.
    by_char = {g["char"]: g for g in glyphs}
    ascent = by_char["d"]["dY"]
    descent = by_char["p"]["height"] - by_char["p"]["dY"]

    out = bytearray()
    out += struct.pack(">6I", len(glyphs), VLW_VERSION, size_px, 0, ascent, descent)

    for g in glyphs:
        out += struct.pack(
            ">7I",
            g["unicode"],
            g["height"],
            g["width"],
            g["xadvance"],
            g["dY"] & 0xFFFFFFFF,   # two's complement if negative
            g["dX"] & 0xFFFFFFFF,
            0,
        )

    for g in glyphs:
        out += g["bitmap"]

    return bytes(out), glyphs, ascent, descent, face


# ---------------------------------------------------------------- verifying

def parse_vlw(blob):
    """Independent reverse parser - mirrors TFT_eSPI loadFont/loadMetrics."""
    if len(blob) < 24:
        raise RuntimeError("file shorter than header")

    gCount, version, fontSize, mboxY, ascent, descent = struct.unpack(">6I", blob[:24])

    glyphs = []
    header_ptr = 24
    bitmap_ptr = 24 + gCount * 28

    for i in range(gCount):
        off = header_ptr + i * 28
        uni, h, w, adv, dY, dX, pad = struct.unpack(">7I", blob[off:off + 28])
        # narrow the way the C code does
        dY = struct.unpack(">h", struct.pack(">H", dY & 0xFFFF))[0]   # int16
        dX = struct.unpack(">b", struct.pack(">B", dX & 0xFF))[0]     # int8
        glyphs.append({
            "unicode": uni & 0xFFFF, "height": h & 0xFF, "width": w & 0xFF,
            "xadvance": adv & 0xFF, "dY": dY, "dX": dX, "pad": pad,
            "bitmap_ptr": bitmap_ptr,
        })
        bitmap_ptr += (w & 0xFF) * (h & 0xFF)

    return {
        "gCount": gCount, "version": version, "fontSize": fontSize,
        "mboxY": mboxY, "ascent": ascent, "descent": descent,
        "glyphs": glyphs, "bitmap_end": bitmap_ptr,
    }


def verify(blob, size_px, expected_count):
    print("  [verify] re-parsing %d bytes..." % len(blob))
    p = parse_vlw(blob)
    ok = True

    def check(label, cond, detail=""):
        nonlocal ok
        if not cond:
            ok = False
        print("    %-42s %s %s" % (label, "PASS" if cond else "FAIL", detail))

    check("header gCount == charset size",
          p["gCount"] == expected_count, "(%d)" % p["gCount"])
    check("header version == 11", p["version"] == VLW_VERSION, "(%d)" % p["version"])
    check("header fontSize == %d" % size_px,
          p["fontSize"] == size_px, "(%d)" % p["fontSize"])
    check("header mboxY == 0", p["mboxY"] == 0, "(%d)" % p["mboxY"])
    check("header ascent > 0", p["ascent"] > 0, "(%d)" % p["ascent"])
    check("header descent > 0", p["descent"] > 0, "(%d)" % p["descent"])

    # every glyph: bitmap byte count == w*h, and slice is actually in-bounds
    bad_bitmap = []
    bad_pad = []
    for g in p["glyphs"]:
        need = g["width"] * g["height"]
        start, end = g["bitmap_ptr"], g["bitmap_ptr"] + need
        if end > len(blob) or len(blob[start:end]) != need:
            bad_bitmap.append(chr(g["unicode"]))
        if g["pad"] != 0:
            bad_pad.append(chr(g["unicode"]))

    check("every glyph bitmap == gWidth*gHeight bytes",
          not bad_bitmap, "" if not bad_bitmap else "bad: %r" % bad_bitmap)
    check("every glyph reserved field == 0",
          not bad_pad, "" if not bad_pad else "bad: %r" % bad_pad)

    total_bmp = sum(g["width"] * g["height"] for g in p["glyphs"])
    expect_len = 24 + p["gCount"] * 28 + total_bmp
    check("len == 24 + gCount*28 + sum(bitmaps)",
          len(blob) == expect_len,
          "(%d == %d)" % (len(blob), expect_len))
    check("bitmap region ends exactly at EOF",
          p["bitmap_end"] == len(blob),
          "(%d == %d)" % (p["bitmap_end"], len(blob)))

    check("unicodes strictly ascending",
          all(p["glyphs"][i]["unicode"] < p["glyphs"][i + 1]["unicode"]
              for i in range(len(p["glyphs"]) - 1)))

    # what TFT_eSPI will compute at runtime
    max_ascent = p["ascent"]
    max_descent = p["descent"]
    for g in p["glyphs"]:
        if 0x20 < g["unicode"] < 0x7F:
            max_ascent = max(max_ascent, g["dY"])
            max_descent = max(max_descent, g["height"] - g["dY"])
    y_advance = max_ascent + max_descent
    space_width = (p["ascent"] + p["descent"]) * 2 // 7

    print("    -> runtime: maxAscent=%d maxDescent=%d yAdvance=%d spaceWidth=%d"
          % (max_ascent, max_descent, y_advance, space_width))

    return ok, p, {"maxAscent": max_ascent, "yAdvance": y_advance,
                   "spaceWidth": space_width}


# ------------------------------------------------------------ visual check

def visualize(blob, p, rt, size_px, tag):
    """Rebuild glyphs from the PARSED vlw only. Two checks:
       1. each glyph as its own PNG (raw bitmap fidelity)
       2. a full string laid out with TFT_eSPI's exact math (metrics fidelity)
    """
    os.makedirs(CHECK_DIR, exist_ok=True)
    by_uni = {g["unicode"]: g for g in p["glyphs"]}

    def glyph_img(g):
        need = g["width"] * g["height"]
        data = blob[g["bitmap_ptr"]:g["bitmap_ptr"] + need]
        return Image.frombytes("L", (g["width"], g["height"]), data)

    # 1. individual glyphs, scaled up 8x nearest-neighbour so we can see pixels
    for ch in ["3", "5", "%", "W"]:
        g = by_uni[ord(ch)]
        img = glyph_img(g)
        big = img.resize((img.width * 8, img.height * 8), Image.NEAREST)
        name = {"%": "pct"}.get(ch, ch)
        path = os.path.join(CHECK_DIR, "%s_glyph_%s.png" % (tag, name))
        big.save(path)
        print("    wrote %s  (%dx%d, dX=%d dY=%d adv=%d)"
              % (os.path.basename(path), g["width"], g["height"],
                 g["dX"], g["dY"], g["xadvance"]))

    # 2. string layout, replicating drawGlyph():
    #      cy = cursor_y + maxAscent - gdY ; cx = cursor_x + gdX ; cursor_x += gxAdvance
    text = "35% Wq Ag.-:"
    max_ascent, y_adv, sp = rt["maxAscent"], rt["yAdvance"], rt["spaceWidth"]

    total_w = 0
    for ch in text:
        if ch == " ":
            total_w += sp
        else:
            total_w += by_uni[ord(ch)]["xadvance"]

    pad = 6
    W, H = total_w + pad * 2, y_adv + pad * 2

    def layout(canvas, guides):
        """Paste guides FIRST, then composite glyphs on top through their own
        alpha mask, so guide lines never destroy glyph pixels."""
        if guides:
            px = canvas.load()
            for x in range(W):
                px[x, pad + max_ascent] = (120, 30, 30)     # baseline (red)
                px[x, pad] = (30, 60, 120)                  # line top (blue)
                px[x, pad + y_adv - 1] = (30, 90, 30)       # line bottom (green)
        cursor_x = 0
        for ch in text:
            if ch == " ":                # TFT_eSPI intercepts 0x20 itself
                cursor_x += sp
                continue
            g = by_uni[ord(ch)]
            cx = cursor_x + g["dX"]
            cy = max_ascent - g["dY"]
            m = glyph_img(g)
            canvas.paste((255, 255, 255), (cx + pad, cy + pad), m)  # m = alpha mask
            cursor_x += g["xadvance"]
        return canvas

    scale = 6 if size_px <= 12 else 3
    for guides, suffix in ((True, "string"), (False, "string_clean")):
        c = layout(Image.new("RGB", (W, H), (0, 0, 0)), guides)
        c = c.resize((W * scale, H * scale), Image.NEAREST)
        path = os.path.join(CHECK_DIR, "%s_%s.png" % (tag, suffix))
        c.save(path)
        print("    wrote %s  ('%s'%s)"
              % (os.path.basename(path), text,
                 ", baseline=red top=blue bottom=green" if guides else ", no overlay"))


# ------------------------------------------------------------- C header out

def write_header(blob, out_path, array_name, len_define, size_px, gcount):
    lines = []
    lines.append("// %s - TFT_eSPI VLW smooth font, generated by gen_vlw.py" % os.path.basename(out_path))
    lines.append("// Source: %s | size: %dpx | glyphs: %d | bytes: %d"
                 % (os.path.basename(OTF), size_px, gcount, len(blob)))
    lines.append("// Usage:  tft.loadFont(%s);  ...  tft.unloadFont();" % array_name)
    lines.append("#pragma once")
    lines.append("#include <pgmspace.h>")
    lines.append("")
    lines.append("#define %s %d" % (len_define, len(blob)))
    lines.append("")
    lines.append("const uint8_t %s[] PROGMEM __attribute__((aligned(4))) = {" % array_name)

    per_line = 16
    for i in range(0, len(blob), per_line):
        chunk = blob[i:i + per_line]
        lines.append("  " + ", ".join("0x%02X" % b for b in chunk) + ("," if i + per_line < len(blob) else ""))

    lines.append("};")
    lines.append("")

    with open(out_path, "w") as f:
        f.write("\n".join(lines))


# -------------------------------------------------------------------- main

def main():
    if not os.path.exists(OTF):
        sys.exit("missing font: %s" % OTF)

    os.makedirs(FONTS_DIR, exist_ok=True)
    os.makedirs(CHECK_DIR, exist_ok=True)

    face0 = freetype.Face(OTF)
    print("Font: %s %s | format=%s | upem=%d | glyphs=%d"
          % (face0.family_name.decode(), face0.style_name.decode(),
             face0.get_format().decode(), face0.units_per_EM, face0.num_glyphs))
    print("freetype lib %s | charset: %d chars\n"
          % (".".join(map(str, freetype.version())), len(CHARSET)))

    targets = [
        (32, "inter32.h", "Inter32", "INTER32_LEN", "i32"),
        (13, "inter13.h", "Inter13", "INTER13_LEN", "i13"),
    ]

    all_ok = True
    summary = []

    for size_px, hdr_name, arr_name, len_def, tag in targets:
        print("=" * 68)
        print("SIZE %dpx" % size_px)
        print("=" * 68)

        blob, glyphs, ascent, descent, face = build_vlw(OTF, size_px)
        print("  built: %d glyphs, %d bytes | header ascent=%d descent=%d"
              % (len(glyphs), len(blob), ascent, descent))

        # sanity: is AA actually happening? count distinct gray levels
        levels = set()
        for g in glyphs:
            levels.update(g["bitmap"])
        mid = [v for v in levels if 0 < v < 255]
        print("  gray levels used: %d distinct (%d are partial/anti-aliased)"
              % (len(levels), len(mid)))
        if len(mid) < 8:
            print("  !! WARNING: very few intermediate grays - AA may not be working")
            all_ok = False

        vlw_path = os.path.join(FONTS_DIR, "%s%d.vlw" % (FONT_STEM, size_px))
        with open(vlw_path, "wb") as f:
            f.write(blob)
        print("  wrote %s" % vlw_path)

        ok, p, rt = verify(blob, size_px, len(CHARSET))
        all_ok = all_ok and ok

        print("  [visual]")
        visualize(blob, p, rt, size_px, tag)

        hdr_path = os.path.join(HEADER_DIR, hdr_name)
        write_header(blob, hdr_path, arr_name, len_def, size_px, len(glyphs))
        print("  wrote %s (%d bytes of PROGMEM)" % (hdr_path, len(blob)))

        # true space advance, for comparison with TFT_eSPI's guess
        face.set_pixel_sizes(0, size_px)
        face.load_char(" ", freetype.FT_LOAD_RENDER | freetype.FT_LOAD_TARGET_NORMAL)
        true_space = int(round(face.glyph.advance.x / 64.0))

        summary.append({
            "size": size_px, "bytes": len(blob), "glyphs": len(glyphs),
            "ascent": ascent, "descent": descent,
            "maxAscent": rt["maxAscent"], "yAdvance": rt["yAdvance"],
            "spaceWidth": rt["spaceWidth"], "trueSpace": true_space,
            "header": hdr_name, "array": arr_name, "ok": ok,
        })
        print()

    print("=" * 68)
    print("SUMMARY")
    print("=" * 68)
    print("%-6s %-9s %-7s %-9s %-9s %-10s %s"
          % ("size", "bytes", "glyphs", "yAdvance", "maxAsc", "spaceWidth", "verify"))
    for s in summary:
        print("%-6s %-9s %-7s %-9s %-9s %-10s %s"
              % ("%dpx" % s["size"], s["bytes"], s["glyphs"], s["yAdvance"],
                 s["maxAscent"],
                 "%d (true %d)" % (s["spaceWidth"], s["trueSpace"]),
                 "PASS" if s["ok"] else "FAIL"))

    total = sum(s["bytes"] for s in summary)
    print("\nTotal PROGMEM for both fonts: %d bytes (%.1f KB)" % (total, total / 1024.0))
    print("\nALL CHECKS: %s" % ("PASS" if all_ok else "FAIL"))
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
