#!/usr/bin/env python3
"""palette.py — доминирующие цвета изображения (для стиля мокапов, ветка C фон + рамки).

Usage: palette.py <image> [--n 5]
stdout: JSON {ok, colors:["#rrggbb",...], dark: bool}
"""
import sys, json
from PIL import Image


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"ok": False, "error": "usage: palette.py <image> [--n N]"})); sys.exit(1)
    img_path = sys.argv[1]
    n = 5
    if "--n" in sys.argv:
        n = int(sys.argv[sys.argv.index("--n") + 1])
    try:
        im = Image.open(img_path).convert("RGB")
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)})); sys.exit(2)
    im.thumbnail((200, 200))
    q = im.quantize(colors=max(2, n * 2), method=Image.FASTOCTREE)
    pal = q.getpalette()
    counts = sorted(q.getcolors(), reverse=True)  # [(count, idx), ...]
    colors = []
    lum_sum = 0.0
    for cnt, idx in counts[:n]:
        r, g, b = pal[idx * 3:idx * 3 + 3]
        colors.append("#%02x%02x%02x" % (r, g, b))
        lum_sum += (0.2126 * r + 0.7152 * g + 0.0722 * b) * cnt
    total = sum(c for c, _ in counts[:n]) or 1
    dark = (lum_sum / total) < 110
    print(json.dumps({"ok": True, "colors": colors, "dark": dark}))


if __name__ == "__main__":
    main()
