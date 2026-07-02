// Screenshot a page at an EXACT aspect ratio (matches the detected screen quad,
// so the composite needs zero cropping). Usage:
//   node shot-aspect.mjs <url> <aspect> <out.png> [viewportWidth=1440]
import { chromium } from 'playwright';

const [url, aspectS, out, wS] = process.argv.slice(2);
const aspect = parseFloat(aspectS);
const vw = parseInt(wS || '1440', 10);
const vh = Math.round(vw / aspect);

const browser = await chromium.launch({ args: ['--disable-dev-shm-usage'] });
try {
  const page = await browser.newPage({
    viewport: { width: vw, height: vh },
    deviceScaleFactor: 2,
  });
  await page.goto(url, { waitUntil: 'networkidle', timeout: 45000 });
  await page.waitForTimeout(1500);
  await page.screenshot({ path: out });
  console.log(JSON.stringify({ ok: true, out, viewport: `${vw}x${vh}`, px: `${vw * 2}x${vh * 2}` }));
} catch (e) {
  console.log(JSON.stringify({ ok: false, error: String(e && e.message || e) }));
  process.exitCode = 1;
} finally {
  await browser.close();
}
