#!/usr/bin/env node
/*
 * record.mjs — T1 (explore): запись реального взаимодействия со страницей в WebM.
 * Сиблинг capture.mjs (SCREENCAST-SPEC §4 T1, §5 clicks, §8.1 SSRF route-level).
 *
 * Безопасность:
 *   - assertSafeUrl на entry + installRouteGuard (ssrf-route.mjs) на КАЖДЫЙ подзапрос
 *   - scroll/scenario watchdog 45s (Promise.race) — §8.4
 *   - page/context/browser.close() в finally
 *
 * Без сценария — плавный easing-скролл до конца страницы (smoothstep по времени,
 * НЕ behavior:'smooth' браузера). Со сценарием — шаги scroll|hover|click|wait (§5).
 *
 * Usage:
 *   node record.mjs --url <url> --out <file.webm> --viewport desktop|mobile|tablet
 *       [--scenario steps.json] [--speed 800] [--max-duration 60] [--timeout 15000]
 * stdout: JSON {ok, video, viewport, steps_done, blocked_hosts, warnings}
 */
import { chromium, devices } from 'playwright';
import path from 'node:path';
import fs from 'node:fs';
import { assertSafeUrl } from './ssrf.mjs';
import { installRouteGuard } from './ssrf-route.mjs';

// геометрия — та же таблица, что capture.mjs / screencast-matrix.json (viewports)
const VIEWPORTS = {
  desktop: { width: 1440, height: 900,  dsf: 2, preset: null },
  tablet:  { width: 834,  height: 1112, dsf: 2, preset: 'iPad Pro 11' },
  mobile:  { width: 390,  height: 844,  dsf: 3, preset: 'iPhone 13' },
};
const SCENARIO_WATCHDOG_MS = 45_000;   // §8.4 scroll-script watchdog

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
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// плавный скролл к targetY за ~len/speed секунд, smoothstep, через rAF в странице
async function smoothScrollTo(page, targetY, speedPx) {
  await page.evaluate(async ({ targetY, speedPx }) => {
    const startY = window.scrollY;
    const dist = targetY - startY;
    if (Math.abs(dist) < 2) return;
    const durMs = Math.min(Math.max((Math.abs(dist) / speedPx) * 1000, 300), 40_000);
    const t0 = performance.now();
    await new Promise((done) => {
      const tick = (now) => {
        const x = Math.min((now - t0) / durMs, 1);
        const s = 3 * x * x - 2 * x * x * x;            // smoothstep
        window.scrollTo(0, startY + dist * s);
        if (x < 1) requestAnimationFrame(tick); else done();
      };
      requestAnimationFrame(tick);
    });
  }, { targetY, speedPx });
}

async function runScenario(page, steps, speedPx, warnings, state) {
  for (const st of steps) {
    if (state.cancelled) break;            // кооперативная отмена по watchdog (finalize warn #6)
    switch (st.action) {
      case 'scroll': {
        let y;
        if (st.to && typeof st.to === 'string' && st.to !== 'bottom') {
          y = await page.evaluate((sel) => {
            const el = document.querySelector(sel);
            return el ? el.getBoundingClientRect().top + window.scrollY - 80 : null;
          }, st.to);
          if (y == null) { warnings.push(`scroll: selector not found: ${st.to}`); break; }
        } else if (st.to === 'bottom' || st.to === undefined) {
          y = await page.evaluate(() => document.documentElement.scrollHeight - window.innerHeight);
        } else { y = Number(st.to) || 0; }
        await smoothScrollTo(page, y, st.speed || speedPx);
        break;
      }
      case 'hover':
        await page.hover(st.selector, { timeout: 5000 }).catch(() => warnings.push(`hover failed: ${st.selector}`));
        break;
      case 'click':
        await page.click(st.selector, { timeout: 5000 }).catch(() => warnings.push(`click failed: ${st.selector}`));
        break;
      case 'wait':
        await sleep(Math.min(Number(st.ms) || 500, 10_000));
        break;
      default:
        warnings.push(`unknown action: ${st.action}`);
        continue;
    }
    state.done++;                          // mutable-счётчик: обрыв не репортит 0
    if (st.dwell) await sleep(Math.min(Number(st.dwell), 5000));
  }
}

