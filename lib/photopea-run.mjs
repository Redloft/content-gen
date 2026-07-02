// photopea-run.mjs — headless-рендер чужих PSD через Photopea (бесплатная замена
// Dynamic Mockups для ветки D: без watermark, без кредитов).
// PSD НЕ уезжает на сервер: Photopea обрабатывает файлы client-side; локальные байты
// подсовываются через перехват https://local.mock/* (context.route), наружу уходит
// только запрос статики самого photopea.com.
//
// Usage:
//   node photopea-run.mjs dump   <file.psd>
//   node photopea-run.mjs render <file.psd> --so "<layer name>" --shot <shot.png> \
//        --out <out.png> [--rm "<substring>"] [--timeout 180]
// stdout: JSON {ok,...} | {ok:false,error}
import { chromium } from "playwright";
import fs from "fs";
import path from "path";

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
  const browser = await chromium.launch({ headless: true });
  try {
    const ctx = await browser.newContext();
    // локальные байты под фейковым https-хостом (перехват до сети, наружу не уходит)
    const psdBytes = fs.readFileSync(psdPath);
    const shotBytes = opt.shot ? fs.readFileSync(opt.shot) : null;
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

    if (mode === "replace") {
      // Одношаговая замена содержимого SO нативным экшеном (как в Photoshop/DM)
      if (!opt.so || !opt.shot || !opt.out) throw new Error("replace needs --so --shot --out");
      if (opt.rm) {
        await exec(`
          var rm = ${JSON.stringify(opt.rm.toLowerCase())};
          function walk(ls) {
            for (var i = ls.length - 1; i >= 0; i--) {
              var l = ls[i];
              if (l.typename == "LayerSet") walk(l.layers);
              else if (l.name.toLowerCase().indexOf(rm) >= 0) l.remove();
            }
          }
          walk(app.activeDocument.layers);
          app.echoToOE("RM_OK");
        `, "remove placeholder layers");
      }
      await exec(`
        var target = null, want = ${JSON.stringify(opt.so)};
        function walk(ls) {
          for (var i = 0; i < ls.length; i++) {
            var l = ls[i];
            if (l.name == want) { target = l; return; }
            if (l.typename == "LayerSet") { walk(l.layers); if (target) return; }
          }
        }
        walk(app.activeDocument.layers);
        if (!target) { app.echoToOE("SO_NOT_FOUND"); }
        else {
          app.activeDocument.activeLayer = target;
          var d = new ActionDescriptor();
          d.putPath(charIDToTypeID("null"), "https://local.mock/shot.png");
          executeAction(stringIDToTypeID("placedLayerReplaceContents"), d, DialogModes.NO);
          app.echoToOE("REPLACED");
        }
      `, "replace SO contents");
      const m = await page.evaluate(() => window.ppMsgs);
      if (m.includes("SO_NOT_FOUND")) throw new Error(`layer "${opt.so}" not found`);
      if (!m.includes("REPLACED")) throw new Error(`placedLayerReplaceContents failed; tail: ${JSON.stringify(m.slice(-5))}`);
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

    if (mode !== "render") throw new Error("unknown mode " + mode);
    if (!opt.so || !opt.shot || !opt.out) throw new Error("render needs --so --shot --out");

    // 1) чистка слоёв-заглушек
    if (opt.rm) {
      await exec(`
        var rm = ${JSON.stringify(opt.rm.toLowerCase())};
        function walk(ls) {
          for (var i = ls.length - 1; i >= 0; i--) {
            var l = ls[i];
            if (l.typename == "LayerSet") walk(l.layers);
            else if (l.name.toLowerCase().indexOf(rm) >= 0) l.remove();
          }
        }
        walk(app.activeDocument.layers);
        app.echoToOE("RM_OK");
      `, "remove placeholder layers");
      log("placeholder layers removed");
    }

    // 2) выбрать SO (рекурсивный поиск по имени) и открыть его содержимое
    await exec(`
      var target = null, want = ${JSON.stringify(opt.so)};
      function walk(ls) {
        for (var i = 0; i < ls.length; i++) {
          var l = ls[i];
          if (l.name == want) { target = l; return; }
          if (l.typename == "LayerSet") { walk(l.layers); if (target) return; }
        }
      }
      walk(app.activeDocument.layers);
      if (!target) { app.echoToOE("SO_NOT_FOUND"); }
      else {
        app.activeDocument.activeLayer = target;
        executeAction(stringIDToTypeID("placedLayerEditContents"));
        app.echoToOE("SO_OPENED");
      }
    `, "open smart object");
    let msgs = await page.evaluate(() => window.ppMsgs);
    if (msgs.includes("SO_NOT_FOUND")) throw new Error(`smart object layer "${opt.so}" not found (run dump)`);
    if (!msgs.includes("SO_OPENED")) throw new Error(`placedLayerEditContents failed silently (layer not a smart object?); msgs tail: ${JSON.stringify(msgs.slice(-5))}`);
    await exec(`app.echoToOE("CTX1 docs=" + app.documents.length + " active=" + app.activeDocument.name + " layers=" + app.activeDocument.layers.length);`, "ctx1");
    log("ctx after SO open: " + (await page.evaluate(() => window.ppMsgs)).filter(m => m.startsWith("CTX1")).pop());

    // 3) скриншот: отдельный док → copy → paste РАСТРОМ в SO-док
    // (app.open(url,null,true) давал smart-в-smart — Photopea, как и DM, nested SO не сохраняет)
    await exec(`app.open("https://local.mock/shot.png");`, "open shot doc");
    await exec(`
      var soName = ${JSON.stringify(opt.so)};
      var shotDoc = null;
      for (var i = 0; i < app.documents.length; i++)
        if (app.documents[i].name.indexOf("shot") >= 0) shotDoc = app.documents[i];
      app.activeDocument = shotDoc;
      shotDoc.selection.selectAll();
      shotDoc.selection.copy();
      shotDoc.close();
      for (var i = 0; i < app.documents.length; i++)
        if (app.documents[i].name == soName) app.activeDocument = app.documents[i];
      app.activeDocument.paste();
      app.echoToOE("CTX2 docs=" + app.documents.length + " active=" + app.activeDocument.name + " layers=" + app.activeDocument.layers.length + " top=" + app.activeDocument.activeLayer.name + " rawb0=" + String(app.activeDocument.activeLayer.bounds[0]));
    `, "paste shot into SO");
    log("ctx after paste: " + (await page.evaluate(() => window.ppMsgs)).filter(m => m.startsWith("CTX2")).pop());

    // 4) cover-fit по канве SO-документа + save/close обратно в родителя
    await exec(`
      var d = app.activeDocument, L = d.activeLayer;
      // bounds — UnitValue-объекты: число лежит в .value (String() даёт [object Object])
      function px(v) { return (v && v.value !== undefined) ? Number(v.value) : parseFloat(String(v)); }
      var b = L.bounds, bx = px(b[0]), by = px(b[1]), bw = px(b[2]) - bx, bh = px(b[3]) - by;
      if (isNaN(by)) { by = px(b[1] && b[1].val); }  // диагностический шанс на другое поле
      app.echoToOE("RAWB " + [typeof b[1], b[1] && b[1].value, b[1] && String(b[1])].join("|"));
      var W = px(d.width), H = px(d.height);
      var sc = Math.max(W / bw, H / bh) * 100;
      L.resize(sc, sc, AnchorPosition.MIDDLECENTER);
      b = L.bounds; bx = px(b[0]); by = px(b[1]); bw = px(b[2]) - bx; bh = px(b[3]) - by;
      L.translate(W / 2 - (bx + bw / 2), H / 2 - (by + bh / 2));
      app.echoToOE("FIT " + [W, H, bx, by, bw, bh, sc.toFixed(1)].join(" "));
      app.activeDocument.save();
      app.activeDocument.close();
      app.echoToOE("SO_SAVED docs=" + app.documents.length);
    `, "fit + save SO");
    {
      const m2 = await page.evaluate(() => window.ppMsgs);
      const saved = m2.find(m => m.startsWith("SO_SAVED"));
      if (!saved) throw new Error(`fit/save script died before save(); tail: ${JSON.stringify(m2.slice(-5))}`);
      log([m2.filter(m => m.startsWith("FIT")).pop(), saved].join(" | "));
    }

    // 5) экспорт родительского документа в PNG
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
    fs.mkdirSync(path.dirname(path.resolve(opt.out)), { recursive: true });
    fs.writeFileSync(opt.out, Buffer.from(b64, "base64"));
    const sz = fs.statSync(opt.out).size;
    if (sz < 10000) throw new Error("exported PNG suspiciously small: " + sz);
    console.log(JSON.stringify({ ok: true, out: opt.out, bytes: sz }));
  } finally {
    await browser.close();
  }
};

run().catch(e => { console.log(JSON.stringify({ ok: false, error: String(e.message || e) })); process.exit(2); });
