# -*- coding: utf-8 -*-
"""程序化生成全部遗物图标（原创几何图案，不依赖任何外部素材）。

流程:
  1. 解析 src/relics.lua，提取每件遗物的 id / rarity（含 icon 字段者需出图）；
     循环生成的 give_card_2..8 由本脚本按同一规则补充。
  2. 每件遗物按「id 关键词 -> 图案族」得到中心图案，再用 id 的 md5 做种子
     决定旋转角/花色/点缀，保证 126 张互不相同且每次重新生成结果一致。
  3. 输出 assets/relics/<id>.png（71x95，2x 超采样抗锯齿）与预览拼图。

用法（在仓库根目录）:
  python tools/gen_relic_art.py            # 生成全部图标 + 预览
  python tools/gen_relic_art.py --preview  # 只重新输出预览拼图
"""
import hashlib
import math
import os
import random
import re
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "assets", "relics")
PREVIEW = os.path.join(ROOT, "tools", "relic_preview.png")

FRAME_W, FRAME_H = 71, 95   # 与 ui 内遗物格子同比例（游戏内等比缩放绘制）
SS = 2                      # 超采样倍率

# 稀有度基色（与 src/relics.lua 的 Relics.RARITY 一致，游戏内兜底色同源）
RARITY_RGB = {
    "common":    (178, 178, 178),
    "uncommon":  (77, 204, 77),
    "rare":      (77, 128, 255),
    "legendary": (255, 179, 51),
    "cursed":    (230, 51, 51),
}

# ---------------------------------------------------------------- 解析 ----

