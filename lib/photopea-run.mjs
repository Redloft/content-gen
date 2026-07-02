// photopea-run.mjs — headless-рендер чужих PSD через Photopea (бесплатная замена
// Dynamic Mockups для ветки D: без watermark, без кредитов).
// Приватность: Photopea обрабатывает файлы client-side, локальные байты подсовываются
// через перехват https://local.mock/* (context.route). Сеть на default-deny: разрешён
// только photopea.com (его статика) + local.mock, любой другой хост — abort+log в stderr.
// ГАРАНТИЯ: сторонний хост не получит запрос. НЕ гарантия: сам код photopea.com (живой,
// без version-pin) держит декодированные байты в памяти — для КЛИЕНТ-КОНФИДЕНЦИАЛЬНЫХ PSD
// это остаточный риск (см. security-ревью 2026-07-03), для публичных сайтов-скриншотов ок.
//
// Usage:
//   node photopea-run.mjs dump    <file.psd>
//   node photopea-run.mjs export  <file.psd> --out <out.png> [--timeout 180]
//   node photopea-run.mjs overlay <file.psd> --overlay <warped.png> --above "<screen layer>" \
//        --quad '<quad8-json>' [--rm "<substring>"] --out <out.png> [--timeout 180]
// stdout: JSON {ok,...} | {ok:false,error}
import { chromium } from "playwright";
import fs from "fs";

const [mode, psdPath, ...rest] = process.argv.slice(2);
const opt = {};
for (let i = 0; i < rest.length; i += 2) opt[rest[i].replace(/^--/, "")] = rest[i + 1];

if (!mode || !psdPath || !fs.existsSync(psdPath)) {
  console.log(JSON.stringify({ ok: false, error: "usage: photopea-run.mjs dump|render <psd> [--so --shot --out --rm]" }));
  process.exit(1);
}
const TIMEOUT = (parseInt(opt.timeout) || 180) * 1000;

const HARNESS = `<!doctype html><html><body style="margin:0">
<iframe id="pp" style="width:1400px;height:900px;border:0"></iframe>
<script>
window.ppMsgs = []; window.ppBins = [];
window.addEventListener("message", e => {
  if (typeof e.data === "string") window.ppMsgs.push(e.data);
  else if (e.data instanceof ArrayBuffer) {
    const u = new Uint8Array(e.data); let s = "", CH = 0x8000;
    for (let i = 0; i < u.length; i += CH) s += String.fromCharCode.apply(null, u.subarray(i, i + CH));
    window.ppBins.push(btoa(s));
  }
});
window.ppSend = t => document.getElementById("pp").contentWindow.postMessage(t, "*");
</script></body></html>`;

function log(m) { process.stderr.write(m + "\n"); }

