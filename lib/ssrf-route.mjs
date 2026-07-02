// ssrf-route.mjs — route-level SSRF enforcement для записи (SCREENCAST-SPEC §8.1).
// Аддитивный модуль (§11): ssrf.mjs не трогаем, capture.mjs держит свой inline-вариант.
// Отличие от inline: живёт всю сессию записи (T1 — десятки секунд), считает блокировки.
import { hostIsPublic } from './ssrf.mjs';

/**
 * Повесить SSRF-guard на КАЖДЫЙ запрос контекста: DNS-resolve → приватный/loopback/
 * metadata/IPv6-private → abort. Возвращает счётчик для диагностики.
 * @param {import('playwright').BrowserContext} ctx
 * @returns {{blocked: () => string[]}}
 */
export async function installRouteGuard(ctx) {
  const blockedHosts = new Set();          // Set сразу — без unbounded-роста массива
  await ctx.route('**/*', async (route) => {
    try {
      const u = new URL(route.request().url());
      // явный scheme-check (SPEC §8.1, finalize warn #4) — не полагаемся на побочный
      // эффект пустого hostname у file:/data:/javascript:
      if (!/^https?:$/.test(u.protocol)) {
        if (blockedHosts.size < 500) blockedHosts.add(`${u.protocol}//`);
        return route.abort();
      }
      if (!(await hostIsPublic(u.hostname))) {
        if (blockedHosts.size < 500) blockedHosts.add(u.hostname);
        return route.abort();
      }
      return route.continue();
    } catch {
      return route.abort();
    }
  });
  return { blocked: () => [...blockedHosts] };
}
