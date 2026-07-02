#!/usr/bin/env python3
"""Deterministic brand tattoo: rasterize the real RedLoft mark SVG and blend it
into skin (multiply + soft edge), rotated along the limb.
Usage: tattoo.py <in.png> <svg> <out.png> <cx> <cy> <width_px> <angle_deg> [ink_opacity=0.62]
"""
import sys
import numpy as np
import cairosvg
from io import BytesIO
from PIL import Image, ImageFilter

src, svg_p, out_p = sys.argv[1], sys.argv[2], sys.argv[3]
cx, cy, wpx, ang = int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]), float(sys.argv[7])
op = float(sys.argv[8]) if len(sys.argv) > 8 else 0.62

img = Image.open(src).convert("RGB")
W, H = img.size
if wpx > W:                        # cap: знак не шире кадра (защита от гигантского массива)
    print(f"tattoo: wpx {wpx} > image width {W}, capping"); wpx = W

svg = open(svg_p).read().replace("currentColor", "#0a2418")  # тёмно-зелёные чернила
png = cairosvg.svg2png(bytestring=svg.encode(), output_width=wpx * 3)
mark = Image.open(BytesIO(png)).convert("RGBA")
mark = mark.resize((wpx, int(mark.height * wpx / mark.width)), Image.LANCZOS)
mark = mark.rotate(ang, expand=True, resample=Image.BICUBIC)
mark = mark.filter(ImageFilter.GaussianBlur(0.7))  # чернила чуть расплываются в коже
mw, mh = mark.size

# clamp позиции внутрь кадра — иначе crop добивает out-of-range ЧЁРНЫМ (0,0,0)
# и multiply-бленд рисует тату по чёрному вместо кожи (тихая порча у кромок)
x0 = min(max(0, cx - mw // 2), max(0, W - mw))
y0 = min(max(0, cy - mh // 2), max(0, H - mh))
# если знак крупнее кадра по стороне — обрежем и знак, и его альфу синхронно
cw, ch = min(mw, W), min(mh, H)
mark = mark.crop((0, 0, cw, ch))

region = img.crop((x0, y0, x0 + cw, y0 + ch))
reg = np.asarray(region, dtype=np.float32)
mk = np.asarray(mark, dtype=np.float32)
alpha = (mk[..., 3:4] / 255.0) * op
ink = mk[..., :3]
# multiply: чернила умножают кожу (свет/фактура кожи остаются сверху)
mult = reg * (ink / 255.0)
blended = reg * (1 - alpha) + mult * alpha
img.paste(Image.fromarray(np.uint8(np.clip(blended, 0, 255))), (x0, y0))
img.save(out_p)
print("tattoo at", cx, cy, "w", wpx, "angle", ang, "clamped-to", (x0, y0), "->", out_p)
