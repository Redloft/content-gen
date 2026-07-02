#!/usr/bin/env python3
"""quad-warp.py — перспективный варп скриншота в заданный квад на прозрачной канве.
Для гибридного рендера чужих PSD: квад = placedLayer.transform из psd-so-swap.mjs dims.

Usage: quad-warp.py <shot.png> <doc_w> <doc_h> '<quad8-json>' <out.png>
quad8 = [x1,y1, x2,y2, x3,y3, x4,y4] (TL, TR, BR, BL) — как в PSD transform.
"""
import json
import sys

import numpy as np
from PIL import Image, ImageDraw


def find_coeffs(dst, src):
    A = []
    for (X, Y), (x, y) in zip(dst, src):
        A.append([x, y, 1, 0, 0, 0, -X * x, -X * y])
        A.append([0, 0, 0, x, y, 1, -Y * x, -Y * y])
    A = np.asarray(A, dtype=float)
    B = np.asarray([c for p in dst for c in p], dtype=float)
    return np.linalg.solve(A, B)


def main():
    shot_p, W, H, quad_s, out_p = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
    q = json.loads(quad_s)
    quad = [(q[0], q[1]), (q[2], q[3]), (q[4], q[5]), (q[6], q[7])]

    shot = Image.open(shot_p).convert("RGBA")
    sw, sh = shot.size

    # PIL PERSPECTIVE: коэффициенты отображают ВЫХОДНЫЕ координаты в координаты исходника.
    # Вырожденный quad (коллинеарные/дублирующиеся точки) → LinAlgError, ловим ниже.
    coeffs = find_coeffs([(0, 0), (sw, 0), (sw, sh), (0, sh)], quad)
    canvas = shot.transform((W, H), Image.PERSPECTIVE, tuple(coeffs), Image.BICUBIC)

    # 4x-суперсэмпл маска квада для гладкой AA-кромки
    SS = 4
    mask_big = Image.new("L", (W * SS, H * SS), 0)
    ImageDraw.Draw(mask_big).polygon([(x * SS, y * SS) for x, y in quad], fill=255)
    mask = mask_big.resize((W, H), Image.LANCZOS)

    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    out.paste(canvas, (0, 0), mask)
    out.save(out_p)
    print(json.dumps({"ok": True, "out": out_p, "size": [W, H]}))


if __name__ == "__main__":
    try:
        main()
    except (np.linalg.LinAlgError, ValueError, IndexError, OSError) as e:
        # единый stdout-JSON контракт с соседними lib-скриптами (не Python traceback на stderr)
        print(json.dumps({"ok": False, "error": f"{type(e).__name__}: {e}"}))
        sys.exit(2)
