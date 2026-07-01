#!/usr/bin/env python3
"""frames.py — нарисовать device-рамку с chroma-green экраном на стилевом фоне.

Ветка A мокапов: вместо фото-рамок рисуем чистое устройство в PIL, экран = #00FF00.
Дальше frame-composite.py --mode green вставит реальный скриншот. Один путь вставки
для веток A (эта рамка) и C (Recraft-сцена).

Устройства: browser | iphone | ipad | macbook.
Экран всегда осевой прямоугольник → green-детект вернёт точные углы (пиксель-в-пиксель).

Usage:
  frames.py --device browser --shot-w 1440 --shot-h 900 --out frame.png \
      [--bg "#0f1420,#1b2436"] [--accent "#c9302c"] [--pad 120] [--scale 1.0]
"""
import sys, json, argparse
from PIL import Image, ImageDraw

GREEN = (0, 255, 0)


def die(m, code=1):
    print(json.dumps({"ok": False, "error": m}, ensure_ascii=False)); sys.exit(code)


def hex2rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def gradient(size, c1, c2):
    w, h = size
    base = Image.new("RGB", size, c1)
    top = Image.new("RGB", size, c2)
    mask = Image.new("L", (1, h))
    for y in range(h):
        mask.putpixel((0, y), int(255 * y / max(1, h - 1)))
    base.paste(top, (0, 0), mask.resize(size))
    return base


def rrect(draw, box, r, fill):
    draw.rounded_rectangle(box, radius=r, fill=fill)


def draw_browser(shot_w, shot_h, bg, accent, pad, scale):
    # окно браузера: топбар + контент (green)
    sw, sh = int(shot_w * scale), int(shot_h * scale)
    bar = max(34, sh // 22)
    win_w, win_h = sw, sh + bar
    W, H = win_w + pad * 2, win_h + pad * 2
    img = gradient((W, H), bg[0], bg[1] if len(bg) > 1 else bg[0])
    d = ImageDraw.Draw(img)
    x0, y0 = pad, pad
    # корпус окна
    rrect(d, [x0, y0, x0 + win_w, y0 + win_h], 16, (245, 246, 248))
    # топбар
    rrect(d, [x0, y0, x0 + win_w, y0 + bar], 16, (228, 230, 234))
    d.rectangle([x0, y0 + bar - 16, x0 + win_w, y0 + bar], fill=(228, 230, 234))
    dot_r = max(5, bar // 6)
    cy = y0 + bar // 2
    for i, col in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        cx = x0 + 20 + i * (dot_r * 2 + 8)
        d.ellipse([cx, cy - dot_r, cx + dot_r * 2, cy + dot_r], fill=col)
    # адресная строка
    ab_x = x0 + 20 + 3 * (dot_r * 2 + 8) + 16
    rrect(d, [ab_x, cy - dot_r - 2, x0 + win_w - 20, cy + dot_r + 2], bar // 3, (255, 255, 255))
    # экран (green)
    scr = [x0, y0 + bar, x0 + win_w, y0 + win_h]
    d.rectangle(scr, fill=GREEN)
    return img


def draw_phone(shot_w, shot_h, bg, accent, pad, scale, tablet=False):
    sw, sh = int(shot_w * scale), int(shot_h * scale)
    bez = max(14, sw // (28 if not tablet else 40))
    corner = bez * 2 if not tablet else bez
    body_w, body_h = sw + bez * 2, sh + bez * 2
    W, H = body_w + pad * 2, body_h + pad * 2
    img = gradient((W, H), bg[0], bg[1] if len(bg) > 1 else bg[0])
    d = ImageDraw.Draw(img)
    x0, y0 = pad, pad
    rrect(d, [x0, y0, x0 + body_w, y0 + body_h], corner + bez, (18, 18, 20))  # корпус
    scr = [x0 + bez, y0 + bez, x0 + bez + sw, y0 + bez + sh]
    d.rectangle(scr, fill=GREEN)
    if not tablet:
        # dynamic island
        iw, ih = sw // 3, max(10, bez)
        ix = x0 + bez + sw // 2 - iw // 2
        iy = y0 + bez + max(6, sh // 60)
        rrect(d, [ix, iy, ix + iw, iy + ih], ih // 2, (12, 12, 14))
    else:
        # камера-точка сверху
        r = max(4, bez // 3)
        cx = x0 + bez + sw // 2
        d.ellipse([cx - r, y0 + bez // 2 - r, cx + r, y0 + bez // 2 + r], fill=(60, 60, 66))
    return img


def draw_macbook(shot_w, shot_h, bg, accent, pad, scale):
    sw, sh = int(shot_w * scale), int(shot_h * scale)
    bez = max(12, sw // 40)
    lid_w, lid_h = sw + bez * 2, sh + bez * 2
    base_h = max(16, lid_h // 22)
    W = lid_w + pad * 2
    H = lid_h + base_h + pad * 2
    img = gradient((W, H), bg[0], bg[1] if len(bg) > 1 else bg[0])
    d = ImageDraw.Draw(img)
    x0, y0 = pad, pad
    rrect(d, [x0, y0, x0 + lid_w, y0 + lid_h], 14, (28, 28, 30))  # крышка
    scr = [x0 + bez, y0 + bez, x0 + bez + sw, y0 + bez + sh]
    d.rectangle(scr, fill=GREEN)
    # камера
    r = max(3, bez // 4)
    cx = x0 + lid_w // 2
    d.ellipse([cx - r, y0 + bez // 2 - r, cx + r, y0 + bez // 2 + r], fill=(55, 55, 60))
    # основание/клавиатурная база (трапеция-намёк)
    by = y0 + lid_h
    over = max(30, lid_w // 12)
    d.polygon([(x0 - over, by + base_h), (x0 + lid_w + over, by + base_h),
               (x0 + lid_w, by), (x0, by)], fill=(200, 202, 206))
    # вырез под палец
    nw = lid_w // 6
    d.rectangle([cx - nw // 2, by, cx + nw // 2, by + base_h // 3], fill=(170, 172, 176))
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", required=True,
                    choices=["browser", "iphone", "ipad", "macbook"])
    ap.add_argument("--shot-w", type=int, required=True)
    ap.add_argument("--shot-h", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--bg", default="#0f1420,#1b2436")
    ap.add_argument("--accent", default="#c9302c")
    ap.add_argument("--pad", type=int, default=120)
    ap.add_argument("--scale", type=float, default=1.0)
    a = ap.parse_args()
    bg = [hex2rgb(c) for c in a.bg.split(",")]
    accent = hex2rgb(a.accent)
    if a.shot_w <= 0 or a.shot_h <= 0:
        die("shot dimensions must be positive", 5)
    try:
        if a.device == "browser":
            img = draw_browser(a.shot_w, a.shot_h, bg, accent, a.pad, a.scale)
        elif a.device == "iphone":
            img = draw_phone(a.shot_w, a.shot_h, bg, accent, a.pad, a.scale, tablet=False)
        elif a.device == "ipad":
            img = draw_phone(a.shot_w, a.shot_h, bg, accent, a.pad, a.scale, tablet=True)
        else:
            img = draw_macbook(a.shot_w, a.shot_h, bg, accent, a.pad, a.scale)
        img.save(a.out)
    except Exception as e:
        die(f"draw failed: {e}", 2)
    print(json.dumps({"ok": True, "out": a.out, "device": a.device}, ensure_ascii=False))


if __name__ == "__main__":
    main()
