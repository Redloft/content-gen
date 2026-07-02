#!/usr/bin/env python3
"""Self-made mockup composite v2: chroma scene -> despill -> perspective insert
-> lighting/reflection transfer. Fully local, no external renderer.

Usage: selfmade-composite.py <scene.png> <shot.png> <out.png>
"""
import sys, os
import numpy as np
from PIL import Image, ImageFilter, ImageDraw

sys.path.insert(0, os.path.expanduser("~/.claude/skills/content-gen/lib"))
import importlib.util
spec = importlib.util.spec_from_file_location(
    "fc", os.path.expanduser("~/.claude/skills/content-gen/lib/frame-composite.py"))
fc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fc)

scene_p, shot_p, out_p = sys.argv[1], sys.argv[2], sys.argv[3]
argv_extra = sys.argv[4:]
junk_p = next((a for a in argv_extra if not a.startswith("--")), None)
DRAW_DI = "--di" in argv_extra            # рисовать Dynamic Island (последний iPhone)
# --crop-screen=0.66 → кроп кадра так, чтобы высота экрана = 66% высоты кадра
crop_frac = next((float(a.split("=")[1]) for a in argv_extra
                  if a.startswith("--crop-screen=")), None)
scene = Image.open(scene_p).convert("RGB")
shot = Image.open(shot_p).convert("RGB")
W, H = scene.size

quad = fc.detect_green_quad(scene, 0.02)

# --- гистерезисное расширение квада ------------------------------------------
# строгий порог детекции теряет ЗАТЕНЁННЫЕ части экрана (тёмно-зелёные, g<130)
# → квад усыхает, у кромки остаётся полоса сцены. Реконструкция: от строгого
# квада (seed) распространяемся в мягкую маску «зелёный доминирует, но тёмный».
sc0 = np.asarray(scene, dtype=np.float32)
r0, g0, b0 = sc0[..., 0], sc0[..., 1], sc0[..., 2]
# g>b+30: у хромакея B низкий; бирюза/teal (ногти, вода) имеет g≈b — не пускать,
# иначе реконструкция утекает в них и квад раздувается
loose = (g0 > r0 + 18) & (g0 > b0 + 30) & (g0 > 45)
seed_img = Image.new("L", (W, H), 0)
ImageDraw.Draw(seed_img).polygon([tuple(p) for p in quad], fill=255)
recon = (np.asarray(seed_img, dtype=np.float32) > 128) & loose
# рост по 1px/итерацию (MaxFilter(3)): НЕ перепрыгивает бленду рамки >2px —
# иначе реконструкция утекает в зелёные отблески на металле за бездой
for _ in range(80):
    grown = np.asarray(Image.fromarray((recon * 255).astype(np.uint8)).filter(
        ImageFilter.MaxFilter(3)), dtype=np.float32) > 128
    nxt = grown & loose
    if nxt.sum() == recon.sum():
        break
    recon = nxt
# opening: срезать тонкие отростки/слизняки перед фитом углов
recon = np.asarray(Image.fromarray((recon * 255).astype(np.uint8)).filter(
    ImageFilter.MinFilter(5)).filter(ImageFilter.MaxFilter(5)),
    dtype=np.float32) > 128