def parse_relics():
    """从 src/relics.lua 提取 (id, rarity, has_icon)；give_card_2..8 程序化补充。"""
    src = open(os.path.join(ROOT, "src", "relics.lua"), encoding="utf-8").read()
    start = src.index("Relics.LIBRARY")
    body = src[start:]
    entries, i = [], 0
    while True:
        m = re.compile(r'\{\s*id\s*=\s*"(\w+)"').search(body, i)
        if not m:
            break
        depth, j = 0, m.start()
        while j < len(body):
            if body[j] == "{":
                depth += 1
            elif body[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        block = body[m.start():j + 1]
        rid = m.group(1)
        if rid.endswith("_"):
            i = m.end()  # 循环生成段的 id = "give_card_" .. rank 拼接代码，非字面定义
            continue
        rm = re.search(r'rarity\s*=\s*"(\w+)"', block)
        rarity = rm.group(1) if rm else "common"
        has_icon = re.search(r"\bicon\s*=\s*\d+", block) is not None
        entries.append((rid, rarity, has_icon))
        i = j + 1
    # 循环生成的「给牌」遗物（relics.lua 内 icon = 70 + idx）
    entries += [("give_card_%d" % r, "uncommon", True) for r in range(2, 9)]
    return entries


# ------------------------------------------------------------ 基础绘制 ----

def mix(c, k):
    return tuple(int(v * k) for v in c)


def rot(pts, cx, cy, ang):
    ca, sa = math.cos(ang), math.sin(ang)
    return [(cx + (x - cx) * ca - (y - cy) * sa,
             cy + (x - cx) * sa + (y - cy) * ca) for x, y in pts]


def poly(d, pts, fill):
    if len(pts) >= 3:
        d.polygon(pts, fill=fill)


def star_pts(cx, cy, r_out, r_in, n=5, ang=-math.pi / 2):
    pts = []
    for k in range(n * 2):
        r = r_out if k % 2 == 0 else r_in
        a = ang + k * math.pi / n
        pts.append((cx + math.cos(a) * r, cy + math.sin(a) * r))
    return pts


def suit(d, cx, cy, s, kind, col):
    """扑克花色: 0 黑桃 1 红心 2 方块 3 梅花（多边形近似）。"""
    if kind == 2:  # 方块
        poly(d, [(cx, cy - s), (cx + s * 0.72, cy), (cx, cy + s), (cx - s * 0.72, cy)], col)
        return
    if kind == 1:  # 红心
        r = s * 0.52
        d.ellipse([cx - 2 * r, cy - s * 0.35 - r, cx, cy - s * 0.35 + r], fill=col)
        d.ellipse([cx, cy - s * 0.35 - r, cx + 2 * r, cy - s * 0.35 + r], fill=col)
        poly(d, [(cx - s * 0.92, cy - s * 0.1), (cx + s * 0.92, cy - s * 0.1), (cx, cy + s)], col)
        return
    if kind == 3:  # 梅花
        r = s * 0.42
        for dx, dy in ((0, -r * 1.15), (-r, r * 0.45), (r, r * 0.45)):
            d.ellipse([cx + dx - r, cy + dy - r, cx + dx + r, cy + dy + r], fill=col)
        poly(d, [(cx - s * 0.16, cy), (cx + s * 0.16, cy), (cx + s * 0.42, cy + s), (cx - s * 0.42, cy + s)], col)
        return
    # 黑桃: 倒红心 + 底座
    r = s * 0.52
    d.ellipse([cx - 2 * r, cy + s * 0.28 - r, cx, cy + s * 0.28 + r], fill=col)
    d.ellipse([cx, cy + s * 0.28 - r, cx + 2 * r, cy + s * 0.28 + r], fill=col)
    poly(d, [(cx - s * 0.92, cy + s * 0.42), (cx + s * 0.92, cy + s * 0.42), (cx, cy - s)], col)
    poly(d, [(cx - s * 0.18, cy + s * 0.3), (cx + s * 0.18, cy + s * 0.3), (cx + s * 0.45, cy + s),
             (cx - s * 0.45, cy + s)], col)


def arrow_head(d, x, y, ang, s, col):
    poly(d, rot([(x, y), (x - s, y - s * 0.6), (x - s, y + s * 0.6)], x, y, ang), col)


def load_font(size):
    for name in ("arialbd.ttf", "arial.ttf", "seguisb.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


# ------------------------------------------------------------- 图案族 ----
# 每个图案族: draw_<name>(d, cx, cy, s, col, acc, rng)
#   s = 图案半径基准, col = 主色(暖白), acc = 稀有度强调色, rng = 种子随机

def g_ring(d, cx, cy, s, col, acc, rng):
    w = int(s * 0.34)
    d.ellipse([cx - s, cy - s, cx + s, cy + s], outline=col, width=w)
    d.ellipse([cx - int(s*0.4), cy - int(s*0.4), cx + int(s*0.4), cy + int(s*0.4)], outline=acc, width=max(2, w // 3))


def g_star(d, cx, cy, s, col, acc, rng):
    poly(d, star_pts(cx, cy, s, s * 0.42, 5), col)
    poly(d, star_pts(cx, cy, s * 0.4, s * 0.17, 5, -math.pi / 2 + 0.3), acc)


def g_burst(d, cx, cy, s, col, acc, rng):
    n = 8
    for k in range(n):
        a = k * math.pi / n + rng.uniform(-0.06, 0.06)
        r0 = s * (0.35 if k % 2 else 0.5)
        r1 = s * (0.8 if k % 2 else 1.0)
        w = max(2, int(s * 0.14))
        d.line([cx + math.cos(a) * r0, cy + math.sin(a) * r0,
                cx + math.cos(a) * r1, cy + math.sin(a) * r1], fill=col, width=w)
    d.ellipse([cx - s * 0.26, cy - s * 0.26, cx + s * 0.26, cy + s * 0.26], fill=acc)


def g_rank(d, cx, cy, s, col, acc, rng, text, pip=True):
    f = load_font(int(s * (1.7 if len(text) <= 2 else 1.15 if len(text) <= 3 else 0.85)))
    d.text((cx, cy - s * 0.12), text, font=f, fill=col, anchor="mm")
    if pip:
        suit(d, cx + s * 0.62, cy + s * 0.72, s * 0.3, rng.randrange(4), acc)


def g_eye(d, cx, cy, s, col, acc, rng, badge=None):
    w, h = s, s * 0.52
    d.polygon([(cx - w, cy), (cx, cy - h), (cx + w, cy), (cx, cy + h)], outline=col)
    d.line([(cx - w, cy), (cx, cy - h), (cx + w, cy), (cx, cy + h), (cx - w, cy)], fill=col, width=max(2, int(s*0.1)))
    r = h * 0.62
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=acc)
    r2 = r * 0.45
    d.ellipse([cx - r2, cy - r2, cx + r2, cy + r2], fill=(20, 22, 28))
    if badge:
        bw, bh = s * 1.3, s * 0.56
        d.rounded_rectangle([cx - bw, cy + s * 0.75, cx + bw, cy + s * 0.75 + bh],
                            radius=bh * 0.3, fill=(20, 22, 28), outline=col, width=2)
        d.text((cx, cy + s * 0.75 + bh / 2), badge, font=load_font(int(bh * 0.66)), fill=col, anchor="mm")


def g_shield(d, cx, cy, s, col, acc, rng):
    pts = [(cx - s * 0.75, cy - s * 0.85), (cx + s * 0.75, cy - s * 0.85),
           (cx + s * 0.75, cy + s * 0.1), (cx, cy + s), (cx - s * 0.75, cy + s * 0.1)]
    poly(d, pts, col)
    poly(d, [(p[0] * 0.68 + cx * 0.32, p[1] * 0.68 + cy * 0.32) for p in pts], mix(acc, 0.85))


def g_magnet(d, cx, cy, s, col, acc, rng):
    w = int(s * 0.42)
    d.arc([cx - s, cy - s * 0.9, cx + s, cy + s * 0.9], start=180, end=360, fill=col, width=w)
    d.rectangle([cx - s, cy - s * 0.05, cx - s + w, cy + s * 0.75], fill=col)
    d.rectangle([cx + s - w, cy - s * 0.05, cx + s, cy + s * 0.75], fill=col)
    d.rectangle([cx - s, cy + s * 0.45, cx - s + w, cy + s * 0.75], fill=acc)
    d.rectangle([cx + s - w, cy + s * 0.45, cx + s, cy + s * 0.75], fill=acc)


def g_blade(d, cx, cy, s, col, acc, rng):
    ang = rng.uniform(-0.5, -0.2)
    pts = [(cx, cy - s), (cx + s * 0.22, cy - s * 0.4), (cx + s * 0.12, cy + s * 0.45),
           (cx - s * 0.12, cy + s * 0.45), (cx - s * 0.22, cy - s * 0.4)]
    poly(d, rot(pts, cx, cy, ang), col)
    gx = cx + math.sin(ang) * s * 0.55
    gy = cy + math.cos(ang) * s * 0.55
    poly(d, rot([(gx - s * 0.5, gy), (gx + s * 0.5, gy), (gx + s * 0.5, gy + s * 0.14),
                 (gx - s * 0.5, gy + s * 0.14)], gx, gy, ang), acc)
    poly(d, rot([(gx - s * 0.09, gy + s * 0.14), (gx + s * 0.09, gy + s * 0.14),
                 (gx + s * 0.09, gy + s * 0.6), (gx - s * 0.09, gy + s * 0.6)], gx, gy, ang), col)


def g_skull(d, cx, cy, s, col, acc, rng):
    d.ellipse([cx - s * 0.75, cy - s * 0.9, cx + s * 0.75, cy + s * 0.55], fill=col)
    d.rectangle([cx - s * 0.42, cy + s * 0.2, cx + s * 0.42, cy + s * 0.85], fill=col)
    for ex in (-0.34, 0.34):
        d.ellipse([cx + s * ex - s * 0.2, cy - s * 0.42, cx + s * ex + s * 0.2, cy - s * 0.02], fill=(20, 22, 28))
    poly(d, [(cx, cy - s * 0.02), (cx - s * 0.14, cy + s * 0.26), (cx + s * 0.14, cy + s * 0.26)], (20, 22, 28))
    for tx in (-0.24, 0, 0.24):
        d.rectangle([cx + s * tx - s * 0.07, cy + s * 0.55, cx + s * tx + s * 0.07, cy + s * 0.85], fill=(20, 22, 28))


def g_flame(d, cx, cy, s, col, acc, rng):
    # 外焰: 两条 S 形边围出的火苗轮廓
    left, right = [], []
    for k in range(9):
        t = k / 8
        y = cy - s + t * s * 1.95
        bulge = math.sin(t * math.pi) * s * 0.78 * (1 - 0.25 * t)
        wig = math.sin(t * math.pi * 2.2) * s * 0.1
        left.append((cx - bulge + wig, y))
        right.append((cx + bulge - wig, y))
    poly(d, left + right[::-1], col)
    # 内焰
    inner = []
    for k in range(7):
        t = k / 6
        y = cy - s * 0.35 + t * s * 1.15
        bulge = math.sin(t * math.pi) * s * 0.4
        inner.append((cx - bulge, y))
        inner.append((cx + bulge, y))
    poly(d, inner[::2] + inner[::-2], acc)


def g_lightning(d, cx, cy, s, col, acc, rng):
    pts = [(cx + s * 0.25, cy - s), (cx - s * 0.45, cy + s * 0.12), (cx + s * 0.02, cy + s * 0.12),
           (cx - s * 0.25, cy + s), (cx + s * 0.55, cy - s * 0.2), (cx + s * 0.05, cy - s * 0.2)]
    poly(d, pts, col)


def g_rainbow(d, cx, cy, s, col, acc, rng):
    hues = [(255, 90, 90), (255, 200, 70), (90, 200, 110), (90, 150, 255)]
    w = max(2, int(s * 0.16))
    for i, hue in enumerate(hues):
        r = s * (1.0 - i * 0.24)
        d.arc([cx - r, cy - r * 0.9, cx + r, cy + r * 1.5], start=200, end=340, fill=hue, width=w)
    d.ellipse([cx - s * 0.1, cy + s * 0.45 - s * 0.1, cx + s * 0.1, cy + s * 0.45 + s * 0.1], fill=col)


def g_gear(d, cx, cy, s, col, acc, rng):
    teeth = 8
    for k in range(teeth):
        a = k * 2 * math.pi / teeth
        x0, y0 = cx + math.cos(a) * s * 0.72, cy + math.sin(a) * s * 0.72
        d.ellipse([x0 - s * 0.16, y0 - s * 0.16, x0 + s * 0.16, y0 + s * 0.16], fill=col)
    d.ellipse([cx - s * 0.78, cy - s * 0.78, cx + s * 0.78, cy + s * 0.78], fill=col)
    d.ellipse([cx - s * 0.3, cy - s * 0.3, cx + s * 0.3, cy + s * 0.3], fill=(20, 22, 28))
    d.ellipse([cx - s * 0.14, cy - s * 0.14, cx + s * 0.14, cy + s * 0.14], fill=acc)


def g_balance(d, cx, cy, s, col, acc, rng):
    w = max(2, int(s * 0.12))
    d.line([cx, cy - s * 0.8, cx, cy + s * 0.7], fill=col, width=w)
    d.line([cx - s * 0.85, cy - s * 0.5, cx + s * 0.85, cy - s * 0.5], fill=col, width=w)
    for sx in (-0.85, 0.85):
        px = cx + s * sx
        d.line([px, cy - s * 0.5, px, cy - s * 0.1], fill=col, width=max(2, w - 1))
        d.pieslice([px - s * 0.34, cy - s * 0.5, px + s * 0.34, cy + s * 0.35], 0, 180, fill=acc)
    d.rectangle([cx - s * 0.4, cy + s * 0.6, cx + s * 0.4, cy + s * 0.78], fill=col)


def g_coin(d, cx, cy, s, col, acc, rng):
    d.ellipse([cx - s * 0.85, cy - s * 0.85, cx + s * 0.85, cy + s * 0.85], fill=col)
    d.ellipse([cx - s * 0.6, cy - s * 0.6, cx + s * 0.6, cy + s * 0.6], outline=mix(col, 0.55), width=2)
    poly(d, star_pts(cx, cy, s * 0.38, s * 0.16, 5), acc)
    for k in range(8):
        a = k * math.pi / 4
        x0 = cx + math.cos(a) * s * 0.72
        y0 = cy + math.sin(a) * s * 0.72
        d.rectangle([x0 - s * 0.05, y0 - s * 0.05, x0 + s * 0.05, y0 + s * 0.05], fill=mix(col, 0.5))


def g_equals(d, cx, cy, s, col, acc, rng):
    for dy in (-0.35, 0.35):
        d.rounded_rectangle([cx - s * 0.8, cy + s * dy - s * 0.16, cx + s * 0.8, cy + s * dy + s * 0.16],
                            radius=s * 0.14, fill=col if dy < 0 else acc)


def g_flush(d, cx, cy, s, col, acc, rng):
    for k in range(5):
        a = -math.pi / 2 + (k - 2) * 0.55
        px = cx + math.sin(a) * s * 0.8
        py = cy - math.cos(a) * s * 0.55 + s * 0.15
        suit(d, px, py, s * 0.24, rng.randrange(4), col if k % 2 else acc)


def g_stack(d, cx, cy, s, col, acc, rng):
    for k, (dx, dy) in enumerate(((0.18, 0.22), (-0.12, 0.1), (0, -0.05))):
        bx, by = cx + s * dx, cy + s * dy
        col_k = acc if k == 2 else mix(col, 0.75)
        d.rounded_rectangle([bx - s * 0.55, by - s * 0.75, bx + s * 0.55, by + s * 0.75],
                            radius=s * 0.12, fill=col_k, outline=(20, 22, 28), width=2)
    suit(d, cx, cy, s * 0.3, rng.randrange(4), (20, 22, 28))


def g_wand(d, cx, cy, s, col, acc, rng):
    ang = -0.6
    x0, y0 = cx - s * 0.5, cy + s * 0.85
    x1, y1 = cx + s * 0.45, cy - s * 0.55
    w = max(3, int(s * 0.18))
    d.line([x0, y0, x1, y1], fill=col, width=w)
    poly(d, star_pts(x1, y1, s * 0.42, s * 0.18, 5), acc)
    for k in range(3):
        a = rng.uniform(0, 6.28)
        px = x1 + math.cos(a) * s * 0.75
        py = y1 + math.sin(a) * s * 0.75
        d.ellipse([px - s * 0.06, py - s * 0.06, px + s * 0.06, py + s * 0.06], fill=col)


def g_waves(d, cx, cy, s, col, acc, rng):
    d.ellipse([cx - s * 0.14, cy - s * 0.14, cx + s * 0.14, cy + s * 0.14], fill=col)
    for i, r in enumerate((0.4, 0.7, 1.0)):
        w = max(2, int(s * 0.13))
        col_i = col if i < 2 else acc
        d.arc([cx - s * r, cy - s * r, cx + s * r, cy + s * r], start=-45, end=45, fill=col_i, width=w)
        d.arc([cx - s * r, cy - s * r, cx + s * r, cy + s * r], start=135, end=225, fill=col_i, width=w)


def g_hexagon(d, cx, cy, s, col, acc, rng):
    pts = [(cx + math.cos(k * math.pi / 3 - math.pi / 6) * s,
            cy + math.sin(k * math.pi / 3 - math.pi / 6) * s) for k in range(6)]
    poly(d, pts, col)
    inner = [(p[0] * 0.55 + cx * 0.45, p[1] * 0.55 + cy * 0.45) for p in pts]
    d.line(inner + [inner[0]], fill=(20, 22, 28), width=max(2, int(s * 0.1)))
    d.ellipse([cx - s * 0.14, cy - s * 0.14, cx + s * 0.14, cy + s * 0.14], fill=acc)


def g_cycle(d, cx, cy, s, col, acc, rng):
    w = max(2, int(s * 0.16))
    r = s * 0.8
    d.arc([cx - r, cy - r, cx + r, cy + r], start=210, end=330, fill=col, width=w)
    d.arc([cx - r, cy - r, cx + r, cy + r], start=30, end=150, fill=acc, width=w)
    arrow_head(d, cx + math.cos(math.radians(330)) * r, cy + math.sin(math.radians(330)) * r,
               math.radians(60), s * 0.4, col)
    arrow_head(d, cx + math.cos(math.radians(150)) * r, cy + math.sin(math.radians(150)) * r,
               math.radians(240), s * 0.4, acc)


def g_droplet(d, cx, cy, s, col, acc, rng):
    poly(d, [(cx, cy - s), (cx + s * 0.62, cy + s * 0.15), (cx + s * 0.42, cy + s * 0.75),
             (cx - s * 0.42, cy + s * 0.75), (cx - s * 0.62, cy + s * 0.15)], col)
    d.ellipse([cx - s * 0.42, cy - s * 0.1, cx + s * 0.42, cy + s * 0.75], fill=col)
    d.ellipse([cx - s * 0.2, cy + s * 0.12, cx + s * 0.05, cy + s * 0.42], fill=acc)


def g_crescent(d, cx, cy, s, col, acc, rng):
    d.ellipse([cx - s * 0.85, cy - s * 0.85, cx + s * 0.85, cy + s * 0.85], fill=col)
    d.ellipse([cx - s * 0.2, cy - s * 1.05, cx + s * 1.25, cy + s * 0.4], fill=(20, 22, 28))
    poly(d, star_pts(cx + s * 0.45, cy - s * 0.35, s * 0.22, s * 0.09, 5), acc)


def g_mask(d, cx, cy, s, col, acc, rng):
    pts = [(cx - s, cy - s * 0.3), (cx, cy - s * 0.55), (cx + s, cy - s * 0.3),
           (cx + s * 0.8, cy + s * 0.45), (cx, cy + s * 0.7), (cx - s * 0.8, cy + s * 0.45)]
    poly(d, pts, col)
    for ex in (-0.42, 0.42):
        d.polygon([(cx + s * ex - s * 0.26, cy - s * 0.12), (cx + s * ex + s * 0.26, cy - s * 0.18),
                   (cx + s * ex + s * 0.2, cy + s * 0.16), (cx + s * ex - s * 0.2, cy + s * 0.16)], fill=(20, 22, 28))
    d.line([(cx - s, cy - s * 0.3), (cx + s, cy - s * 0.3)], fill=acc, width=max(2, int(s * 0.08)))


def g_vortex(d, cx, cy, s, col, acc, rng):
    pts = []
    for k in range(46):
        t = k / 45
        a = t * 4.2 * math.pi
        r = s * (0.12 + 0.85 * t)
        pts.append((cx + math.cos(a) * r, cy + math.sin(a) * r))
    d.line(pts, fill=col, width=max(2, int(s * 0.12)), joint="curve")
    d.ellipse([cx - s * 0.14, cy - s * 0.14, cx + s * 0.14, cy + s * 0.14], fill=acc)


def g_banner(d, cx, cy, s, col, acc, rng):
    poly(d, [(cx - s * 0.7, cy - s * 0.8), (cx + s * 0.7, cy - s * 0.8),
             (cx + s * 0.7, cy + s * 0.5), (cx, cy + s * 0.85), (cx - s * 0.7, cy + s * 0.5)], col)
    poly(d, [(cx - s * 0.7, cy - s * 0.8), (cx + s * 0.7, cy - s * 0.8),
             (cx + s * 0.7, cy - s * 0.55), (cx - s * 0.7, cy - s * 0.55)], acc)


# id 关键词 -> 图案族（顺序即优先级，首条命中生效）
FAMILY_RULES = [
    (r"black_hole",              lambda *a: g_vortex(*a)),
    (r"ring",                    g_ring),
    (r"ace",                     None),  # rank 族（字母 A），见下方特判
    (r"reveal",                  None),  # eye 族 + 数字徽章
    (r"mirror|swap|reverse|backflow|salvager|discard(?!_rinse)", g_cycle),
    (r"shield|safe|insurance|buster|anti|evidence|guard|save", g_shield),
    (r"magnet",                  g_magnet),
    (r"eye|sight|peek|probe|sniffer|mind|memory|blind|cheat", g_eye),
    (r"thief|face",              g_mask),
    (r"killer|sharp",            g_blade),
    (r"curse|coward",            g_skull),
    (r"burn|flame",              g_flame),
    (r"streak|hammer",           g_lightning),
    (r"rainbow",                 g_rainbow),
    (r"clockwork",               g_gear),
    (r"scales|justice",          g_balance),
    (r"rinse",                   g_droplet),
    (r"bet|chip|money|credit|fund|roller|jackpot|debt|steal|syndicate|all_in", g_coin),
    (r"flush",                   g_flush),
    (r"king|royalty|supreme|master|consort|fanatic|champion", g_banner),
    (r"charm|blessing|divine",   g_star),
    (r"deck|pack",               g_stack),
    (r"rod",                     g_wand),
    (r"mobile|network|signal",   g_waves),
    (r"seclusion",               g_hexagon),
    (r"survivor|stage",          g_banner),
    (r"fatigue",                 g_crescent),
    (r"super|mult|boost|buff",   g_burst),
    (r"surrender|push(?!_as)|tie", g_equals),
    (r"\d|seven|eight|ten|pair|give_card", None),  # rank 族（数字），见下方特判
]
FALLBACK = g_hexagon


def resolve_family(rid):
    """返回 (绘制函数族名, 附加参数)。特判 rank / eye-badge 两类需要文本。"""
    for pat, fn in FAMILY_RULES:
        if re.search(pat, rid):
            if pat == r"ace":
                return ("rank", "A")
            if pat == r"reveal":
                digits = re.findall(r"\d+", rid)
                return ("rank", None)  # reveal 走 eye+徽章
            if pat == r"\d|seven|eight|ten|pair|give_card":
                named = {"seven": "7", "eight": "8", "ten": "10"}
                for w, v in named.items():
                    if w in rid:
                        return ("rank", v)
                digits = re.findall(r"\d+", rid)
                if digits:
                    joined = "-".join(digits) if len(digits) > 1 else digits[0]
                    return ("rank", joined)
                return ("rank", "?")
            return (fn, None)
    return (FALLBACK, None)


# ------------------------------------------------------------- 组装 ----

def draw_relic(rid, rarity):
    base = RARITY_RGB.get(rarity, RARITY_RGB["common"])
    rng = random.Random(hashlib.md5(rid.encode()).hexdigest())
    W, H = FRAME_W * SS, FRAME_H * SS
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # 面板: 稀有度暗色底（与游戏内兜底背景同源） + 稀有度描边
    bg = mix(base, 0.30)
    d.rounded_rectangle([0, 0, W - 1, H - 1], radius=6 * SS, fill=bg + (255,))
    # 顶部微光与底部暗角，避免大色块过平
    d.rounded_rectangle([3 * SS, 3 * SS, W - 3 * SS, int(H * 0.45)], radius=5 * SS,
                        fill=mix(base, 0.36) + (255,))
    d.rounded_rectangle([3 * SS, int(H * 0.45), W - 3 * SS, H - 3 * SS], radius=5 * SS,
                        fill=mix(base, 0.25) + (255,))
    d.rounded_rectangle([0, 0, W - 1, H - 1], radius=6 * SS, outline=base + (255,), width=2 * SS)

    # 图案主色（暖白）与微色相扰动，保证同族图案也有差异
    jitter = rng.randint(-14, 14)
    col = (238 + jitter // 2, 234 + jitter // 3, 222 - jitter // 2)
    acc = mix(base, 0.95)
    cx, cy = W / 2, H * 0.46
    s = W * 0.30

    fam, extra = resolve_family(rid)
    if fam == "rank":
        if extra is None:  # reveal: 眼睛 + 数字徽章
            digits = "-".join(re.findall(r"\d+", rid))
            g_eye(d, cx, cy - H * 0.04, s * 0.92, col, acc, rng, badge=digits)
        else:
            g_rank(d, cx, cy + H * 0.02, s * 1.05, col, acc, rng, extra)
    else:
        fam(d, cx, cy, s * 1.15, col, acc, rng)

    # 角落点缀: 0~3 颗小方点（种子决定位置），增强辨识度
    for _ in range(rng.randrange(4)):
        px = rng.choice((7 * SS, W - 7 * SS))
        py = rng.choice((7 * SS, H - 7 * SS))
        d.rectangle([px - SS, py - SS, px + SS, py + SS], fill=mix(base, 0.8) + (255,))

    return img.resize((FRAME_W, FRAME_H), Image.LANCZOS)


def build_preview(tiles):
    cols, cell_w, cell_h, label_h = 10, FRAME_W + 22, FRAME_H + 8, 16
    rows = (len(tiles) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell_w + 8, rows * (cell_h + label_h) + 8), (24, 26, 32))
    d = ImageDraw.Draw(sheet)
    f = load_font(9)
    for k, (rid, tile) in enumerate(tiles):
        x = 8 + (k % cols) * cell_w + 11
        y = 8 + (k // cols) * (cell_h + label_h)
        sheet.paste(tile, (x, y), tile)
        d.text((x + FRAME_W / 2, y + FRAME_H + 2), rid[:14], font=f, fill=(200, 200, 200), anchor="ma")
    return sheet


def main():
    only_preview = "--preview" in sys.argv
    entries = parse_relics()
    targets = [(rid, r) for rid, r, has_icon in entries if has_icon]
    ids = [rid for rid, _ in targets]
    dup = {i for i in ids if ids.count(i) > 1}
    assert not dup, "重复 id: %s" % dup
    print("解析到 %d 件遗物，其中 %d 件需要图标" % (len(entries), len(targets)))

    if not only_preview:
        os.makedirs(OUT_DIR, exist_ok=True)
    tiles = []
    for rid, rarity in targets:
        tile = draw_relic(rid, rarity)
        tiles.append((rid, tile))
        if not only_preview:
            tile.save(os.path.join(OUT_DIR, rid + ".png"))
    sheet = build_preview(tiles)
    sheet.save(PREVIEW)
    print("预览拼图: %s" % os.path.relpath(PREVIEW, ROOT))
    if not only_preview:
        print("图标目录: %s (%d 张)" % (os.path.relpath(OUT_DIR, ROOT), len(targets)))


if __name__ == "__main__":
    main()
