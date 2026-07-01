#!/usr/bin/env node
/*
 * capture.mjs — Playwright-скриншоты сайта в нескольких viewport + опц. замер image-слотов.
 *
 * Безопасность (plan-panel critical #2 SSRF):
 *   - только http/https схемы (file:/data:/javascript: — reject)
 *   - hostname резолвится и проверяется: приватные/loopback/link-local/metadata IP → abort
 *   - request-interception: КАЖДЫЙ подзапрос страницы к приватному IP тоже abort
 *   - hard timeout на goto + лимит редиректов + page.close() в finally
 *
 * Usage:
 *   node capture.mjs --url <url> --out-dir <dir>
 *       [--viewports desktop,mobile,tablet] [--full-page]
 *       [--measure-slots] [--timeout 30000]
 * stdout: JSON {ok, url, shots:[{viewport,w,h,file}], slots?:[...], warnings:[]}
 */
import { chromium } from 'playwright';
import path from 'node:path';
import fs from 'node:fs';
import { hostIsPublic } from './ssrf.mjs';

const VIEWPORTS = {
  desktop: { width: 1440, height: 900, isMobile: false, dsf: 2 },
  tablet:  { width: 834,  height: 1112, isMobile: true,  dsf: 2 },
  mobile:  { width: 390,  height: 844,  isMobile: true,  dsf: 3 },
};

function arg(name, def) {
  const i = process.argv.indexOf('--' + name);
  if (i < 0) return def;
  const v = process.argv[i + 1];
  return v && !v.startsWith('--') ? v : true;
}
function fail(msg, extra = {}) {
  console.log(JSON.stringify({ ok: false, error: msg, ...extra }));
  process.exit(1);
}

async function main() {
  const url = arg('url');
  const outDir = arg('out-dir');
  if (!url || !outDir) fail('usage: --url <url> --out-dir <dir>');
  const timeout = Number(arg('timeout', 30000));
  const fullPage = !!arg('full-page', false);
  const measure = !!arg('measure-slots', false);
  const vps = String(arg('viewports', 'desktop,mobile')).split(',')
    .map(s => s.trim()).filter(v => VIEWPORTS[v]);
  if (!vps.length) fail('no valid viewports');

  let u;
  try { u = new URL(url); } catch { fail('invalid url'); }
  if (!/^https?:$/.test(u.protocol)) fail('only http/https allowed', { scheme: u.protocol });
  if (!(await hostIsPublic(u.hostname)))
    fail('SSRF blocked: url resolves to a private/loopback/metadata address', { host: u.hostname });

  fs.mkdirSync(outDir, { recursive: true });
  const warnings = [];
  const browser = await chromium.launch({ args: ['--disable-dev-shm-usage'] });
  const shots = [];
  let slots = null;

  try {
    for (const vp of vps) {
      const cfg = VIEWPORTS[vp];
      const ctx = await browser.newContext({
        viewport: { width: cfg.width, height: cfg.height },
        deviceScaleFactor: cfg.dsf,
        isMobile: cfg.isMobile,
        userAgent: cfg.isMobile
          ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148'
          : undefined,
      });
      // SSRF на КАЖДЫЙ запрос: приватный хост → abort
      await ctx.route('**/*', async (route) => {
        try {
          const h = new URL(route.request().url()).hostname;
          if (!(await hostIsPublic(h))) return route.abort();
          return route.continue();
        } catch { return route.abort(); }
      });
      const page = await ctx.newPage();
      let redirects = 0;
      page.on('response', (r) => { if ([301,302,303,307,308].includes(r.status())) redirects++; });
      try {
        await page.goto(url, { timeout, waitUntil: 'networkidle' }).catch(async () => {
          // networkidle не дождались — берём domcontentloaded как fallback
          warnings.push(`${vp}: networkidle timeout, using domcontentloaded`);
          await page.goto(url, { timeout, waitUntil: 'domcontentloaded' });
        });
        if (redirects > 15) warnings.push(`${vp}: many redirects (${redirects})`);
        await page.waitForTimeout(800);
        const file = path.join(outDir, `shot-${vp}.png`);
        await page.screenshot({ path: file, fullPage });
        const dim = await page.evaluate(() => ({ w: document.documentElement.clientWidth, h: document.documentElement.clientHeight }));
        shots.push({ viewport: vp, w: cfg.width, h: fullPage ? null : cfg.height, file });

        if (measure && slots === null && vp === vps[0]) {
          // замер слотов на первом (desktop) viewport
          slots = await page.evaluate(() => {
            const out = [];
            const push = (el, kind) => {
              const r = el.getBoundingClientRect();
              if (r.width < 80 || r.height < 60) return;
              out.push({ kind, w: Math.round(r.width), h: Math.round(r.height),
                         ratio: +(r.width / r.height).toFixed(3),
                         alt: (el.alt || el.getAttribute?.('aria-label') || '').slice(0, 60) });
            };
            document.querySelectorAll('img, picture > img, [role=img]').forEach(e => push(e, 'img'));
            document.querySelectorAll('*').forEach(e => {
              const bg = getComputedStyle(e).backgroundImage;
              if (bg && bg !== 'none' && bg.includes('url(')) push(e, 'bg');
            });
            // дедуп по (w,h,kind), сорт по площади
            const seen = new Set(); const uniq = [];
            for (const s of out.sort((a,b)=>b.w*b.h-a.w*a.h)) {
              const k = `${s.kind}:${s.w}x${s.h}`;
              if (!seen.has(k)) { seen.add(k); uniq.push(s); }
            }
            return uniq.slice(0, 24);
          });
        }
      } finally {
        await page.close().catch(()=>{});
        await ctx.close().catch(()=>{});
      }
    }
  } catch (e) {
    await browser.close().catch(()=>{});
    fail(`capture failed: ${e.message}`, { warnings });
  }
  await browser.close().catch(()=>{});
  console.log(JSON.stringify({ ok: true, url, shots, slots, warnings }));
}
main();
