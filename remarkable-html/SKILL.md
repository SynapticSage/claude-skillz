---
name: remarkable-html
description: |
  Convert an HTML file — especially a Claude-produced diagram or artifact
  (system design, architecture, flow, dashboard) — into an e-ink-friendly PDF
  and push it to a reMarkable tablet. Classifies the HTML first: layout-driven
  diagrams are rendered faithfully via headless Chrome; prose-shaped documents
  are routed through the markdown/Typst path instead so the text reflows.
  Shares the reMarkable upload ladder with remarkable-md.
  Use when the user says "send this diagram to my remarkable", "put this
  artifact on my tablet", "html to remarkable", "push this HTML to rm", or
  supplies an `.html` path with the word "remarkable" or "tablet".
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
---

# /remarkable-html — HTML → PDF → reMarkable

Counterpart to `remarkable-md`. Same destination, different front end, **shared
uploader** (`skills/_remarkable/scripts/upload.sh`).

```
             ┌─ RENDER ─ chrome 2-pass ─┐
  file.html ─┤  (classify.sh decides)   ├─→ pdf ─→ upload.sh ─→ tablet
             └─ TEXT ─── pandoc→typst ──┘
```

## Input: use the SOURCE file, not the artifact URL

For a Claude artifact, feed the **local `.html` file** Claude wrote (usually in
the session scratchpad), not `https://claude.ai/code/artifact/…`. The URL is a
dead end twice over — Cloudflare + auth reject a headless fetch (403), and even
inside the user's logged-in browser the artifact body lives in a **cross-origin
sandbox iframe** the parent page cannot read. "Save Page As" doesn't help either:
it captures Claude's SPA shell, which renders *"Page not found"* without a
session. If the user only has a URL, ask them for the source file, or for the
artifact's HTML pasted into a file.

## Step 0 — Preflight

```bash
CX=~/.claude/skills/remarkable-html/scripts
command -v python3 >/dev/null && echo ok
```

Chrome is resolved by `_remarkable/scripts/lib.sh`. **Do not substitute
`wkhtmltopdf`** even though it is often installed: its WebKit predates CSS grid
and silently mangles exactly the flex/grid diagrams this skill exists to carry.
A wrong diagram is worse than an error.

## Step 1 — Classify

```bash
bash "$CX/classify.sh" <file.html>
```

- `RENDER: <reason>` → Step 2A (Chrome).
- `TEXT: <reason>` → Step 2B (markdown/Typst).

Always relay the reason — the routing decision should never be a surprise.
Override with `--render` / `--text`.

The default is `RENDER` on purpose: the two mistakes are not symmetric.
Rendering a document is merely suboptimal (fixed-width text); text-converting a
diagram is **unrecoverable** — flex/grid boxes flatten into an unordered pile of
words and inline `<svg>` is dropped. When unsure, take the lossless path.

## Step 2A — Render (diagrams)

```bash
bash "$CX/render.sh" <file.html> <out.pdf> [design-width-px]
```

Prints `RENDERED: <pdf> mode=<fit|flow> page=WxH content=WxH orientation=…`.

Two passes, and the second is the trick:

- **measure** — a probe polls the page until its height stops changing, then
  writes the content box to a `data-rmfit` attribute on `<html>`, read back out
  of `--dump-dom`. No Puppeteer, no CDP. It must poll (a React artifact's body
  is empty at `load`) and it must not use `document.title` (artifacts overwrite
  it — this was a live bug).
- **render** — set `@page` to *exactly* the measured content box.

Why not just scale the diagram onto a 157×209mm page? Because Chrome applies its
own implicit shrink-to-fit that **compounds** with any `zoom` you set, landing on
a page that is mostly dead space with unreadable text. Making the page equal the
content removes the need to scale at all — and reMarkable then fits the page to
its screen, which is the one scaler in this pipeline that does the right thing.

| mode | when | result |
|---|---|---|
| `fit` | content is roughly page-shaped (a diagram) | one page, exactly bounding the content — no clip, no pagination, no dead space |
| `flow` | content is far taller than a page (a long doc) | paginated at the content's width and the device's aspect, so every page fills the screen at a consistent, readable scale |

`design-width-px` (default 1000) is the layout width. **Narrower ⇒ less
downscaling on-device ⇒ larger text.** Bump it only if a wide diagram is being
squeezed.

## Step 2B — Text (prose-shaped HTML)

Reuse the Typst pipeline — it reflows to the small screen and keeps text
selectable, which a rendered image-of-a-page cannot.

```bash
pandoc -f html -t markdown "$IN" -o "$WORK/doc.md"
```

then hand `$WORK/doc.md` to **`/remarkable-md`** and stop. Do not reimplement it.

## Step 3 — Upload

```bash
bash ~/.claude/skills/_remarkable/scripts/upload.sh <pdf> <name> [transport] [folder]
```

Shared with `remarkable-md`. Prints `PROBE:` then one of `UPLOADED:` /
`STAGED:` / `FAIL:`. Transports, in auto order: SSH-USB → SSH-WiFi → rmapi cloud
→ manual handoff. `STAGED: manual` is **not** success — the file is on the
Desktop and the human still has to drop it in.

## Flags

| Flag | Default | Meaning |
|---|---|---|
| `--render` / `--text` | auto | Force a pipeline, skipping the classifier. |
| `--width <px>` | `1000` | Design width. Narrower ⇒ bigger text on the tablet. |
| `--name <str>` | filename stem | Document name on the tablet. |
| `--transport <id>` | `auto` | `ssh` / `ssh-usb` / `ssh-wifi` / `cloud` / `manual`. |
| `--folder <path>` | `/` | Cloud destination folder (rmapi only). |
| `--keep-pdf` | off | Keep the PDF next to the input. |
| `--no-upload` | off | Convert only. Implies `--keep-pdf`. |

## Notes for the implementing assistant

- **Verify by looking, not by counting.** A page-count/page-size check passed
  while the renderer was emitting a *blank* page (the pass-2 script was reading
  the file *path* instead of its contents). Both numbers looked plausible.
  Check extractable text (`pdftotext … | wc -c`) or rasterize and look.
- **`RM_KEEP=1`** preserves `render.sh`'s intermediate HTML. Every bug in this
  pipeline is "what did Chrome actually see" — go look instead of theorising.
- **Dark mode is mostly a non-issue**: headless Chrome renders the light variant
  by default. `render.sh` still pins `color-scheme: light only` because a page
  that *hard-codes* dark would otherwise print as a black slab on a screen with
  no backlight.
- **Never `rm` on the tablet.** This skill only writes new documents.
