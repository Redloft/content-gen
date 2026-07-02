#!/usr/bin/env python3
"""frame-composite.py — единый движок вставки скриншота в экран мокапа.

Два режима источника «экрана»:
  --mode green : детектировать chroma-green прямоугольник в сцене (ветка C, Recraft-сцены)
  --mode quad  : взять явные 4 угла экрана (ветка A, SVG-рамки из frames.json)

Скриншот перспективно вписывается в найденный/заданный четырёхугольник.
Только PIL (без numpy/cv2). Контракт ошибок: JSON в stdout, ненулевой exit.

Usage:
  frame-composite.py --scene scene.png --shot shot.png --out out.png --mode green
  frame-composite.py --scene frame.png --shot shot.png --out out.png --mode quad \
      --quad "x0,y0,x1,y1,x2,y2,x3,y3"   # порядок TL,TR,BR,BL в пикселях сцены
  [--radius N]        # скруглить углы вставки (для плоских рамок), px
  [--fit cover|contain] (default cover)
  [--min-area-frac F] # мин. доля площади зелёного от кадра (default 0.01), иначе fail
"""
import sys, json, argparse
from PIL import Image, ImageChops, ImageDraw, ImageFilter


def die(msg, code=1, **extra):
    print(json.dumps({"ok": False, "error": msg, **extra}, ensure_ascii=False))
    sys.exit(code)


def ok(**data):
    print(json.dumps({"ok": True, **data}, ensure_ascii=False))
    sys.exit(0)


def detect_green_quad(scene, min_area_frac):
    """Найти САМУЮ КРУПНУЮ СВЯЗНУЮ chroma-green область (не все зелёные пиксели —
    иначе растения/блики в фоне уводят углы), вернуть 4 угла (TL,TR,BR,BL).

    Порог жёсткий: экран — яркий #00FF00 (G высокий, R и B низкие); листья/трава
    (муты, желтее) отсекаются.
    """
    r, g, b = scene.split()
    # умеренный порог: ловит и чистый #00FF00 (рамки A), и мягкий Recraft-зелёный
    # (~114,188,101). Разделение экрана и листвы/бликов — на connected-component ниже.
    gr = ImageChops.subtract(g, r).point(lambda v: 255 if v > 40 else 0)   # G > R
    gb = ImageChops.subtract(g, b).point(lambda v: 255 if v > 40 else 0)   # G > B
    gg = g.point(lambda v: 255 if v > 130 else 0)                          # достаточно ярко
    mask = ImageChops.multiply(ImageChops.multiply(gr, gb), gg)
    W, H = mask.size
    px = mask.load()

    # связные компоненты (итеративный flood fill по зелёным пикселям), берём крупнейшую
    visited = bytearray(W * H)
    best = None  # (size, [pixels-extents])
    best_size = 0
    for y0 in range(H):
        row = y0 * W
        for x0 in range(W):
            if px[x0, y0] and not visited[row + x0]:
                stack = [(x0, y0)]
                visited[row + x0] = 1
                size = 0
                smin = dmin = 10 ** 9; smax = dmax = -10 ** 9
                tl = tr = br = bl = None
                while stack:
                    x, y = stack.pop()
                    size += 1
                    s = x + y; d = x - y
                    if s < smin: smin, tl = s, (x, y)
                    if s > smax: smax, br = s, (x, y)
                    if d > dmax: dmax, tr = d, (x, y)
                    if d < dmin: dmin, bl = d, (x, y)
                    for nx, ny in ((x+1,y),(x-1,y),(x,y+1),(x,y-1)):
                        if 0 <= nx < W and 0 <= ny < H:
                            idx = ny * W + nx
                            if px[nx, ny] and not visited[idx]:
                                visited[idx] = 1
                                stack.append((nx, ny))
                if size > best_size:
                    best_size = size
                    best = [tl, tr, br, bl]

    if best is None or best_size < min_area_frac * W * H:
        die("green-screen not found (largest region too small / absent)",
            code=3, green_px=best_size, frame_px=W * H)
    return best


