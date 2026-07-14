"""按真实 poll 序列跑一遍状态机，只有第一帧 force，其余全是增量更新。

残影只会在增量更新里出现（长字符串换成短字符串时，清除框没盖住尾巴），
所以这里刻意安排了 100% -> 5%、"6d 23h" -> "45m"、working -> idle 这些收缩。
"""
from PIL import Image, ImageDraw
from sim_screen import Sim, W, H

STEPS = [
    ("01 开机 force\n全部未知",
     dict(status="unknown", p5=-1, pw=-1, r5=-1, rw=-1),
     dict(status="unknown", pw=-1, rw=-1), True),

    ("02 首次拿到数据\nclaude working",
     dict(status="working", p5=11, pw=36, r5=139, rw=3779),
     dict(status="idle", pw=21, rw=9924), False),

    ("03 最宽情况\n100% + 6d 23h",
     dict(status="working", p5=100, pw=99, r5=299, rw=10019),
     dict(status="idle", pw=100, rw=10019), False),

    ("04 收缩\n100%->5%, 长时间->45m",
     dict(status="working", p5=5, pw=36, r5=45, rw=3779),
     dict(status="idle", pw=7, rw=45), False),

    ("05 状态翻转\nclaude idle / codex working",
     dict(status="idle", p5=5, pw=36, r5=45, rw=3779),
     dict(status="working", pw=7, rw=45), False),

    ("06 全部离线\n值变回 -",
     dict(status="offline", p5=-1, pw=-1, r5=-1, rw=-1),
     dict(status="offline", pw=-1, rw=-1), False),

    ("07 零值\n0% / 0m",
     dict(status="working", p5=0, pw=0, r5=0, rw=0),
     dict(status="idle", pw=0, rw=0), False),

    ("08 回到常态\n再确认一次",
     dict(status="working", p5=11, pw=36, r5=139, rw=3779),
     dict(status="idle", pw=21, rw=9924), False),
]

sim = Sim()
frames = []
for label, cl, cx, force in STEPS:
    frames.append((label, sim.draw(cl, cx, force)))

# 拼 4x2 网格，每格上方写标题
CELL_W, CELL_H, GAP, TITLE = W, H, 16, 34
cols, rows = 4, 2
sheet = Image.new("RGB", (cols * (CELL_W + GAP) + GAP,
                          rows * (CELL_H + TITLE + GAP) + GAP), (245, 245, 245))
d = ImageDraw.Draw(sheet)
for i, (label, im) in enumerate(frames):
    cx_, cy_ = i % cols, i // cols
    x = GAP + cx_ * (CELL_W + GAP)
    y = GAP + cy_ * (CELL_H + TITLE + GAP)
    d.multiline_text((x, y), label, fill=(20, 20, 20), spacing=2)
    sheet.paste(im, (x, y + TITLE))
sheet.save("statecheck.png")

# 单独存最容易出问题的两帧，放大 2 倍细看
for idx, name in [(3, "step04-shrink"), (4, "step05-flip")]:
    frames[idx][1].resize((W * 2, H * 2), Image.NEAREST).save(f"{name}.png")

print("statecheck.png + step04-shrink.png + step05-flip.png")
