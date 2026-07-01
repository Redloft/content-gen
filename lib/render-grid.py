#!/usr/bin/env python3
"""Generate HTML grid preview for content-gen results."""
import os, sys, json, glob, html
from pathlib import Path

OUTDIR = Path(sys.argv[1])
prompt = sys.argv[2] if len(sys.argv) > 2 else ""

# Find all PNG/JPG/WEBP in the dir
images = []
for ext in ("png", "jpg", "jpeg", "webp"):
    for p in sorted(OUTDIR.glob(f"*.{ext}")):
        if p.name == "preview.html":
            continue
        size = p.stat().st_size
        images.append({
            "name": p.stem,
            "file": p.name,
            "path": str(p),
            "size_kb": size // 1024,
        })

# Find errors
errors = []
for p in sorted(OUTDIR.glob("*.error.txt")):
    name = p.stem.replace(".error", "")
    err = p.read_text(encoding="utf-8")[:300]
    errors.append({"name": name, "err": err})

# Render HTML
items_html = ""
for img in images:
    items_html += f"""
    <figure class="card">
      <a href="{html.escape(img['file'])}" target="_blank">
        <img src="{html.escape(img['file'])}" alt="{html.escape(img['name'])}" loading="lazy">
      </a>
      <figcaption>
        <strong>{html.escape(img['name'])}</strong>
        <span class="meta">{img['size_kb']} KB</span>
        <button class="copy-btn" onclick="copyPath('{html.escape(img['path'])}')">📋 copy path</button>
      </figcaption>
    </figure>
"""

errors_html = ""
if errors:
    items = "".join(f"<li><strong>{html.escape(e['name'])}</strong>: <code>{html.escape(e['err'])}</code></li>" for e in errors)
    errors_html = f'<details><summary>⚠️ {len(errors)} ошибок</summary><ul>{items}</ul></details>'

html_out = f"""<!doctype html>
<html lang="ru"><head>
<meta charset="utf-8">
<title>content-gen — {html.escape(prompt[:60])}</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ font-family: -apple-system, system-ui, sans-serif; margin: 0; padding: 24px; background: #0d0d0f; color: #e8e8ea; }}
  h1 {{ font-size: 18px; margin: 0 0 8px; font-weight: 600; }}
  .prompt {{ background: #1a1a1d; padding: 12px 16px; border-radius: 8px; margin-bottom: 24px; font-size: 14px; line-height: 1.5; color: #b0b0b8; border-left: 3px solid #4a9eff; }}
  .grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 16px; }}
  .card {{ margin: 0; background: #18181b; border-radius: 8px; overflow: hidden; transition: transform .15s ease-out; }}
  .card:hover {{ transform: translateY(-2px); }}
  .card img {{ width: 100%; height: 280px; object-fit: cover; display: block; cursor: zoom-in; }}
  .card figcaption {{ padding: 10px 12px; display: flex; align-items: center; justify-content: space-between; font-size: 13px; gap: 8px; }}
  .meta {{ color: #888; font-size: 12px; margin-left: 8px; }}
  .copy-btn {{ background: #2a2a2e; color: #b0b0b8; border: none; padding: 4px 10px; border-radius: 4px; cursor: pointer; font-size: 12px; }}
  .copy-btn:hover {{ background: #3a3a3e; color: #fff; }}
  details {{ margin-top: 24px; background: #2a1818; padding: 12px 16px; border-radius: 8px; }}
  details code {{ background: #0d0d0f; padding: 2px 6px; border-radius: 4px; font-size: 11px; }}
</style></head><body>
<h1>content-gen — preview</h1>
<div class="prompt">{html.escape(prompt) if prompt else "(no prompt)"}</div>
<div class="grid">{items_html}</div>
{errors_html}
<script>
  function copyPath(p) {{
    navigator.clipboard.writeText(p);
    event.target.textContent = '✓ copied';
    setTimeout(() => event.target.textContent = '📋 copy path', 1500);
  }}
</script>
</body></html>"""

(OUTDIR / "preview.html").write_text(html_out, encoding="utf-8")
print(f"✓ preview.html ({len(images)} images, {len(errors)} errors)")
