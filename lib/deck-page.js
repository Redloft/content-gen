#!/usr/bin/env node
/*
 * deck-page.js — собрать локальную HTML-«тиндер»-колоду мокап-вариантов.
 * Пользователь листает карточки (👍/👎, оценка 1-5, 💬 коммент), решение
 * POST'ится на localhost feedback-server (bearer token). Ответы:
 *   {card_id, liked:bool|null, score:1-5|null, verdict:'like'|'dislike'|'skip', comment}
 *
 * Usage:
 *   node deck-page.js --cards cards.json --out page.html \
 *       --port <n> --token <hex> --nonce <uuid> [--round 1] [--title "..."]
 * cards.json: [{card_id, image:"relative.png", label, meta}]  (image — путь ОТНОСИТЕЛЬНО page.html)
 */
const fs = require('fs');
const path = require('path');

function arg(n, d) { const i = process.argv.indexOf('--' + n); return i < 0 ? d : process.argv[i + 1]; }
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));

const cardsPath = arg('cards'), outPath = arg('out');
const port = arg('port'), token = arg('token'), nonce = arg('nonce');
const round = Number(arg('round', '1')), title = arg('title', 'Мокапы — выбор направления');
if (!cardsPath || !outPath || !port || !token || !nonce) {
  console.error('usage: --cards --out --port --token --nonce [--round --title]'); process.exit(64);
}
const cards = JSON.parse(fs.readFileSync(cardsPath, 'utf8'));
const CARDS_JSON = JSON.stringify(cards.map(c => ({
  card_id: c.card_id, image: c.image, label: c.label || '', meta: c.meta || '' })));

