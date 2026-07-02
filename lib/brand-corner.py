#!/usr/bin/env python3
"""Stamp a subtle RedLoft brand mark in a corner (replaces watermark idea).
Usage: brand-corner.py <in.png> <mark.svg> <out.png> [corner=br] [frac=0.07] [opacity=0.5]
"""
import sys
import numpy as np
import cairosvg
from io import BytesIO
from PIL import Image

src, svg_p, out_p = sys.argv[1], sys.argv[2], sys.argv[3]
corner = sys.argv[4] if len(sys.argv) > 4 else "br"
frac = float(sys.argv[5]) if len(sys.argv) > 5 else 0.07
op = float(sys.argv[6]) if len(sys.argv) > 6 else 0.5

img = Image.open(src).convert("RGB")
W, H = img.size
mw = int(W * frac)

# пробный растр (белым) → узнать пропорции знака и позицию
probe = Image.open(BytesIO(cairosvg.svg2png(
    bytestring=open(svg_p).read().replace("currentColor", "#ffffff").encode(),
    output_width=mw * 3))).convert("RGBA")
mh = int(probe.height * mw / probe.width)
if mh > H:                         # знак выше кадра — ужать
    print(f"brand: mark taller than frame ({mh}>{H}), shrinking to fit")
    mw = int(mw * (H / mh)); mh = H
pad = int(W * 0.035)
pos = {"br": (W - mw - pad, H - mh - pad), "bl": (pad, H - mh - pad),
       "tr": (W - mw - pad, pad), "tl": (pad, pad)}[corner]

# авто-цвет знака по яркости фона под меткой (белый на тёмном, тёмный на светлом)
rx, ry = max(0, pos[0]), max(0, pos[1])
s = np.asarray(img.crop((rx, ry, min(W, rx + mw), min(H, ry + mh))), dtype=np.float32)
bg_luma = float((0.299 * s[..., 0] + 0.587 * s[..., 1] + 0.114 * s[..., 2]).mean())
ink = "#ffffff" if bg_luma < 140 else "#1a1a1a"
print(f"brand: bg luma {bg_luma:.0f} → ink {ink}")

svg = open(svg_p).read().replace("currentColor", ink)
png = cairosvg.svg2png(bytestring=svg.encode(), output_width=mw * 3)
mark = Image.open(BytesIO(png)).convert("RGBA").resize((mw, mh), Image.LANCZOS)

layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
m2 = mark.copy()
alpha = np.asarray(m2)[..., 3].astype(np.float32) * op
m2.putalpha(Image.fromarray(alpha.astype(np.uint8)))
layer.paste(m2, pos, m2)
out = Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")
out.save(out_p)
print("brand mark", corner, "@", pos, "size", mw, "x", mh, "->", out_p)
