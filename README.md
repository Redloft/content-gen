# content-gen

**A [Claude Code](https://claude.com/claude-code) skill for visual content — parallel AI generation, stock search, and polished website mockups from a URL.**

One command fans an image prompt out across several providers at once, shows you a preview grid, and lets you pick the winner. A separate `/content-mockup` branch turns any website URL into a batch of beautiful device/context mockups.

---

## What it does

- **Parallel AI generation** — one prompt → Recraft v3, Gemini (Nano Banana / Imagen 4), OpenAI `gpt-image-1`, Replicate Flux, all at once → HTML preview grid in your browser.
- **3 cost tiers** — `explore` (cheap, dial in the prompt) → `mid` (default) → `premium` (production).
- **Stock search** — Unsplash + Pexels + Pixabay in parallel.
- **Website mockups** (`/content-mockup <url>`) — screenshot a site and drop it into:
  - **device frames** — browser / iPhone / iPad / MacBook (pixel-perfect, offline);
  - **contextual scenes** — a laptop in a sauna, a phone in hand at a spa (AI-generated scene + deterministic screen compositing, so the screen is never distorted);
  - with a **Tinder-style pick** of the visual direction and volume **fitted to a page's image slots** (desktop + mobile).
- **Vectorize / compress** — trace raster → SVG (vtracer/potrace) or convert/compress to WebP/AVIF.
- **Cloudinary upload** — optional, with auto-optimized derivatives.

## How the mockup engine works

Both mockup branches share one path: build a surface with a **chroma-green screen** (a PIL-drawn device for frames, or a Recraft-generated scene for context), then **detect the green quad and perspective-composite the real screenshot into it**. The screenshot is inserted deterministically — pixel-for-pixel — instead of being re-drawn by a model, so text and layout stay crisp. Website capture runs through Playwright with an **SSRF guard** (private/loopback/metadata IPs and `file:`/`data:` are blocked).

## Install

This is a Claude Code skill. Drop it into your skills directory:

```bash
git clone https://github.com/Redloft/content-gen ~/.claude/skills/content-gen
cd ~/.claude/skills/content-gen && npm install        # Playwright (for /content-mockup)
npx playwright install chromium                        # one-time (~110 MB)
```

Copy the command files into your Claude Code commands directory if you want the `/content-*` slash commands:

```bash
cp ~/.claude/skills/content-gen/commands/content-*.md ~/.claude/commands/
```

Offline engines used by vectorize/compose (installed once): `vtracer`, `potrace` + `mkbitmap`, `pngquant`, `oxipng`, `svgo`, `sharp-cli`, `cwebp`, and Python `Pillow`.

## API keys

Set only the ones for the providers you use. Two ways:

**A — environment variables.** Copy `.env.example` → `.env`, fill it in, then `set -a; source .env; set +a`.

**B — 1Password.** Copy `lib/all-secrets.env.example` → `lib/all-secrets.env` and point each var at your own `op://` reference. If that file plus the [`op` CLI](https://developer.1password.com/docs/cli/) are present, the run scripts automatically wrap generation in a single `op run` (one auth prompt for the whole batch). If it's absent, they fall back to plain env vars.

| Provider | Env var | Get a key |
|---|---|---|
| Recraft v3 | `RECRAFT_API_KEY` | https://www.recraft.ai/ |
| Google AI Studio (Nano Banana / Imagen) | `GEMINI_API_KEY` | https://aistudio.google.com/apikey |
| OpenAI (gpt-image-1) | `OPENAI_API_KEY` | https://platform.openai.com/api-keys |
| Replicate (Flux) | `REPLICATE_API_TOKEN` | https://replicate.com/account/api-tokens |
| Unsplash / Pexels / Pixabay | `UNSPLASH_ACCESS_KEY` / `PEXELS_API_KEY` / `PIXABAY_API_KEY` | unsplash.com/developers · pexels.com/api · pixabay.com/api/docs |
| Cloudinary (upload) | `CLOUDINARY_*` | https://cloudinary.com/console |

> **Never commit real keys.** `.env` and `lib/all-secrets.env` are git-ignored. `/content-mockup` sends the screenshot to a third-party AI (Recraft) — use it on **public** pages, not internal dashboards with real customer data.

## Usage

```bash
# multi-provider image generation
/content-gen a cozy hero for a coffee-shop landing --tier mid

# website mockups from a URL
/content-mockup https://example.com
/content-mockup https://example.com --for-page ./src   # fit volume to a page's image slots

# stock search
/content-stock river at dawn

# vectorize / compress a file
/content-vectorize ./logo.png --potrace
```

Or call the orchestrators directly:

```bash
./run.sh "a neon wireframe brain on black" --tier explore
./run-mockup.sh capture --url https://example.com --out ./out
```

## License

MIT — see [LICENSE](LICENSE).