def fit_quad_from_mask(m, fallback):
    """Квад = пересечение 4 прямых, натянутых на рёбра выпуклой оболочки маски.
    Устойчив к ЗАКРЫТЫМ углам (палец поверх угла): невидимый угол = пересечение
    продолженных видимых рёбер. Fallback — extreme-points."""
    ys, xs = np.where(m)
    if len(xs) < 100:
        return fallback, False
    pts = np.stack([xs, ys], 1).astype(np.float64)
    # convex hull (Andrew monotone chain) по подвыборке границы
    P = np.unique(pts[np.random.default_rng(0).choice(len(pts), min(len(pts), 20000), replace=False)], axis=0)
    P = P[np.lexsort((P[:, 1], P[:, 0]))]
    def cross(o, a, b):
        return (a[0]-o[0])*(b[1]-o[1]) - (a[1]-o[1])*(b[0]-o[0])
    lower, upper = [], []
    for p in P:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(tuple(p))
    for p in P[::-1]:
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(tuple(p))
    hull = np.array(lower[:-1] + upper[:-1])
    if len(hull) < 4:
        return fallback, False
    # ориентация: PCA главных осей
    c = hull.mean(0)
    u, s, vt = np.linalg.svd(hull - c)
    ax1, ax2 = vt[0], vt[1]
    # каждое ребро оболочки → сторона по внешней нормали (4 сектора)
    sides = {k: [] for k in range(4)}   # 0:+ax2(низ) 1:-ax2(верх) 2:+ax1 3:-ax1
    n_h = len(hull)
    for i in range(n_h):
        p1, p2 = hull[i], hull[(i + 1) % n_h]
        e = p2 - p1
        ln = np.hypot(*e)
        if ln < 2:
            continue
        nrm = np.array([e[1], -e[0]]) / ln
        mid = (p1 + p2) / 2
        if np.dot(nrm, mid - c) < 0:
            nrm = -nrm
        d1, d2 = np.dot(nrm, ax1), np.dot(nrm, ax2)
        k = (2 if d1 > 0 else 3) if abs(d1) > abs(d2) else (0 if d2 > 0 else 1)
        sides[k].append((p1, p2, ln))
    lines = {}
    for k, edges in sides.items():
        if not edges:
            return fallback, False
        # взвешенный LSQ по концам рёбер (вес = длина) → прямая ax+by=c
        pts_k, w_k = [], []
        for p1, p2, ln in edges:
            pts_k += [p1, p2]; w_k += [ln, ln]
        A = np.array(pts_k); w = np.array(w_k)
        cm = (A * w[:, None]).sum(0) / w.sum()
        uu, ss, vv = np.linalg.svd((A - cm) * np.sqrt(w)[:, None])
        direction = vv[0]
        normal = np.array([direction[1], -direction[0]])
        lines[k] = (normal, np.dot(normal, cm))
    def inter(l1, l2):
        (n1, c1), (n2, c2) = l1, l2
        M = np.array([n1, n2])
        if abs(np.linalg.det(M)) < 1e-9:
            return None
        return np.linalg.solve(M, np.array([c1, c2]))
    # углы: (верх,лево)(верх,право)(низ,право)(низ,лево) → TL TR BR BL по геометрии
    cand = [inter(lines[1], lines[3]), inter(lines[1], lines[2]),
            inter(lines[0], lines[2]), inter(lines[0], lines[3])]
    if any(p is None for p in cand):
        return fallback, False
    # упорядочить как TL TR BR BL в экранных координатах
    cand = sorted(cand, key=lambda p: p[1])
    top = sorted(cand[:2], key=lambda p: p[0])
    bot = sorted(cand[2:], key=lambda p: p[0])
    q = [tuple(top[0]), tuple(top[1]), tuple(bot[1]), tuple(bot[0])]
    return q, True

quad_fallback = quad
# quad_fit_quality: машиночитаемый статус для batch-оркестратора —
# edge_fit (точный) | extreme_point_fallback (грубее) | strict_fallback (хуже всего)
if recon.any():
    ys_, xs_ = np.where(recon)
    s_ = xs_ + ys_; d_ = xs_ - ys_
    quad_ep = [(float(xs_[s_.argmin()]), float(ys_[s_.argmin()])),
               (float(xs_[d_.argmax()]), float(ys_[d_.argmax()])),
               (float(xs_[s_.argmax()]), float(ys_[s_.argmax()])),
               (float(xs_[d_.argmin()]), float(ys_[d_.argmin()]))]
    quad, fitted = fit_quad_from_mask(recon, quad_ep)
    quad_fit_quality = "edge_fit" if fitted else "extreme_point_fallback"
    print("hysteresis quad:", [(round(x), round(y)) for x, y in quad],
          "| edge-fit:", fitted)
else:
    quad_fit_quality = "strict_fallback"
    print('{"warn":"hysteresis reconstruction empty, keeping strict quad"}')
if quad_fit_quality != "edge_fit":
    print(f'{{"quad_fit_quality":"{quad_fit_quality}","degraded":true}}', file=sys.stderr)

cx = sum(p[0] for p in quad) / 4.0
cy = sum(p[1] for p in quad) / 4.0
BLEED = 4.0
quad = [(x + (x - cx) / (((x - cx) ** 2 + (y - cy) ** 2) ** 0.5 or 1) * BLEED,
         y + (y - cy) / (((x - cx) ** 2 + (y - cy) ** 2) ** 0.5 or 1) * BLEED)
        for x, y in quad]
tw, th = fc.quad_true_size(quad)
# маска полигона с 4x суперсэмплингом — гладкая AA-кромка вместо лесенки
mask4 = Image.new("L", (W * 4, H * 4), 0)
ImageDraw.Draw(mask4).polygon([(x * 4, y * 4) for x, y in quad], fill=255)
mask = mask4.resize((W, H), Image.LANCZOS)

sc = np.asarray(scene, dtype=np.float32)

