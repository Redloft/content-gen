#!/usr/bin/env python3
"""screencast-frame-alpha.py — рамка frames.py (green-экран) → RGBA с прозрачным окном.

Для видео-мокапов (/content-screencast): вместо вклейки скриншота (frame-composite.py)
нам нужно ПРОЗРАЧНОЕ окно в рамке — pan-видео подкладывается ffmpeg'ом снизу.
Экран frames.py — осевой ярко-зелёный прямоугольник → детект тривиальный.

Usage:
  screencast-frame-alpha.py --frame frame.png --out frame-rgba.png
stdout: JSON {ok, screen:{x,y,w,h}, canvas:{w,h}}  (координаты окна для ffmpeg overlay)
"""
import sys, json, argparse
from PIL import Image, ImageChops, ImageFilter, ImageDraw


def die(m, code=1):
    print(json.dumps({"ok": False, "error": m}, ensure_ascii=False)); sys.exit(code)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frame", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    try:
        img = Image.open(a.frame).convert("RGB")
    except Exception as e:
        die(f"cannot open frame: {e}")

    # маска чистого green-экрана (как в frame-composite.py, но осевой bbox достаточно)
    r, g, b = img.split()
    gr = ImageChops.subtract(g, r).point(lambda v: 255 if v > 40 else 0)
    gb = ImageChops.subtract(g, b).point(lambda v: 255 if v > 40 else 0)
    gg = g.point(lambda v: 255 if v > 130 else 0)
    mask = ImageChops.multiply(ImageChops.multiply(gr, gb), gg)

    # мелкие зелёные элементы (точка «светофора» топбара, dot_r~6px) загрязняют bbox:
    # эрозия MinFilter(15) убивает всё мельче ~15px, экран (сотни px) выживает
    eroded = mask.filter(ImageFilter.MinFilter(15))
    ebox = eroded.getbbox()
    if not ebox:
        die("no green screen detected in frame")
    W, H = img.size
    # компенсируем эрозию (+7px) и уточняем по оригинальной маске в этом регионе
    ex0, ey0, ex1, ey1 = (max(0, ebox[0] - 7), max(0, ebox[1] - 7),
                          min(W, ebox[2] + 7), min(H, ebox[3] + 7))
    region = mask.crop((ex0, ey0, ex1, ey1))
    rbox = region.getbbox()
    if not rbox:
        die("green screen lost after refine")
    x0, y0, x1, y1 = ex0 + rbox[0], ey0 + rbox[1], ex0 + rbox[2], ey0 + rbox[3]
    w, h = x1 - x0, y1 - y0
    if w * h < 0.01 * W * H:
        die(f"green area too small: {w}x{h} on {W}x{H}")

    # RGBA: альфа=0 только по маске ВНУТРИ найденного экрана (скругления сохраняются,
    # посторонняя зелень вне bbox остаётся непрозрачной)
    rgba = img.convert("RGBA")
    keep = Image.new("L", (W, H), 0)
    ImageDraw.Draw(keep).rectangle([x0, y0, x1 - 1, y1 - 1], fill=255)
    screen_mask = ImageChops.multiply(mask, keep)
    alpha = screen_mask.point(lambda v: 0 if v else 255)
    rgba.putalpha(alpha)
    rgba.save(a.out)

    print(json.dumps({"ok": True,
                      "screen": {"x": x0, "y": y0, "w": w, "h": h},
                      "canvas": {"w": W, "h": H}}, ensure_ascii=False))


if __name__ == "__main__":
    main()
