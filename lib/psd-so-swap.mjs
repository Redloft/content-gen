// psd-so-swap.mjs — локальная подмена содержимого smart object в чужом PSD (ag-psd),
// без Photoshop и без редактирования в Photopea (его SO-коммит в headless сломан,
// photopea/photopea#5921). Photopea после этого используется ТОЛЬКО как рендерер.
//
// Usage:
//   node psd-so-swap.mjs dims <in.psd> --so "<placed layer name>"
//       → {ok, w, h}  (размер содержимого SO — под него готовить скриншот)
//   node psd-so-swap.mjs swap <in.psd> <shot.png> <out.psd> --so "<name>" [--rm "<substr>"]
//       → {ok, out}   (shot.png ДОЛЖЕН быть ровно w×h; --rm удаляет слои-заглушки)
import fs from "fs";
import { readPsd, writePsd, initializeCanvas } from "ag-psd";
import { PNG } from "pngjs";

// node без DOM: ag-psd хватает imageData-шима (canvas нужен только путям, которые мы не используем)
initializeCanvas(
  () => { throw new Error("real canvas not available in node (use imageData paths)"); },
  (w, h) => ({ width: w, height: h, data: new Uint8ClampedArray(w * h * 4) })
);

const [mode, inPath, ...rest] = process.argv.slice(2);
const pos = rest.filter(a => !a.startsWith("--"));
const opt = {};
for (let i = 0; i < rest.length; i++) if (rest[i].startsWith("--")) { opt[rest[i].slice(2)] = rest[i + 1]; i++; }

const fail = e => { console.log(JSON.stringify({ ok: false, error: String(e) })); process.exit(2); };
if (!mode || !inPath || !opt.so) fail("usage: psd-so-swap.mjs dims|swap <in.psd> [shot out] --so name [--rm substr]");

const buf = fs.readFileSync(inPath);
const psd = readPsd(buf, { useImageData: true });

const matches = [];
const findPlaced = ls => (ls || []).forEach(l => {
  if (l.name === opt.so && l.placedLayer) matches.push(l);
  findPlaced(l.children);
});
findPlaced(psd.children);
// одноимённые слои встречаются (скрытые обрезки у mockups-design) — предпочитаем видимый
const placed = matches.find(l => !l.hidden) || matches[0];
if (!placed) fail(`placed layer "${opt.so}" not found`);
const visibleMatches = matches.filter(l => !l.hidden).length;
const ambiguous = visibleMatches > 1;   // 2+ видимых одноимённых → выбор первого недиагностируем
if (ambiguous) process.stderr.write(`warning: ${visibleMatches} visible placed layers named "${opt.so}" — picking first in tree order\n`);
const linked = (psd.linkedFiles || []).find(f => f.id === placed.placedLayer.id);
if (!linked || !linked.data) fail(`linked file for id ${placed.placedLayer.id} not found`);

const inner = readPsd(Buffer.from(linked.data), { skipLayerImageData: true, skipCompositeImageData: true, skipThumbnail: true });

if (mode === "dims") {
  console.log(JSON.stringify({
    ok: true, w: inner.width, h: inner.height, linked_name: linked.name,
    doc_w: psd.width, doc_h: psd.height,
    matches_count: matches.length, ambiguous,
    // настоящий перспективный квад — в nonAffineTransform; transform = лишь bbox
    transform: placed.placedLayer.nonAffineTransform || placed.placedLayer.transform,
  }));
  process.exit(0);
}

if (mode !== "swap") fail("unknown mode " + mode);
const [shotPath, outPath] = pos;
if (!shotPath || !outPath) fail("swap needs <shot.png> <out.psd>");

const png = PNG.sync.read(fs.readFileSync(shotPath));
if (png.width !== inner.width || png.height !== inner.height)
  fail(`shot is ${png.width}x${png.height}, SO content needs exactly ${inner.width}x${inner.height}`);

const imageData = { width: png.width, height: png.height, data: new Uint8ClampedArray(png.data) };
// вложенный документ: один растровый слой на всю канву + composite
const innerPsd = {
  width: png.width, height: png.height,
  imageData,
  children: [{ name: "shot", left: 0, top: 0, imageData }],
};
const newBytes = writePsd(innerPsd, { generateThumbnail: false });
linked.data = new Uint8Array(newBytes);

// ГЛАВНОЕ: placed layer несёт ЗАПЕЧЁННЫЙ растр — рендереры (Photopea при load)
// используют его, а не linked file. --raster = наш локально-варпнутый по transform-кваду
// кадр на всю канву: подменяем растр слоя и превращаем его в обычный растровый слой.
if (opt.raster) {
  const rp = PNG.sync.read(fs.readFileSync(opt.raster));
  if (rp.width !== psd.width || rp.height !== psd.height)
    fail(`--raster is ${rp.width}x${rp.height}, must be full canvas ${psd.width}x${psd.height}`);
  placed.imageData = { width: rp.width, height: rp.height, data: new Uint8ClampedArray(rp.data) };
  placed.left = 0; placed.top = 0; placed.right = psd.width; placed.bottom = psd.height;
  delete placed.placedLayer;
  delete placed.canvas;
}

// чистка слоёв-заглушек (mockups-design «DELETE THIS LAYER») — прямо в дереве
if (opt.rm) {
  const rm = opt.rm.toLowerCase();
  const prune = node => {
    if (!node.children) return;
    node.children = node.children.filter(l => !(l.name || "").toLowerCase().includes(rm));
    node.children.forEach(prune);
  };
  prune(psd);
}

fs.writeFileSync(outPath, Buffer.from(writePsd(psd, { generateThumbnail: false })));
console.log(JSON.stringify({ ok: true, out: outPath, bytes: fs.statSync(outPath).size }));