def perspective_coeffs(src, dst):
    """8 коэффициентов PIL PERSPECTIVE (Gauss, без numpy). src/dst: [(x,y)*4]."""
    A, B = [], []
    for (xs, ys), (xd, yd) in zip(src, dst):
        A.append([xd, yd, 1, 0, 0, 0, -xs * xd, -xs * yd]); B.append(xs)
        A.append([0, 0, 0, xd, yd, 1, -ys * xd, -ys * yd]); B.append(ys)
    M = [row[:] + [B[i]] for i, row in enumerate(A)]
    N = 8
    for c in range(N):
        piv = max(range(c, N), key=lambda r: abs(M[r][c]))
        M[c], M[piv] = M[piv], M[c]
        if abs(M[c][c]) < 1e-9:
            die("degenerate quad (collinear corners)", code=4)
        pv = M[c][c]
        for j in range(c, N + 1):
            M[c][j] /= pv
        for r in range(N):
            if r != c and M[r][c]:
                f = M[r][c]
                for j in range(c, N + 1):
                    M[r][j] -= f * M[c][j]
    return [M[i][N] for i in range(N)]


def quad_bbox_size(quad):
    xs = [p[0] for p in quad]; ys = [p[1] for p in quad]
    return int(max(xs) - min(xs)), int(max(ys) - min(ys))


def quad_true_size(quad):
    """Реальный аспект наклонного экрана: средние длины противоположных сторон
    (bbox на угловых ракурсах врёт → скриншот растягивается)."""
    (tlx, tly), (trx, try_), (brx, bry), (blx, bly) = quad
    top    = ((trx - tlx) ** 2 + (try_ - tly) ** 2) ** 0.5
    bottom = ((brx - blx) ** 2 + (bry - bly) ** 2) ** 0.5
    left   = ((blx - tlx) ** 2 + (bly - tly) ** 2) ** 0.5
    right  = ((brx - trx) ** 2 + (bry - try_) ** 2) ** 0.5
    return max(1, int((top + bottom) / 2)), max(1, int((left + right) / 2))