# --- lighting maps from the green screen (BEFORE despill) -------------------
m = np.asarray(mask, dtype=np.float32) / 255.0
inside = m > 0.5
luma = 0.2126 * sc[..., 0] + 0.7152 * sc[..., 1] + 0.0722 * sc[..., 2]
ref_img = Image.fromarray(np.uint8(np.clip(luma, 0, 255))).filter(
    ImageFilter.GaussianBlur(radius=max(W, H) // 14))
ref = np.asarray(ref_img, dtype=np.float32)
ratio = np.ones_like(luma)
ratio[inside] = (luma[inside] + 1.0) / (ref[inside] + 1.0)
spec = np.zeros_like(luma)
spec[inside] = np.clip(
    (np.minimum(sc[..., 0], sc[..., 2])[inside] / (sc[..., 1][inside] + 1.0) - 0.35) / 0.65,
    0, 1)
ratio = np.asarray(Image.fromarray(np.uint8(np.clip(ratio * 127.5, 0, 255))).filter(
    ImageFilter.GaussianBlur(2)), dtype=np.float32) / 127.5
spec = np.asarray(Image.fromarray(np.uint8(spec * 255)).filter(
    ImageFilter.GaussianBlur(3)), dtype=np.float32) / 255.0

# junk-маска (иконки/мусор, нарисованные генератором НА зелёном): нейтрализуем
# их в карте света, чтобы не давали призрачных бликов; сами пиксели сцены
# не важны — их накроет вставка
if junk_p:
    jn = np.asarray(Image.open(junk_p).convert("L").filter(
        ImageFilter.GaussianBlur(3)), dtype=np.float32) / 255.0
    ratio = ratio * (1 - jn) + 1.0 * jn
    spec = spec * (1 - jn)
    print("junk neutralized px:", int((jn > 0.5).sum()))

# --- despill scene (prod thresholds), ONLY near the screen quad -------------
# отсветы хромакея живут на канте/клавиатуре/руках у экрана; далёкая зелёная
# ткань/растения — легитимный цвет сцены, их не трогаем (иначе пятна)
r, g, b = sc[..., 0], sc[..., 1], sc[..., 2]
spill = ((g - r > 22) & (g - b > 22) & (np.abs(r - b) < 25) & (g > 40)).astype(np.uint8) * 255
zone = mask.filter(ImageFilter.MaxFilter(9))
for _ in range(6):                       # 7×MaxFilter(9) ≈ ±28px вокруг экрана
    zone = zone.filter(ImageFilter.MaxFilter(9))
zn = (np.asarray(zone, dtype=np.float32) / 255.0) > 0.5
spill[~zn] = 0
spill_m = Image.fromarray(spill).filter(ImageFilter.MaxFilter(7)).filter(
    ImageFilter.GaussianBlur(2))
sm = np.asarray(spill_m, dtype=np.float32) / 255.0
g_fix = np.maximum(r, b)
sc_d = sc.copy()
sc_d[..., 1] = g * (1 - sm) + g_fix * sm

# --- warp screenshot ---------------------------------------------------------
shot_fit = fc.fit_shot(shot, int(tw), int(th), "cover")
sw, sh = shot_fit.size
coeffs = fc.perspective_coeffs([(0, 0), (sw, 0), (sw, sh), (0, sh)], quad)
warped = shot_fit.transform((W, H), Image.PERSPECTIVE, coeffs, Image.BICUBIC)
wp = np.asarray(warped, dtype=np.float32)

# --- apply lighting to the insert -------------------------------------------
lit = wp * np.clip(ratio[..., None], 0.45, 1.0)               # shadows
lit = lit + (255.0 - lit) * np.clip(ratio[..., None] - 1.0, 0, 0.6)  # glare
lit = lit + (255.0 - lit) * spec[..., None] * 0.55                    # specular
# black-level lift: живой дисплей не бывает RGB(0,0,0) — поднять чёрную точку
BLACK_FLOOR = 14.0
lit = lit + BLACK_FLOOR * (1.0 - lit / 255.0)

# --- rounded corners вставки (совпасть со скруглением экрана устройства) -----
corner_r = int(min(sw, sh) * 0.055)
rr = Image.new("L", (sw, sh), 0)
ImageDraw.Draw(rr).rounded_rectangle([0, 0, sw - 1, sh - 1], radius=corner_r, fill=255)
rr_w = rr.transform((W, H), Image.PERSPECTIVE, coeffs, Image.BICUBIC)
round_a = np.asarray(rr_w.filter(ImageFilter.GaussianBlur(0.8)),
                     dtype=np.float32)[..., None] / 255.0

# --- Dynamic Island (последний iPhone): чёрный «островок» вверху экрана ------
# рисуем в плоском shot-space и варпим тем же coeffs → перспектива верна.
# кладём на lit (=контент экрана), значит пальцы поверх него всё равно перекроют
if DRAW_DI:
    di = Image.new("L", (sw, sh), 0)
    diw, dih = int(sw * 0.29), int(sh * 0.032)
    dcx, dcy = sw // 2, int(sh * 0.052)
    ImageDraw.Draw(di).rounded_rectangle(
        [dcx - diw // 2, dcy - dih // 2, dcx + diw // 2, dcy + dih // 2],
        radius=dih // 2, fill=255)
    di_w = di.transform((W, H), Image.PERSPECTIVE, coeffs, Image.BICUBIC).filter(
        ImageFilter.GaussianBlur(0.6))
    dia = np.asarray(di_w, dtype=np.float32)[..., None] / 255.0
    lit = lit * (1 - dia) + np.array([10.0, 10.0, 12.0]) * dia
    print("dynamic island drawn")

# --- occlusion: пальцы/чёлка ПОВЕРХ вставки ----------------------------------
# не-хром области внутри квада, СВЯЗАННЫЕ с его границей (палец, notch, рамка),
# остаются на переднем плане; изолированный мусор внутри (иконки) — накрывается
mk = np.asarray(mask, dtype=np.float32) > 128
nonchroma_in = (~loose) & mk
boundary = mk & ~(np.asarray(mask.filter(ImageFilter.MinFilter(7)),
                             dtype=np.float32) > 128)
occl = nonchroma_in & boundary
prev_sum = -1
for _ in range(60):
    if occl.sum() == prev_sum:
        break
    prev_sum = occl.sum()
    occl = (np.asarray(Image.fromarray((occl * 255).astype(np.uint8)).filter(
        ImageFilter.MaxFilter(5)), dtype=np.float32) > 128) & nonchroma_in
occl_soft = np.asarray(Image.fromarray((occl * 255).astype(np.uint8)).filter(
    ImageFilter.GaussianBlur(1.2)), dtype=np.float32)[..., None] / 255.0
print("occlusion px:", int(occl.sum()))

# --- composite ---------------------------------------------------------------
mask_soft = np.asarray(
    mask.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(1.2)),
    dtype=np.float32)[..., None] / 255.0
mask_soft = mask_soft * (1 - occl_soft) * round_a   # скругление углов вставки
out = sc_d * (1 - mask_soft) + lit * mask_soft

# добить остаточный хром в КОЛЬЦЕ вокруг кромки экрана (выпуклость за квадом):
# в кольце легитимной зелени не бывает — глушим без охранного |r-b|-порога
dil = mask
for _ in range(4):
    dil = dil.filter(ImageFilter.MaxFilter(9))          # ~±16px наружу
ero = mask.filter(ImageFilter.MinFilter(5))
ring = (np.asarray(dil, dtype=np.float32) > 128) & ~(
    np.asarray(ero, dtype=np.float32) > 128)
ro, go, bo = out[..., 0], out[..., 1], out[..., 2]
resid = ring & (go > ro + 25) & (go > bo + 25)
rm = np.asarray(Image.fromarray((resid * 255).astype(np.uint8)).filter(
    ImageFilter.MaxFilter(5)).filter(ImageFilter.GaussianBlur(1.5)),
    dtype=np.float32) / 255.0
out[..., 1] = go * (1 - rm) + np.maximum(ro, bo) * rm
print("residual chroma px:", int(resid.sum()))

out_img = Image.fromarray(np.uint8(np.clip(out, 0, 255)))

# --- авто-кроп: экран занимает crop_frac высоты кадра (сохраняя аспект) ------
if crop_frac:
    qy = [p[1] for p in quad]; qx = [p[0] for p in quad]
    screen_h = max(qy) - min(qy)
    cy_q = (min(qy) + max(qy)) / 2
    cx_q = (min(qx) + max(qx)) / 2
    new_h = min(H, screen_h / crop_frac)
    new_w = min(W, new_h * (W / H))
    x0 = int(min(max(0, cx_q - new_w / 2), W - new_w))
    y0 = int(min(max(0, cy_q - new_h / 2), H - new_h))
    out_img = out_img.crop((x0, y0, int(x0 + new_w), int(y0 + new_h)))
    print(f"cropped to screen≈{crop_frac:.0%}: {out_img.size}")

out_img.save(out_p)
print("quad:", [(round(x), round(y)) for x, y in quad],
      "| light range:", round(float(ratio[inside].min()), 2), "-",
      round(float(ratio[inside].max()), 2),
      "| spill px:", int((sm > 0.5).sum()),
      "| quad_fit:", quad_fit_quality)
print("saved:", out_p)
