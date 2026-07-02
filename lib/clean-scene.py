#!/usr/bin/env python3
"""Cleanup v3 for ref51-scene-v2:
- erase garbled bezel text stroke-by-stroke (median inpaint), draw rotated RedLoft
- output junk-mask.png (icons etc on the green) for the composite step to
  neutralize in the LIGHT MAP (scene pixels stay untouched — insert covers them)
Usage: clean-scene-v3.py <in.png> <out.png> <junkmask.png>
"""
import sys, os, math
import numpy as np
from PIL import Image, ImageFilter, ImageDraw, ImageFont

sys.path.insert(0, os.path.expanduser("~/.claude/skills/content-gen/lib"))
import importlib.util
spec = importlib.util.spec_from_file_location(
    "fc", os.path.expanduser("~/.claude/skills/content-gen/lib/frame-composite.py"))
fc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fc)

src_p, out_p, junk_p = sys.argv[1], sys.argv[2], sys.argv[3]
img = Image.open(src_p).convert("RGB")
W, H = img.size
a = np.asarray(img, dtype=np.float32)
quad = fc.detect_green_quad(img, 0.02)

# --- junk mask: non-chroma marks inside the screen ---------------------------
poly = Image.new("L", (W, H), 0)
ImageDraw.Draw(poly).polygon([tuple(p) for p in quad], fill=255)
poly_in = np.asarray(poly.filter(ImageFilter.MinFilter(7)), dtype=np.float32) > 128
r, g, b = a[..., 0], a[..., 1], a[..., 2]
junk = poly_in & ~((g - r > 30) & (g - b > 30))
jm = Image.fromarray((junk * 255).astype(np.uint8))
jm = jm.filter(ImageFilter.MaxFilter(11)).filter(ImageFilter.MaxFilter(11))
jm.save(junk_p)
print("junk px:", int((np.asarray(jm) > 128).sum()))

# --- bezel badge: erase strokes, draw RedLoft --------------------------------
(brx, bry), (blx, bly_) = quad[2], quad[3]
edge_ang = math.degrees(math.atan2(bry - bly_, brx - blx))
lum = 0.299 * r + 0.587 * g + 0.114 * b
sat = a.max(-1) - a.min(-1)
yy, xx = np.mgrid[0:H, 0:W]
edge_y = bly_ + np.clip((xx - blx) / ((brx - blx) or 1), 0, 1) * (bry - bly_)
bg = np.asarray(Image.fromarray(np.uint8(np.clip(lum, 0, 255))).filter(
    ImageFilter.MedianFilter(15)), dtype=np.float32)
textm = ((yy > edge_y + 5) & (yy < edge_y + 90)
         & (lum > 130) & (sat < 60) & (bg < 95))
textm[:, :W // 4] = False
textm[:, (3 * W) // 4:] = False
ys, xs = np.where(textm)
img2 = img
if len(xs) > 50:
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
    print("badge strokes bbox:", x0, y0, x1, y1)
    tm = Image.fromarray((textm * 255).astype(np.uint8)).filter(
        ImageFilter.MaxFilter(9)).filter(ImageFilter.GaussianBlur(1.5))
    tmn = np.asarray(tm, dtype=np.float32)[..., None] / 255.0
    med = np.asarray(img.filter(ImageFilter.MedianFilter(31)), dtype=np.float32)
    a2 = a * (1 - tmn) + med * tmn
    img2 = Image.fromarray(np.uint8(np.clip(a2, 0, 255)))
    # новый логотип: высота ~ высоте штрихов (перпендикулярно ребру)
    stroke_h = int((y1 - y0) - abs(math.tan(math.radians(edge_ang))) * (x1 - x0))
    th = max(18, min(60, int(stroke_h * 0.9)))
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", th)  # macOS
    except OSError:
        try:
            font = ImageFont.truetype("DejaVuSans.ttf", th)
        except OSError:
            print('{"warn":"no scalable font found, using bitmap default"}')
            font = ImageFont.load_default()
    tb = ImageDraw.Draw(img2).textbbox((0, 0), "RedLoft", font=font)
    tw_, th_ = tb[2] - tb[0], tb[3] - tb[1]
    txt = Image.new("RGBA", (tw_ + 20, th_ + 20), (0, 0, 0, 0))
    ImageDraw.Draw(txt).text((10 - tb[0], 10 - tb[1]), "RedLoft",
                             fill=(222, 220, 216, 225), font=font)
    txt = txt.rotate(-edge_ang, expand=True, resample=Image.BICUBIC)
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
    img2.paste(txt, (int(cx - txt.width / 2), int(cy - txt.height / 2)), txt)
    print("RedLoft drawn @", cx, cy, "th", th, "angle", round(edge_ang, 1))
else:
    print("badge not found — skipped")

img2.save(out_p)
print("saved:", out_p)