def fit_shot(shot, target_w, target_h, mode):
    """cover: заполнить целевой bbox с обрезкой; contain: вписать целиком.
    Гравитация обрезки — левый верхний угол: лого/заголовок/навигация сайта живут
    там, центр-кроп срезал начало заголовка («…ДКА НА РАЗОВОЕ»)."""
    sw, sh = shot.size
    if target_w <= 0 or target_h <= 0:
        die("target screen has non-positive size", code=5)
    ar_t = target_w / target_h
    ar_s = sw / sh
    if mode == "cover":
        if ar_s > ar_t:  # шире цели → режем по ширине, держим ЛЕВЫЙ край
            nw = int(sh * ar_t); shot = shot.crop((0, 0, nw, sh))
        else:            # выше цели → режем по высоте, держим ВЕРХ (nav + hero)
            nh = int(sw / ar_t); shot = shot.crop((0, 0, sw, nh))
    return shot


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scene", required=True)
    ap.add_argument("--shot", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--mode", choices=["green", "quad"], default="green")
    ap.add_argument("--quad", help="TL,TR,BR,BL как x0,y0,...,x3,y3 (mode=quad)")
    ap.add_argument("--radius", type=int, default=0)
    ap.add_argument("--fit", choices=["cover", "contain"], default="cover")
    ap.add_argument("--min-area-frac", type=float, default=0.01)
    ap.add_argument("--bleed", type=float, default=2.0,
                    help="расширить экран наружу на N px, чтобы скрыть chroma-кант")
    ap.add_argument("--despill", type=int, default=1,
                    help="1=глушить остаточный зелёный кант в области экрана (green mode)")
    a = ap.parse_args()

    try:
        scene = Image.open(a.scene).convert("RGB")
        shot = Image.open(a.shot).convert("RGB")
    except Exception as e:
        die(f"cannot open images: {e}", code=2)

    if a.mode == "green":
        quad = detect_green_quad(scene, a.min_area_frac)
    else:
        if not a.quad:
            die("--mode quad requires --quad", code=6)
        nums = [float(x) for x in a.quad.split(",")]
        if len(nums) != 8:
            die("--quad needs 8 numbers", code=6)
        quad = [(nums[i], nums[i + 1]) for i in range(0, 8, 2)]

    if a.bleed:
        cx = sum(p[0] for p in quad) / 4.0
        cy = sum(p[1] for p in quad) / 4.0
        exp = []
        for x, y in quad:
            dx, dy = x - cx, y - cy
            ln = (dx * dx + dy * dy) ** 0.5 or 1.0
            exp.append((x + dx / ln * a.bleed, y + dy / ln * a.bleed))
        quad = exp

    tw, th = quad_true_size(quad) if a.mode == "green" else quad_bbox_size(quad)
    shot = fit_shot(shot, tw, th, a.fit)
    w, h = shot.size
    src = [(0, 0), (w, 0), (w, h), (0, h)]
    cf = perspective_coeffs(src, quad)
    warped = shot.transform(scene.size, Image.PERSPECTIVE, cf, Image.BICUBIC)

    poly = Image.new("L", scene.size, 0)
    ImageDraw.Draw(poly).polygon([tuple(p) for p in quad], fill=255)
    if a.radius > 0:
        # мягкое скругление краёв маски (для плоских рамок)
        poly = poly.filter(ImageFilter.GaussianBlur(a.radius / 3))
        poly = poly.point(lambda v: 255 if v > 200 else 0)

    out = Image.composite(warped, scene, poly)

    # despill: заглушить остаточный зелёный кант ВНУТРИ области экрана (расширенной),
    # не трогая зелень в остальной сцене (растения/фон)
    if a.mode == "green" and a.despill:
        bbox_poly = Image.new("L", scene.size, 0)
        pad = max(10, int(a.bleed) + 14)
        ex = []
        cx = sum(p[0] for p in quad) / 4.0; cy = sum(p[1] for p in quad) / 4.0
        for x, y in quad:
            dx, dy = x - cx, y - cy
            ln = (dx * dx + dy * dy) ** 0.5 or 1.0
            ex.append((x + dx / ln * pad, y + dy / ln * pad))
        ImageDraw.Draw(bbox_poly).polygon([tuple(p) for p in ex], fill=255)
        r2, g2, b2 = out.split()
        # там где всё ещё зелёно: g -> min(g, max(r,b))
        gmask = ImageChops.multiply(
            ImageChops.subtract(g2, r2).point(lambda v: 255 if v > 30 else 0),
            ImageChops.subtract(g2, b2).point(lambda v: 255 if v > 30 else 0))
        gmask = ImageChops.multiply(gmask, bbox_poly)
        cap = ImageChops.lighter(r2, b2)             # max(r,b)
        g_fixed = ImageChops.darker(g2, cap)         # min(g, max(r,b))
        g_new = Image.composite(g_fixed, g2, gmask)
        out = Image.merge("RGB", (r2, g_new, b2))

        # глобальный despill: хромакей-ОТРАЖЕНИЯ на сцене (камень, стол, клавиатура)
        # вне экрана. Порог = как у детектора (жёстче внутреннего) — живая зелень
        # (листва/mox, мутнее и желтее) по дизайну детектора его не пробивает.
        r3, g3, b3 = out.split()
        # низкие пороги + требование R≈B (цветовая «чистота» хромакея): тёмный отсвет
        # на клавиатуре (~22,53,27) ловится, живая зелень (R>B, желтее) — нет.
        purity = ImageChops.difference(r3, b3).point(lambda v: 255 if v < 25 else 0)
        spill = ImageChops.multiply(
            ImageChops.subtract(g3, r3).point(lambda v: 255 if v > 22 else 0),
            ImageChops.subtract(g3, b3).point(lambda v: 255 if v > 22 else 0))
        spill = ImageChops.multiply(spill, purity)
        spill = ImageChops.multiply(spill, g3.point(lambda v: 255 if v > 40 else 0))
        spill = ImageChops.multiply(spill, ImageChops.invert(bbox_poly))  # только вне экрана
        # отсвет разрежен (зазоры клавиш) — без дилатации blur съедает маску до ~20% альфы
        spill = spill.filter(ImageFilter.MaxFilter(7))
        spill = spill.filter(ImageFilter.GaussianBlur(2))                 # мягкий переход
        cap3 = ImageChops.lighter(r3, b3)
        # полное глушение: g -> max(r,b) — отсвет теряет цвет, сохраняя форму бликов
        g_soft = ImageChops.darker(g3, cap3)
        g_out = Image.composite(g_soft, g3, spill)
        out = Image.merge("RGB", (r3, g_out, b3))

    try:
        out.save(a.out)
    except Exception as e:
        die(f"cannot write output: {e}", code=7)

    ok(out=a.out, quad=[[int(x), int(y)] for x, y in quad],
       screen_px=[tw, th], mode=a.mode)


if __name__ == "__main__":
    main()