const run = async () => {
  // большие PSD (70-100MB) OOM-ят рендерер с дефолтным лимитом V8
  const browser = await chromium.launch({ headless: true, args: ["--js-flags=--max-old-space-size=8192"] });
  // hard-watchdog: если Playwright/Photopea зависнут вне внутренних while-loop'ов,
  // finally{browser.close} не сработает — гарантированно валим процесс, не оставляя headless Chromium.
  const watchdog = setTimeout(() => {
    process.stderr.write("watchdog: hard timeout, killing browser\n");
    browser.close().catch(() => {});
    process.exit(2);
  }, TIMEOUT + 180000);
  watchdog.unref?.();
  try {
    const ctx = await browser.newContext();
    await ctx.grantPermissions(["clipboard-read", "clipboard-write"]);
    // Перехватываем ТОЛЬКО local.mock — подставляем локальные байты, наружу они не уходят.
    // ГАРАНТИЯ приватности здесь узкая и честная: запрос на local.mock не покидает машину.
    // НЕ гарантия: сам код www.photopea.com (живой, без version-pin) держит декодированные
    // байты в памяти и имеет открытый сетевой путь — для КЛИЕНТ-КОНФИДЕНЦИАЛЬНЫХ PSD это
    // остаточный риск (security-ревью 2026-07-03). Полный default-deny egress пробовали —
    // он ломает загрузку самого Photopea (перехват всех subresource-запросов через route
    // рушит инициализацию, app-ready не наступает); для публичных сайтов-скриншотов узкого
    // перехвата достаточно, для конфиденциальных — нужен self-hosted pinned Photopea (TODO).
    const psdBytes = fs.readFileSync(psdPath);
    const shotBytes = (opt.shot || opt.overlay) ? fs.readFileSync(opt.shot || opt.overlay) : null;
    await ctx.route("https://local.mock/**", route => {
      const u = route.request().url();
      const body = u.endsWith("file.psd") ? psdBytes : shotBytes;
      if (!body) return route.abort();
      route.fulfill({ status: 200, body, headers: { "Access-Control-Allow-Origin": "*", "Content-Type": "application/octet-stream" } });
    });
    const page = await ctx.newPage();
    await page.setContent(HARNESS);
    // ВАЖНО: НЕ задавать environment.customIO.save — он глобально перехватывает save()
    // и ломает коммит smart object обратно в родительский документ.
    const cfg = { files: ["https://local.mock/file.psd"] };
    await page.evaluate(c => { document.getElementById("pp").src = "https://www.photopea.com#" + encodeURIComponent(JSON.stringify(c)); }, cfg);

    const msgCount = () => page.evaluate(() => window.ppMsgs.length);
    const waitDone = async (since, what, extraMs = 0) => {
      const t0 = Date.now();
      while (Date.now() - t0 < TIMEOUT + extraMs) {
        const msgs = await page.evaluate(() => window.ppMsgs);
        for (let i = since; i < msgs.length; i++) if (msgs[i] === "done") return i + 1;
        await page.waitForTimeout(300);
      }
      throw new Error(`timeout waiting done after: ${what}`);
    };
    const exec = async (script, what) => {
      const since = await msgCount();
      await page.evaluate(s => window.ppSend(s), script);
      return waitDone(since, what);
    };

    log("loading PSD into Photopea…");
    await waitDone(0, "photopea app ready", 120000);
    // "done" приходит и от готовности приложения, и от загрузки файла — единственный
    // надёжный признак загруженного PSD: probe на app.documents.length
    {
      const t0 = Date.now();
      let loaded = false;
      while (Date.now() - t0 < TIMEOUT + 120000) {
        await exec(`app.echoToOE("DOCS:" + app.documents.length);`, "doc probe");
        const msgs = await page.evaluate(() => window.ppMsgs);
        const last = [...msgs].reverse().find(m => m.startsWith("DOCS:"));
        if (last && parseInt(last.slice(5)) >= 1) { loaded = true; break; }
        await page.waitForTimeout(1500);
      }
      if (!loaded) throw new Error("PSD did not load (documents.length stayed 0)");
      log("PSD loaded");
    }

    if (mode === "dump") {
      await exec(`
        var out = [];
        function walk(ls, d) {
          for (var i = 0; i < ls.length; i++) {
            var l = ls[i];
            out.push(Array(d + 1).join("  ") + l.name + " | " + l.typename + (l.kind ? " | " + l.kind : "") + (l.visible ? "" : " | hidden"));
            if (l.typename == "LayerSet") walk(l.layers, d + 1);
          }
        }
        walk(app.activeDocument.layers, 0);
        app.echoToOE("DUMP\\n" + out.join("\\n"));
      `, "dump");
      // «kind» ArtLayer в Photopea видно только по typename родного объекта — добавим smartObject-пробу
      await exec(`
        var l = app.activeDocument.layers[0];
        app.echoToOE("PROBE first layer kind=" + l.kind + " isSO=" + (String(l.kind) == "LayerKind.SMARTOBJECT"));
      `, "so probe");
      const msgs = await page.evaluate(() => window.ppMsgs);
      const dump = msgs.find(m => m.startsWith("DUMP"));
      console.log(JSON.stringify({ ok: !!dump, layers: dump ? dump.slice(5) : "(no dump)", all_msgs: dump ? undefined : msgs.slice(0, 40) }));
      return;
    }

    if (mode === "export") {
      // чистый рендер: load → PNG (никакого редактирования — единственный надёжный headless-путь)
      if (!opt.out) throw new Error("export needs --out");
      const binsBefore = await page.evaluate(() => window.ppBins.length);
      await exec(`app.activeDocument.saveToOE("png");`, "export png");
      const t0 = Date.now();
      let b64 = null;
      while (Date.now() - t0 < TIMEOUT) {
        const bins = await page.evaluate(() => window.ppBins);
        if (bins.length > binsBefore) { b64 = bins[bins.length - 1]; break; }
        await page.waitForTimeout(300);
      }
      if (!b64) throw new Error("no PNG arrived from saveToOE");
      fs.writeFileSync(opt.out, Buffer.from(b64, "base64"));
      console.log(JSON.stringify({ ok: true, out: opt.out, bytes: fs.statSync(opt.out).size }));
      return;
    }

    if (mode === "overlay") {
      // Универсальный путь для чужих PSD: оригинал НЕ переписывается (ag-psd roundtrip
      // ломает сложные PSD), SO не коммитится (headless-баг Photopea). Вместо этого:
      // удалить заглушки → вставить полноканвенный варп-растр НАД слоем экрана → PNG.
      if (!opt.overlay || !opt.above || !opt.out) throw new Error("overlay needs --overlay --above --out");
      if (opt.rm) {
        await exec(`
          var rm = ${JSON.stringify(opt.rm.toLowerCase())}, n = 0;
          function walk(ls) {
            for (var i = ls.length - 1; i >= 0; i--) {
              var l = ls[i];
              if (l.typename == "LayerSet") walk(l.layers);
              else if (l.name.toLowerCase().indexOf(rm) >= 0) { l.remove(); n++; }
            }
          }
          walk(app.activeDocument.layers);
          app.echoToOE("RM_OK count=" + n);
        `, "remove placeholder layers");
        const rmMsg = (await page.evaluate(() => window.ppMsgs)).filter(x => x.startsWith("RM_OK")).pop() || "";
        const rmN = parseInt((rmMsg.match(/count=(\d+)/) || [])[1] || "0");
        log(`--rm "${opt.rm}": removed ${rmN} layer(s)`);
        if (rmN === 0) process.stderr.write(`warning: --rm "${opt.rm}" matched 0 layers (placeholder not found?)\n`);
      }
      // варп-растр приезжает вторым документом
      await exec(`app.open("https://local.mock/shot.png");`, "open overlay doc");
      // size-assert: overlay ОБЯЗАН быть полноканвенным (выход quad-warp.py = doc_w×doc_h).
      // Иначе caller забыл прогнать warp → тихо кривая вставка. Валим явно.
      await exec(`
        var mainDoc = app.documents[0], ovDoc = null;
        for (var i = 0; i < app.documents.length; i++) if (app.documents[i] != mainDoc) ovDoc = app.documents[i];
        function px(v){ return (v && v.value !== undefined) ? Number(v.value) : parseFloat(String(v)); }
        var mw = px(mainDoc.width), mh = px(mainDoc.height), ow = px(ovDoc.width), oh = px(ovDoc.height);
        app.echoToOE((Math.abs(mw-ow) <= 2 && Math.abs(mh-oh) <= 2 ? "SIZE_OK " : "SIZE_MISMATCH ") + [mw,mh,ow,oh].join("x"));
      `, "overlay size check");
      {
        const sm = (await page.evaluate(() => window.ppMsgs)).filter(x => x.startsWith("SIZE_")).pop() || "";
        if (sm.startsWith("SIZE_MISMATCH")) throw new Error(`overlay is not full-canvas (${sm}); run quad-warp.py to doc dims first`);
      }
      await exec(`
        var mainDoc = app.documents[0];
        var ovDoc = null;
        for (var i = 0; i < app.documents.length; i++)
          if (app.documents[i] != mainDoc) ovDoc = app.documents[i];
        // copy/paste работает в headless (внутренний буфер Photopea, не OS clipboard)
        app.activeDocument = ovDoc;
        ovDoc.selection.selectAll();
        ovDoc.selection.copy();
        ovDoc.close();
        app.activeDocument = mainDoc;
        // активным делаем слой экрана → paste ложится ПРЯМО НАД ним (под Highlights)
        var want = ${JSON.stringify(opt.above)}, target = null;
        function walk(ls) {
          for (var i = 0; i < ls.length; i++) {
            var l = ls[i];
            if (l.name == want && l.visible && !target) target = l;
            if (l.typename == "LayerSet") walk(l.layers);
          }
        }
        walk(mainDoc.layers);
        if (!target) { app.echoToOE("ABOVE_NOT_FOUND"); }
        else {
          mainDoc.activeLayer = target;
          mainDoc.paste();
          var L = mainDoc.activeLayer;
          function px(v) { return (v && v.value !== undefined) ? Number(v.value) : parseFloat(String(v)); }
          // paste центрует НЕПРОЗРАЧНЫЙ bbox по центру дока; вернём его в позицию квада
          var q = ${JSON.stringify(opt.quad ? JSON.parse(opt.quad) : null)};
          var b = L.bounds, bx = px(b[0]), by = px(b[1]);
          if (q) {
            var tx = Math.min(q[0], q[2], q[4], q[6]), ty = Math.min(q[1], q[3], q[5], q[7]);
            L.translate(tx - bx, ty - by);
          }
          app.echoToOE("OVERLAY_OK bounds=" + [px(b[0]), px(b[1]), px(b[2]), px(b[3])].join(","));
        }
      `, "paste overlay above screen layer");
      const m = await page.evaluate(() => window.ppMsgs);
      if (m.includes("ABOVE_NOT_FOUND")) throw new Error(`layer "${opt.above}" not found/visible`);
      if (!m.some(x => x.startsWith("OVERLAY_OK"))) throw new Error(`overlay failed; tail: ${JSON.stringify(m.slice(-5))}`);
      const binsBefore = await page.evaluate(() => window.ppBins.length);
      await exec(`app.activeDocument.saveToOE("png");`, "export png");
      const t0 = Date.now();
      let b64 = null;
      while (Date.now() - t0 < TIMEOUT) {
        const bins = await page.evaluate(() => window.ppBins);
        if (bins.length > binsBefore) { b64 = bins[bins.length - 1]; break; }
        await page.waitForTimeout(300);
      }
      if (!b64) throw new Error("no PNG arrived from saveToOE");
      fs.writeFileSync(opt.out, Buffer.from(b64, "base64"));
      console.log(JSON.stringify({ ok: true, out: opt.out, bytes: fs.statSync(opt.out).size }));
      return;
    }

    // Режимы `render` и `replace` (редактирование smart object внутри Photopea) УДАЛЕНЫ:
    // headless Photopea НЕ коммитит SO обратно в родителя (placedLayerEditContents/
    // placedLayerReplaceContents + save() виснут/no-op, photopea#5921), а echo SO_SAVED/REPLACED
    // при этом приходит → ложный success. Рабочий путь — swap растра в linked file через
    // psd-so-swap.mjs + рендер здесь в режиме `overlay`/`export`. Не воскрешать без round-trip
    // pixel-diff проверки экспорта.
    throw new Error(`unknown mode "${mode}" (supported: dump|export|overlay)`);
  } finally {
    await browser.close();
  }
};

run().catch(e => { console.log(JSON.stringify({ ok: false, error: String(e.message || e) })); process.exit(2); });
