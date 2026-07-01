#!/usr/bin/env node
/*
 * slots-from-page.mjs — построить slot-манифест из ШАБЛОНА (репо/файл).
 * Для ЖИВОГО url слоты меряет capture.mjs --measure-slots; этот скрипт — для кода.
 *
 * Ищет: next/image <Image>, <img>, background-image url(), компоненты Hero/Feature/
 * Gallery/Banner/Cover/Avatar/Logo. Извлекает явные width/height/aspect если есть,
 * иначе — пресет по назначению. Каждый слот → desktop+mobile WxH.
 *
 * КОНТРАКТ (plan-panel critical #4): если 0 валидных слотов → {ok:true, slots:[],
 * fallback:true, reason} — оркестратор уходит в AskUserQuestion-пресет, НЕ молчит.
 *
 * Usage: node slots-from-page.mjs --path <dir|file> [--max 24]
 * stdout: JSON {ok, slots:[{id,purpose,desktop:{w,h},mobile:{w,h},format}], fallback, reason}
 */
import fs from 'node:fs';
import path from 'node:path';

function arg(n,d){ const i=process.argv.indexOf('--'+n); return i<0?d:(process.argv[i+1]??d); }
function out(o){ console.log(JSON.stringify(o)); process.exit(0); }

const PRESET = {
  hero:    { d:[1600,900], m:[800,900] },
  feature: { d:[600,400],  m:[640,420] },
  gallery: { d:[800,600],  m:[720,540] },
  banner:  { d:[1600,500], m:[800,600] },
  cover:   { d:[1200,630], m:[800,1000] },
  avatar:  { d:[240,240],  m:[200,200] },
  logo:    { d:[240,80],   m:[180,60] },
  card:    { d:[480,320],  m:[560,360] },
  generic: { d:[1200,800], m:[720,900] },
};
const PURPOSE_RE = [
  [/hero|jumbotron|masthead|главн|обложк.*верх|шапк/i, 'hero'],
  [/gallery|carousel|slider|lightbox|галере|слайд|карусел/i, 'gallery'],
  [/banner|promo|cta-?image|баннер|промо/i, 'banner'],
  [/cover|thumbnail|thumb|preview|og-?image|превью|обложк/i, 'cover'],
  [/avatar|profile|headshot|photo-?round|аватар|профил|команд|сотрудник/i, 'avatar'],
  [/logo|brandmark|лого/i, 'logo'],
  [/feature|benefit|service|step|услуг|преимущест|фича|шаг/i, 'feature'],
  [/card|tile|item|карточк|плитк/i, 'card'],
];
const EXT = new Set(['.tsx','.jsx','.ts','.js','.astro','.vue','.svelte','.html','.htm','.css','.scss']);
const SKIP = new Set(['node_modules','.next','.git','dist','build','out','.turbo','coverage','.cache']);

function walk(root, acc, depth=0){
  if (depth > 8) return;
  let ents;
  try { ents = fs.readdirSync(root, { withFileTypes:true }); } catch { return; }
  for (const e of ents){
    if (e.name.startsWith('.') && e.name !== '.') { if (SKIP.has(e.name)) continue; }
    const p = path.join(root, e.name);
    if (e.isDirectory()){ if (!SKIP.has(e.name)) walk(p, acc, depth+1); }
    else if (EXT.has(path.extname(e.name))) acc.push(p);
  }
}

function purposeFor(hint){
  for (const [re,p] of PURPOSE_RE) if (re.test(hint)) return p;
  return null;
}

function main(){
  const target = arg('path');
  const max = Number(arg('max', 24));
  if (!target) out({ok:false,error:'usage: --path <dir|file>'});
  if (!fs.existsSync(target)) out({ok:false,error:'path not found',path:target});

  const files = [];
  const st = fs.statSync(target);
  if (st.isDirectory()) walk(target, files); else files.push(target);

  const slots = [];
  const seen = new Set();
  const addSlot = (purpose, hint, explicit) => {
    const pu = purpose || purposeFor(hint) || 'generic';
    const pr = PRESET[pu] || PRESET.generic;
    let d = pr.d, m = pr.m;
    if (explicit && explicit.w>0 && explicit.h>0){
      d = [explicit.w, explicit.h];
      const mw = Math.min(explicit.w, 760);
      m = [mw, Math.round(mw * explicit.h/explicit.w)];
    }
    const key = `${pu}:${d[0]}x${d[1]}`;
    if (seen.has(key)) return;
    seen.add(key);
    slots.push({ id:`slot-${slots.length+1}-${pu}`, purpose:pu,
      desktop:{w:d[0],h:d[1]}, mobile:{w:m[0],h:m[1]}, format:'webp',
      source_hint: hint.slice(0,60) });
  };

  for (const f of files){
    let src=''; try { src = fs.readFileSync(f,'utf8'); } catch { continue; }
    const base = path.basename(f);
    // next/image + <Image ...>  (назначение — по alt+class элемента, НЕ по имени файла)
    for (const m of src.matchAll(/<Image\b([^>]*)>/g)){
      const attrs = m[1];
      const w = +(attrs.match(/\bwidth=\{?["']?(\d+)/)?.[1]||0);
      const h = +(attrs.match(/\bheight=\{?["']?(\d+)/)?.[1]||0);
      const alt = attrs.match(/\balt=["']([^"']*)/)?.[1] || '';
      addSlot(null, `${alt} ${attrs.match(/className=["']([^"']*)/)?.[1]||''}`, {w,h});
    }
    // <img ...>
    for (const m of src.matchAll(/<img\b([^>]*)>/gi)){
      const attrs = m[1];
      const w = +(attrs.match(/\bwidth=["']?(\d+)/)?.[1]||0);
      const h = +(attrs.match(/\bheight=["']?(\d+)/)?.[1]||0);
      const alt = attrs.match(/\balt=["']([^"']*)/)?.[1] || '';
      addSlot(null, `${alt} ${attrs.match(/class(Name)?=["']([^"']*)/)?.[2]||''}`, {w,h});
    }
    // background-image url()
    for (const m of src.matchAll(/background(-image)?\s*:\s*[^;]*url\(/gi))
      addSlot(purposeFor(base) || 'banner', base, null);
    // именованные компоненты Hero/Gallery/... даже без явного img
    for (const m of src.matchAll(/<(Hero|Feature[A-Za-z]*|Gallery|Banner|Cover|Avatar|Logo|Masthead)\b/g))
      addSlot(purposeFor(m[1]), `${base} <${m[1]}>`, null);
    if (slots.length >= max) break;
  }

  if (slots.length === 0){
    out({ ok:true, slots:[], fallback:true,
      reason:'В шаблоне не найдено image-слотов (нет <Image>/<img>/background-image/именованных компонентов). Уточни назначение вручную.' });
  }
  out({ ok:true, slots: slots.slice(0,max), fallback:false, files_scanned: files.length });
}
main();
