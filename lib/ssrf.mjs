// ssrf.mjs — общий egress-guard для Playwright/fetch (plan-panel critical #2).
import dns from 'node:dns/promises';
import net from 'node:net';

export function isPrivateIP(ip) {
  if (net.isIPv4(ip)) {
    const p = ip.split('.').map(Number);
    if (p[0] === 10) return true;
    if (p[0] === 127) return true;
    if (p[0] === 0) return true;
    if (p[0] === 169 && p[1] === 254) return true;          // link-local + metadata
    if (p[0] === 172 && p[1] >= 16 && p[1] <= 31) return true;
    if (p[0] === 192 && p[1] === 168) return true;
    if (p[0] === 100 && p[1] >= 64 && p[1] <= 127) return true; // CGNAT
    return false;
  }
  if (net.isIPv6(ip)) {
    // IPv4-mapped в точечной записи (::ffff:a.b.c.d) — до хекстет-разбора
    const mapped = ip.toLowerCase().match(/:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/);
    if (mapped) return isPrivateIP(mapped[1]);
    // нормализуем в 8 групп — ловим и сжатые (::1), и расширенные (0:0:...:1) формы
    let groups;
    try {
      const [h, t] = ip.toLowerCase().split('::');
      const head = h ? h.split(':') : [];
      if (t === undefined) { groups = head; }
      else {
        const tail = t ? t.split(':') : [];
        groups = [...head, ...Array(8 - head.length - tail.length).fill('0'), ...tail];
      }
      groups = groups.map(g => parseInt(g || '0', 16) & 0xffff);
    } catch { return true; }
    if (groups.length !== 8) return true;                         // разобрать не смогли → небезопасно
    if (groups.slice(0, 7).every(g => g === 0) && groups[7] <= 1) return true; // :: и ::1
    if ((groups[0] & 0xfe00) === 0xfc00) return true;             // fc00::/7 (ULA)
    if ((groups[0] & 0xffc0) === 0xfe80) return true;             // fe80::/10 (link-local)
    if (groups.slice(0, 5).every(g => g === 0) && groups[5] === 0xffff) { // ::ffff:a.b.c.d
      return isPrivateIP(`${groups[6] >> 8}.${groups[6] & 0xff}.${groups[7] >> 8}.${groups[7] & 0xff}`);
    }
    return false;
  }
  return true;
}

export async function hostIsPublic(hostname) {
  const h = String(hostname).replace(/^\[|\]$/g, '');   // IPv6 из URL приходит в скобках [..]
  if (net.isIP(h)) return !isPrivateIP(h);
  try {
    const recs = await dns.lookup(h, { all: true });
    if (!recs.length) return false;
    return recs.every(r => !isPrivateIP(r.address));
  } catch { return false; }
}

// Проверить URL целиком: схема http/https + публичный хост. Кидает Error с .reason.
export async function assertSafeUrl(url) {
  let u;
  try { u = new URL(url); } catch { const e = new Error('invalid url'); e.reason = 'invalid'; throw e; }
  if (!/^https?:$/.test(u.protocol)) { const e = new Error('only http/https allowed'); e.reason = 'scheme'; throw e; }
  if (!(await hostIsPublic(u.hostname))) {
    const e = new Error('SSRF blocked: private/loopback/metadata address'); e.reason = 'ssrf'; throw e;
  }
  return u;
}