async function main() {
  const url = arg('url');
  const out = arg('out');
  const vpName = String(arg('viewport', 'desktop'));
  const scenarioPath = arg('scenario', null);
  const speedPx = Math.min(Math.max(Number(arg('speed', 800)), 100), 3000);
  const maxDur = Math.min(Number(arg('max-duration', 60)), 60) * 1000;
  const timeout = Number(arg('timeout', 15000));

  if (!url || !out) fail('usage: --url <url> --out <file.webm> [--viewport ...]');
  const cfg = VIEWPORTS[vpName];
  if (!cfg) fail(`unknown viewport: ${vpName} (allowed: ${Object.keys(VIEWPORTS).join(',')})`);

  let steps = null;
  if (scenarioPath) {
    try { steps = JSON.parse(fs.readFileSync(scenarioPath, 'utf8')).steps; } catch (e) { fail(`bad scenario: ${e.message}`); }
    if (!Array.isArray(steps) || !steps.length) fail('scenario.steps empty');
  }

  try { await assertSafeUrl(url); } catch (e) { fail(e.message, { reason: e.reason || 'ssrf' }); }

  const outDir = path.dirname(path.resolve(out));
  fs.mkdirSync(outDir, { recursive: true });
  const warnings = [];
  const browser = await chromium.launch({ args: ['--disable-dev-shm-usage'] });
  let ctx, page, videoPath = null, stepsDone = 0, guard;

  try {
    const preset = cfg.preset ? devices[cfg.preset] : {};
    ctx = await browser.newContext({
      ...preset,
      viewport: { width: cfg.width, height: cfg.height },
      deviceScaleFactor: cfg.dsf,
      // recordVideo НЕ применяет deviceScaleFactor к холсту видео — размер задаётся в
      // CSS-пикселях вьюпорта. Если поставить ×dsf, страница займёт левый верхний угол,
      // остальное = серый фон. Поэтому size = viewport 1:1 (полное заполнение кадра).
      recordVideo: { dir: outDir, size: { width: cfg.width, height: cfg.height } },
    });
    guard = await installRouteGuard(ctx);        // §8.1: SSRF на всю сессию записи
    page = await ctx.newPage();

    await page.goto(url, { timeout, waitUntil: 'networkidle' }).catch(async () => {
      warnings.push('networkidle timeout, using domcontentloaded');
      await page.goto(url, { timeout, waitUntil: 'domcontentloaded' });
    });
    await sleep(800);                             // дать hero-анимациям отыграть

    // сценарий (или дефолтный полный скролл) под watchdog §8.4 + общий cap длины.
    // Отмена КООПЕРАТИВНАЯ (finalize warn #6): watchdog ставит флаг, work выходит
    // между шагами и мы ЖДЁМ его завершения до page.close() — никакого race с teardown.
    const runState = { cancelled: false, done: 0 };
    const work = (async () => {
      if (steps) {
        await runScenario(page, steps, speedPx, warnings, runState);
      } else {
        const bottom = await page.evaluate(() => document.documentElement.scrollHeight - window.innerHeight);
        await smoothScrollTo(page, bottom, speedPx);
        runState.done = 1;
      }
      await sleep(600);                           // хвост после последнего действия
    })().catch((e) => warnings.push(`scenario error: ${e.message}`));
    const wdMs = Math.min(SCENARIO_WATCHDOG_MS, maxDur);
    const timedOut = await Promise.race([
      work.then(() => false),
      sleep(wdMs).then(() => true),
    ]);
    if (timedOut) {
      runState.cancelled = true;
      warnings.push(`scenario watchdog fired (${wdMs}ms) — запись обрезана после ${runState.done} шагов`);
      // дать текущему Playwright-шагу дозавершиться (шаги имеют собственные timeout ≤5-10s)
      await Promise.race([work, sleep(12_000)]);
    }
    stepsDone = runState.done;

    const video = page.video();
    await page.close();                           // финализирует запись
    await ctx.close();
    if (video) {
      const tmp = await video.path();
      fs.renameSync(tmp, out);
      videoPath = out;
    }
  } catch (e) {
    try { await ctx?.close(); } catch {}
    await browser.close();
    fail(`record failed: ${e.message}`);
  }
  await browser.close();

  if (!videoPath || !fs.existsSync(videoPath)) fail('no video produced');
  const bytes = fs.statSync(videoPath).size;
  if (bytes > 200 * 1024 * 1024) {               // §8.4 WebM cap
    fs.unlinkSync(videoPath);
    fail(`webm exceeds 200MB cap (${bytes})`);
  }

  console.log(JSON.stringify({
    ok: true, video: videoPath, viewport: vpName, bytes,
    steps_done: stepsDone, blocked_hosts: guard.blocked(), warnings,
  }));
}

main();
