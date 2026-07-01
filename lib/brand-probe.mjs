#!/usr/bin/env node
/*
 * brand-probe.mjs — вытащить брендовые сигналы из публичной страницы.
 * SSRF-guarded fetch (assertSafeUrl). Без браузера — обычный fetch + regex по HTML.
 *
 * Usage: node brand-probe.mjs --url <url> [--timeout 15000]
 * stdout: JSON {ok, name, logo, themeColor, description, vibe:[..], lang}
 */
import { assertSafeUrl } from './ssrf.mjs';

function arg(n, d){ const i=process.argv.indexOf('--'+n); return i<0?d:(process.argv[i+1]??d); }
function out(o){ console.log(JSON.stringify(o)); }

function meta(html, re){ const m = html.match(re); return m ? m[1].trim() : null; }
function abs(base, u){ try { return u ? new URL(u, base).href : null; } catch { return null; } }

async function main(){
  const url = arg('url');
  if (!url) { out({ok:false,error:'usage: --url <url>'}); process.exit(1); }
  const timeout = Number(arg('timeout', 15000));
  let u;
  try { u = await assertSafeUrl(url); }
  catch(e){ out({ok:false,error:e.message,reason:e.reason}); process.exit(1); }

  let html = '';
  try {
    const ctl = AbortSignal.timeout(timeout);
    const r = await fetch(u.href, { signal: ctl, redirect: 'follow',
      headers: { 'user-agent': 'Mozilla/5.0 (compatible; content-mockup/1.0)' } });
    html = (await r.text()).slice(0, 500_000);
  } catch(e){ out({ok:false,error:`fetch failed: ${e.message}`}); process.exit(1); }

  const name =
    meta(html, /<meta[^>]+property=["']og:site_name["'][^>]+content=["']([^"']+)/i) ||
    meta(html, /<meta[^>]+name=["']application-name["'][^>]+content=["']([^"']+)/i) ||
    meta(html, /<title[^>]*>([^<]+)<\/title>/i) || u.hostname;
  const logo = abs(u.href,
    meta(html, /<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)/i) ||
    meta(html, /<link[^>]+rel=["'][^"']*icon[^"']*["'][^>]+href=["']([^"']+)/i));
  const themeColor = meta(html, /<meta[^>]+name=["']theme-color["'][^>]+content=["']([^"']+)/i);
  const description =
    meta(html, /<meta[^>]+name=["']description["'][^>]+content=["']([^"']+)/i) ||
    meta(html, /<meta[^>]+property=["']og:description["'][^>]+content=["']([^"']+)/i) || '';
  const lang = meta(html, /<html[^>]+lang=["']([^"']+)/i) || null;
  const h1 = meta(html, /<h1[^>]*>([\s\S]{0,120}?)<\/h1>/i)?.replace(/<[^>]+>/g,'').trim() || '';

  // грубые «вайб»-ключевики из текста (для контекст-промптов ветки C)
  const text = (description + ' ' + h1 + ' ' + name).toLowerCase();
  const vibe = [];
  const dict = {
    'баня|сауна|парн|веник|banya|sauna|spa|спа|термы': 'spa-sauna',
    'ресторан|кафе|кухн|еда|restaurant|cafe|food|бар': 'food',
    'фитнес|спорт|gym|тренаж|йога|yoga': 'fitness',
    'клиник|мед|health|dental|стомат|доктор': 'medical',
    'недвиж|estate|кварти|дом|строит|architect|интерьер': 'realestate',
    'магазин|shop|store|купить|товар|market': 'ecommerce',
    'красот|салон|beauty|nails|барбер|barber': 'beauty',
    'it|tech|saas|app|software|платформ|стартап|startup': 'tech',
    'отель|hotel|hostel|тур|travel|путеш': 'travel',
  };
  for (const [k, tag] of Object.entries(dict))
    if (new RegExp(k).test(text)) vibe.push(tag);

  out({ ok:true, name: name.slice(0,80), logo, themeColor,
        description: description.slice(0,200), vibe, lang, host: u.hostname });
}
main();
