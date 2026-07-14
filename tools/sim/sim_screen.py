"""固件绘制模拟器（卡片版）。

复刻 main.cpp 的 drawDualQuota()：同样的坐标常量、同样的清除矩形、同样的
字体度量，逐笔画到 PIL 画布上。目的是在没有屏幕的情况下验证增量更新
（不 force 重绘）会不会留下残影或者撞字。

字形渲染刻意模仿 TFT_eSPI 的 smooth font：设了背景色时，它只把字形自己的
包围盒填成背景色再混合，盒子外面的旧像素原样留着。残影就是这么来的。

改了 main.cpp 里的常量，这里要同步改。
"""
import freetype
from PIL import Image, ImageDraw

OTF = "../fonts/Inter-Medium.otf"
W = H = 240

C_WHITE = (255, 251, 247)
C_GREY = (181, 174, 165)
C_TRACK = (41, 40, 41)
C_CARD = (24, 28, 24)
C_ORANGE = (222, 117, 82)
C_BLUE = (107, 116, 248)
C_GREEN = (123, 142, 90)
BLACK = (0, 0, 0)

# --- 与 main.cpp 逐字对应 ---
CARD_X, CARD_W, CARD_H, CARD_R = 8, 224, 52, 8
K_LAB_X, K_NUM_X, K_TIME_R = 18, 48, 222
K_BAR_X, K_BAR_W, K_BAR_H = 18, 204, 6
K_NUM_Y, K_LAB_Y, K_BAR_Y = 4, 10, 40
T_LOGO_X, T_NAME_X, T_DOT_X = 10, 40, 222
T_NAME_Y, T_DOT_Y = 5, 12
TITLE1_Y, CARD1_Y, CARD2_Y = 3, 29, 85  # TITLE1_Y >= ALERT_W (3), see main.cpp
DIV_Y = 141
TITLE2_Y, CARD3_Y = 145, 171

_faces, _metrics = {}, {}


def face(px):
    if px not in _faces:
        f = freetype.Face(OTF)
        f.set_pixel_sizes(0, px)
        _faces[px] = f
        f.load_char("d")
        asc = f.glyph.bitmap_top
        f.load_char("p")
        desc = f.glyph.bitmap.rows - f.glyph.bitmap_top
        _metrics[px] = (asc, desc)
    return _faces[px]


def text_width(s, px):
    f = face(px)
    asc, desc = _metrics[px]
    w = 0
    for ch in s:
        if ch == " ":
            w += (asc + desc) * 2 // 7  # TFT_eSPI 对空格的特判
            continue
        f.load_char(ch, freetype.FT_LOAD_RENDER)
        w += f.glyph.advance.x >> 6
    return w


class Screen:
    def __init__(self):
        self.im = Image.new("RGB", (W, H), BLACK)
        self.d = ImageDraw.Draw(self.im)

    def fill_rect(self, x, y, w, h, c):
        self.d.rectangle([x, y, x + w - 1, y + h - 1], fill=c)

    def fill_round_rect(self, x, y, w, h, r, c):
        self.d.rounded_rectangle([x, y, x + w - 1, y + h - 1], radius=r, fill=c)

    def fill_circle(self, cx, cy, r, c):
        self.d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=c)

    def hline(self, x, y, w, c):
        self.d.rectangle([x, y, x + w - 1, y], fill=c)

    def paste_logo(self, path, x, y, size=24):
        lg = Image.open(path).convert("RGBA").resize((size, size), Image.LANCZOS)
        self.im.paste(lg, (x, y), lg)

    def draw_string(self, s, x, y, px, fg, bg, datum="TL"):
        """y = 字形框顶边（TL_DATUM）。datum='TR' 时 x 是右边界。"""
        f = face(px)
        asc, _ = _metrics[px]
        if datum == "TR":
            x -= text_width(s, px)
        pen = x
        for ch in s:
            if ch == " ":
                pen += text_width(" ", px)
                continue
            f.load_char(ch, freetype.FT_LOAD_RENDER)
            bm = f.glyph.bitmap
            gx, gy = pen + f.glyph.bitmap_left, y + (asc - f.glyph.bitmap_top)
            for r in range(bm.rows):
                for cX in range(bm.width):
                    a = bm.buffer[r * bm.pitch + cX] / 255.0
                    X, Y = gx + cX, gy + r
                    if 0 <= X < W and 0 <= Y < H:
                        # smooth font 有背景色时：盒内像素 = fg 与 bg 混合，直接覆盖
                        self.im.putpixel((X, Y), tuple(
                            int(fg[i] * a + bg[i] * (1 - a)) for i in range(3)))
            pen += f.glyph.advance.x >> 6