const html = `<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)}</title>
<style>
  :root{--bg:#0f1117;--fg:#e8eaed;--mut:#9aa0aa;--line:#252a33;--acc:#f5b942;--like:#27c93f;--dis:#ff5f56}
  *{box-sizing:border-box} body{margin:0;background:var(--bg);color:var(--fg);
    font:15px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;display:flex;flex-direction:column;align-items:center;min-height:100vh}
  header{padding:16px;text-align:center} h1{font-size:18px;margin:0 0 4px} .sub{color:var(--mut);font-size:13px}
  .stage{position:relative;width:min(92vw,860px);flex:1;display:flex;flex-direction:column;align-items:center;gap:12px}
  .card{width:100%;background:#151922;border:1px solid var(--line);border-radius:16px;overflow:hidden}
  .card img{width:100%;display:block;background:#0b0d12;max-height:64vh;object-fit:contain}
  .clabel{padding:10px 14px;font-size:14px;color:var(--mut);display:flex;justify-content:space-between;gap:8px}
  .ratings{display:flex;gap:6px;justify-content:center;margin:2px 0}
  .star{font-size:26px;cursor:pointer;filter:grayscale(1);opacity:.5}
  .star.on{filter:none;opacity:1}
  .cmt{width:100%} .cmt textarea{width:100%;min-height:52px;background:#0b0d12;color:var(--fg);
    border:1px solid var(--line);border-radius:10px;padding:8px;font:inherit;resize:vertical}
  .acts{display:flex;gap:10px;justify-content:center;flex-wrap:wrap;padding-bottom:8px}
  button{font:inherit;border-radius:12px;padding:11px 18px;cursor:pointer;border:1px solid var(--line);background:#1b2130;color:var(--fg)}
  .dis{border-color:var(--dis)} .like{border-color:var(--like)}
  .primary{background:var(--acc);color:#000;border:0;font-weight:700}
  .nav{position:absolute;top:40%;background:#1b2130cc;border:1px solid var(--line);border-radius:50%;width:42px;height:42px}
  .prev{left:-8px} .next{right:-8px}
  .counter{color:var(--mut);font-size:13px;margin:4px}
  #end{display:none;text-align:center;padding:24px} #end.show{display:block}
  .toast{position:fixed;bottom:16px;background:#1b2130;border:1px solid var(--line);padding:10px 16px;border-radius:10px;opacity:0;transition:.3s}
  .toast.show{opacity:1}
</style></head><body>
<header><h1>${esc(title)}</h1><div class="sub">Лайкай направления, что нравятся. Стрелка вправо — пропустить. В конце — «Отправить».</div></header>
<div class="stage">
  <button class="nav prev" id="prev" aria-label="назад">‹</button>
  <button class="nav next" id="next" aria-label="пропустить">›</button>
  <div class="card"><img id="img" alt=""><div class="clabel"><span id="label"></span><span id="meta"></span></div></div>
  <div class="ratings" id="stars"></div>
  <div class="cmt"><textarea id="cmt" placeholder="💬 что именно нравится/не так (необязательно)"></textarea></div>
  <div class="counter" id="counter"></div>
  <div class="acts">
    <button class="dis" id="b-dis">👎 не то</button>
    <button class="like" id="b-like">👍 нравится</button>
    <button class="primary" id="b-submit">Отправить выбор →</button>
  </div>
</div>
<div id="end"><h2>Готово ✓</h2><p class="sub">Ответы отправлены. Можно закрыть вкладку.</p>
  <button class="primary" id="copy">📋 скопировать JSON (fallback)</button></div>
<div class="toast" id="toast"></div>
<script>
const CARDS=${CARDS_JSON}, PORT=${JSON.stringify(port)}, TOKEN=${JSON.stringify(token)},
      NONCE=${JSON.stringify(nonce)}, ROUND=${round};
const $=id=>document.getElementById(id);
const ST=CARDS.map(c=>({card_id:c.card_id,liked:null,score:null,verdict:'skip',comment:''}));
let i=0;
function toast(t){const el=$('toast');el.textContent=t;el.classList.add('show');setTimeout(()=>el.classList.remove('show'),1400);}
function renderStars(){const box=$('stars');box.innerHTML='';for(let n=1;n<=5;n++){const s=document.createElement('span');
  s.className='star'+((ST[i].score>=n)?' on':'');s.textContent='★';
  s.onclick=()=>{ST[i].score=(ST[i].score===n?null:n);render();};box.appendChild(s);} }
function render(){const c=CARDS[i],s=ST[i];
  $('img').src=c.image;$('img').alt=c.label||'';$('label').textContent=c.label||'';$('meta').textContent=c.meta||'';
  $('cmt').value=s.comment;$('counter').textContent=(i+1)+' / '+CARDS.length+
    '  ·  '+(s.verdict==='like'?'👍':s.verdict==='dislike'?'👎':'—');
  $('b-like').style.outline=s.verdict==='like'?'2px solid var(--like)':'';
  $('b-dis').style.outline=s.verdict==='dislike'?'2px solid var(--dis)':'';
  renderStars();}
function go(d){$('cmt').blur();i=(i+d+CARDS.length)%CARDS.length;render();}
$('cmt').addEventListener('input',e=>ST[i].comment=e.target.value);
$('b-like').onclick=()=>{ST[i].verdict='like';ST[i].liked=true;if(!ST[i].score)ST[i].score=4;render();if(i<CARDS.length-1)go(1);};
$('b-dis').onclick=()=>{ST[i].verdict='dislike';ST[i].liked=false;render();if(i<CARDS.length-1)go(1);};
$('prev').onclick=()=>go(-1);$('next').onclick=()=>go(1);
document.onkeydown=e=>{if(e.key==='ArrowRight')go(1);if(e.key==='ArrowLeft')go(-1);
  if(e.key.toLowerCase()==='l')$('b-like').click();if(e.key.toLowerCase()==='d')$('b-dis').click();};
async function submit(){const payload={round:ROUND,round_nonce:NONCE,answers:ST};
  try{const r=await fetch('http://127.0.0.1:'+PORT+'/round',{method:'POST',
      headers:{'Content-Type':'application/json','Authorization':'Bearer '+TOKEN},body:JSON.stringify(payload)});
    if(r.ok){$('.stage');document.querySelector('.stage').style.display='none';$('end').classList.add('show');}
    else toast('сервер: '+r.status+' — используй копирование JSON');}
  catch(e){toast('нет связи с сервером — скопируй JSON');$('end').classList.add('show');document.querySelector('.stage').style.display='none';}
  window.__PAYLOAD=payload;}
$('b-submit').onclick=submit;
$('copy').onclick=async()=>{await navigator.clipboard.writeText(JSON.stringify(window.__PAYLOAD||{round:ROUND,round_nonce:NONCE,answers:ST}));toast('скопировано');};
render();
// keepalive пинг
setInterval(()=>fetch('http://127.0.0.1:'+PORT+'/ping').catch(()=>{}),60000);
</script></body></html>`;

fs.writeFileSync(outPath, html);
console.log(JSON.stringify({ ok: true, out: outPath, cards: cards.length }));