def reset_text(m):
    if m is None or m < 0:
        return "-"
    if m < 60:
        return "%dm" % m
    if m < 1440:
        return "%dh %dm" % (m // 60, m % 60)
    return "%dd %dh" % (m // 1440, (m % 1440) // 60)


def pct_text(p):
    return "%d%%" % int(p) if p is not None and p >= 0 else "-"


class Cache:
    def __init__(self):
        self.n1 = self.t1 = self.n2 = self.t2 = None
        self.working = None


class Sim:
    def __init__(self):
        self.s = Screen()
        self.cc = Cache()
        self.cx = Cache()

    def draw(self, cl, cx, force=False):
        s = self.s
        if force:
            s.fill_rect(0, 0, W, H, BLACK)
            s.paste_logo("logo24-claude_logo.png", T_LOGO_X, TITLE1_Y)
            s.paste_logo("logo24-codex_logo.png", T_LOGO_X, TITLE2_Y)
            for cy in (CARD1_Y, CARD2_Y, CARD3_Y):
                s.fill_round_rect(CARD_X, cy, CARD_W, CARD_H, CARD_R, C_CARD)
            s.hline(CARD_X, DIV_Y, CARD_W, C_TRACK)
            self.cc, self.cx = Cache(), Cache()

        self._title(TITLE1_Y, "Claude", cl["status"] == "working", self.cc, force)
        self._title(TITLE2_Y, "Codex", cx["status"] == "working", self.cx, force)
        self._small(CARD1_Y, "5H", reset_text(cl["r5"]), self.cc, "t1", force)
        self._small(CARD2_Y, "WK", reset_text(cl["rw"]), self.cc, "t2", force)
        self._small(CARD3_Y, "WK", reset_text(cx["rw"]), self.cx, "t1", force)

        self._big(CARD1_Y, pct_text(cl["p5"]), self.cc, "n1", force)
        self._big(CARD2_Y, pct_text(cl["pw"]), self.cc, "n2", force)
        self._big(CARD3_Y, pct_text(cx["pw"]), self.cx, "n1", force)

        self._bar(CARD1_Y, cl["p5"], C_ORANGE)
        self._bar(CARD2_Y, cl["pw"], C_ORANGE)
        self._bar(CARD3_Y, cx["pw"], C_BLUE)
        return self.s.im.copy()

    def _title(self, y, name, working, c, force):
        if force:
            self.s.draw_string(name, T_NAME_X, y + T_NAME_Y, 13, C_WHITE, BLACK)
        if not force and working == c.working:
            return
        c.working = working
        self.s.fill_circle(T_DOT_X, y + T_DOT_Y, 4, C_GREEN if working else C_TRACK)

    def _small(self, cardY, label, time, c, field, force):
        if force:
            self.s.draw_string(label, K_LAB_X, cardY + K_LAB_Y, 13, C_GREY, C_CARD)
        if force or time != getattr(c, field):
            setattr(c, field, time)
            self.s.fill_rect(K_TIME_R - 58, cardY + K_LAB_Y, 58, 15, C_CARD)
            self.s.draw_string(time, K_TIME_R, cardY + K_LAB_Y, 13, C_GREY, C_CARD, datum="TR")

    def _big(self, cardY, pct, c, field, force):
        if not force and pct == getattr(c, field):
            return
        setattr(c, field, pct)
        self.s.fill_rect(K_NUM_X, cardY + K_NUM_Y, 94, 34, C_CARD)
        self.s.draw_string(pct, K_NUM_X, cardY + K_NUM_Y, 32, C_WHITE, C_CARD)

    def _bar(self, cardY, pct, color):
        y = cardY + K_BAR_Y
        self.s.fill_round_rect(K_BAR_X, y, K_BAR_W, K_BAR_H, K_BAR_H // 2, C_TRACK)
        if pct is None or pct <= 0:
            return
        fw = max(int(K_BAR_W * min(pct, 100) / 100.0 + 0.5), K_BAR_H)
        self.s.fill_round_rect(K_BAR_X, y, fw, K_BAR_H, K_BAR_H // 2, color)
