---
name: remarkable-md
description: |
  Convert a Markdown file to Typst, compile it to PDF, and upload the PDF
  to a reMarkable tablet. Picks the best upload transport available:
  USB-tethered SSH (10.11.99.1) → WiFi SSH (saved host) → `rmapi` cloud CLI
  → manual cloud drop (opens the PDF + my.remarkable.com so the user can
  drag it into the web/desktop app). The Typst preamble is tuned for the
  reMarkable 2 screen (~157×210mm, A5-ish) so the PDF fills the device
  without scaling.
  Use when the user says "send this markdown to my remarkable", "push
  notes to remarkable", "md to remarkable", "compile and upload to rm",
  or supplies a `.md` path with the word "remarkable".
allowed-tools:
  - Bash
  - Read
  - Write
  - AskUserQuestion
---

# /remarkable-md — Markdown → Typst → PDF → reMarkable

Three-stage pipeline:

1. **Convert** the input `.md` to `.typ` via `pandoc -t typst`, prepending
   a reMarkable-tuned preamble.
2. **Compile** the `.typ` to a `.pdf` via `typst compile`.
3. **Upload** the PDF using the first transport that works:
   - **SSH-USB** — tablet tethered, SSH on `10.11.99.1`. Fastest, lossless.
   - **SSH-WiFi** — tablet IP saved in `~/.config/remarkable/host`.
   - **rmapi-cloud** — third-party CLI, registered with reMarkable cloud.
   - **manual-cloud** — open the PDF in Finder and `https://my.remarkable.com/`
     so the user can drag it into the web app or desktop app.

The skill never blocks: if a transport is unreachable, it falls through
to the next one and reports which one succeeded.

## When To Use

- The user names a Markdown file and asks to put it on reMarkable.
- The user asks to "compile these notes for my tablet" or similar.
- The user explicitly invokes the skill, optionally with flags:

```text
remarkable-md notes.md
remarkable-md notes.md --transport ssh
remarkable-md notes.md --transport cloud --name "Reading List"
remarkable-md notes.md --paper a4
remarkable-md notes.md --keep-typ --keep-pdf
remarkable-md notes.md --folder /Reading
```

## When Not To Use

- The user just wants a PDF locally — use Typst or Pandoc directly.
- The source is not Markdown (e.g. `.docx`, `.tex`) — use a dedicated
  converter, or convert to Markdown first.
- The user wants to *edit* an existing reMarkable notebook — this skill
  only pushes new documents.

## Argument Parsing

The first positional argument is the input Markdown path. Flags:

| Flag | Default | Meaning |
|---|---|---|
| `--transport <id>` | `auto` | Force `ssh`, `ssh-usb`, `ssh-wifi`, `cloud`, or `manual`. `auto` tries in order. |
| `--name <str>` | input filename stem | Document name shown on the tablet. |
| `--folder <path>` | `/` | Destination folder. For cloud: rmapi path. For SSH: ignored (lands in root). |
| `--paper <id>` | `remarkable` | `remarkable` (157×209mm), `a5`, `a4`, `letter`. |
| `--keep-typ` | off | Keep the intermediate `.typ`. |
| `--keep-pdf` | off | Keep the compiled `.pdf` after upload. |
| `--no-upload` | off | Convert + compile only. Implies `--keep-pdf`. |
| `--dry-run` | off | Show what would happen, don't execute. |

If the user invokes the skill without an input file, ask for one.

---

## Step 0: Preflight

Detect tools and transports. Stop only if neither converter nor
compiler is present; otherwise just record what is available.

```bash
set -euo pipefail

INPUT="${INPUT:?usage: remarkable-md <file.md> [flags]}"
[ -r "$INPUT" ] || { echo "MISSING: input file not readable: $INPUT"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

have pandoc || { echo "MISSING: pandoc (brew install pandoc)"; exit 1; }
have typst  || { echo "MISSING: typst  (brew install typst)";  exit 1; }

# Optional cloud CLI
RMAPI_OK=0
if have rmapi && rmapi version >/dev/null 2>&1; then RMAPI_OK=1; fi

# SSH-USB reachability (cheap probe, 1s timeout)
SSH_USB_OK=0
if nc -z -G 1 10.11.99.1 22 2>/dev/null; then SSH_USB_OK=1; fi

# SSH-WiFi reachability (only if user has saved a host)
SSH_WIFI_OK=0
SSH_WIFI_HOST=""
if [ -r "$HOME/.config/remarkable/host" ]; then
  SSH_WIFI_HOST="$(tr -d '[:space:]' < "$HOME/.config/remarkable/host")"
  if [ -n "$SSH_WIFI_HOST" ] && nc -z -G 1 "$SSH_WIFI_HOST" 22 2>/dev/null; then
    SSH_WIFI_OK=1
  fi
fi

echo "preflight: rmapi=$RMAPI_OK ssh-usb=$SSH_USB_OK ssh-wifi=$SSH_WIFI_OK host=${SSH_WIFI_HOST:-none}"
```

Output one line of preflight to the user so the chosen transport is not
a surprise.

---

## Step 1: Convert Markdown → Typst

Write the reMarkable-tuned preamble, then append the pandoc-generated
Typst body. Pandoc's `typst` writer (Pandoc ≥3.1) handles headings,
lists, code fences, tables, and inline math.

Pick the page block by `--paper`:

| `--paper` | Typst page setting |
|---|---|
| `remarkable` *(default)* | `width: 157mm, height: 209mm, margin: (x: 10mm, y: 12mm)` |
| `a5` | `paper: "a5", margin: (x: 12mm, y: 14mm)` |
| `a4` | `paper: "a4", margin: (x: 18mm, y: 20mm)` |
| `letter` | `paper: "us-letter", margin: (x: 18mm, y: 20mm)` |

```bash
WORK="$(mktemp -d -t remarkable-md.XXXXXX)"
STEM="$(basename "${INPUT%.md}")"
NAME="${NAME:-$STEM}"
TYP="$WORK/$STEM.typ"
PDF="$WORK/$STEM.pdf"

# Build preamble. Default = reMarkable-native page.
case "${PAPER:-remarkable}" in
  remarkable) PAGE='#set page(width: 157mm, height: 209mm, margin: (x: 10mm, y: 12mm))' ;;
  a5)         PAGE='#set page(paper: "a5", margin: (x: 12mm, y: 14mm))' ;;
  a4)         PAGE='#set page(paper: "a4", margin: (x: 18mm, y: 20mm))' ;;
  letter)     PAGE='#set page(paper: "us-letter", margin: (x: 18mm, y: 20mm))' ;;
  *) echo "unknown --paper value: $PAPER"; exit 1 ;;
esac

{
  echo "$PAGE"
  echo '#set text(size: 11pt)'
  echo '#set par(justify: true, leading: 0.65em)'
  echo '#show heading.where(level: 1): set text(size: 18pt)'
  echo '#show heading.where(level: 2): set text(size: 14pt)'
  echo '#show raw: set text(font: "DejaVu Sans Mono", size: 9pt)'
  # Pandoc's typst writer emits `#horizontalrule` for `---` thematic
  # breaks, but that symbol lives only in pandoc's --standalone template,
  # which this skill replaces. Define it ourselves or any `.md` with a
  # `---` divider fails to compile ("unknown variable: horizontalrule").
  echo '#let horizontalrule = line(start: (25%,0%), end: (75%,0%))'
  echo ''
  pandoc -f gfm -t typst "$INPUT"
} > "$TYP"
```

If pandoc emits its own `#set page(...)` line, the preamble's `#set
page(...)` still wins because Typst applies the *last* `set` rule —
that's why the preamble is written **before** the pandoc body. (Test
once if pandoc's typst writer changes; correct as needed.)

---

## Step 2: Compile Typst → PDF

```bash
typst compile "$TYP" "$PDF"
```

If compilation fails, surface the Typst error verbatim. The most common
cause is an unsupported pandoc construct (e.g. raw HTML embedded in
Markdown). Tell the user which line of the `.typ` to look at.

---

## Step 3: Upload — Pick Transport

Decision order (when `--transport auto`):

1. `SSH_USB_OK=1` → **SSH-USB**
2. `SSH_WIFI_OK=1` → **SSH-WiFi**
3. `RMAPI_OK=1` → **rmapi-cloud**
4. else → **manual-cloud**

A forced `--transport` jumps straight to that block and errors if
unavailable (no fallthrough — the user asked for a specific path).

### Transport A — SSH (USB or WiFi)

Same logic for both; only the host differs.

```bash
RM_HOST="${RM_HOST:-10.11.99.1}"            # or $SSH_WIFI_HOST for WiFi
UUID="$(uuidgen | tr 'A-Z' 'a-z')"
TS_MS="$(($(date +%s) * 1000))"
XOCHITL="/home/root/.local/share/remarkable/xochitl"

# 1. Build sidecars locally.
cat > "$WORK/$UUID.metadata" <<EOF
{
  "visibleName": "$NAME",
  "type": "DocumentType",
  "parent": "",
  "deleted": false,
  "lastModified": "$TS_MS",
  "metadatamodified": false,
  "modified": false,
  "pinned": false,
  "synced": false,
  "version": 0
}
EOF

cat > "$WORK/$UUID.content" <<EOF
{
  "fileType": "pdf",
  "pageCount": 1,
  "extraMetadata": {},
  "lineHeight": -1,
  "margins": 100,
  "textScale": 1,
  "transform": {},
  "orientation": "portrait"
}
EOF

# 2. Push the PDF + sidecars to the tablet.
scp -q -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new \
  "$PDF" "$WORK/$UUID.metadata" "$WORK/$UUID.content" \
  "root@$RM_HOST:$XOCHITL/" \
  && ssh -o ConnectTimeout=4 "root@$RM_HOST" \
       "mv $XOCHITL/$(basename "$PDF") $XOCHITL/$UUID.pdf && systemctl restart xochitl"
```

Rename-on-device puts the PDF at `<UUID>.pdf` matching the sidecars.
Restarting `xochitl` re-scans the document store; the doc appears in
*My Files* within ~5 seconds. The UI flashes during restart — note that
to the user so they don't think the tablet crashed.

**Auth**: reMarkable's SSH password is set on the device under *Settings
→ Help → Copyrights and software → GPL Notice → ssh password* (path
varies by firmware). If `scp` prompts for a password every run, suggest
the user run `ssh-copy-id root@<host>` once.

### Transport B — rmapi cloud

```bash
FOLDER="${FOLDER:-/}"
rmapi mkdir "$FOLDER" 2>/dev/null || true   # idempotent
rmapi put "$PDF" "$FOLDER"
```

`rmapi` uploads to reMarkable Cloud; the document appears on the
tablet after the next sync (seconds on WiFi). If `rmapi` is installed
but not authenticated, surface the `rmapi help` line that explains the
one-time `rmapi` (no args) registration flow.

### Transport C — manual cloud

Last resort. Move the PDF somewhere the user can grab it, open Finder
to it, open the web app, and tell the user what to drop where.

```bash
DEST="$HOME/Desktop/$NAME.pdf"
cp "$PDF" "$DEST"
open -R "$DEST"                          # reveal in Finder
open "https://my.remarkable.com/"        # open cloud UI
```

Tell the user verbatim:

> Drag `$DEST` into the *My Files* area of the open reMarkable web tab.
> It will sync to the tablet after the next pull.

The reMarkable desktop app accepts the same drag-and-drop if the user
prefers it over the browser — point to the open Finder window.

---

## Step 4: Cleanup

Always remove the work directory unless the user passed `--keep-typ` or
`--keep-pdf`. With `--keep-*`, move just those artifacts to the input
file's directory, then remove `$WORK`.

```bash
if [ "${KEEP_TYP:-0}" = 1 ]; then cp "$TYP" "$(dirname "$INPUT")/"; fi
if [ "${KEEP_PDF:-0}" = 1 ]; then cp "$PDF" "$(dirname "$INPUT")/"; fi
rm -rf "$WORK"
```

---

## Output Contract

Always print one final status line so the user knows what shipped:

```
remarkable-md: $INPUT → $NAME.pdf via <transport> [success|manual-handoff]
```

For the SSH path, include the UUID — if the user later wants to delete
or rename via SSH, the UUID is the handle.

For the manual path, the status is `manual-handoff` (not `success`):
the upload is the user's job, the skill just staged it.

---

## Notes For The Implementing Assistant

- **Default page = 157×209mm.** Don't switch to A4 unless the user
  asks. The tablet will render any size, but native size avoids
  empty borders and tiny text.
- **Pandoc front matter** (YAML at the top of the `.md`) is consumed
  silently — pandoc renders `title:` and `author:` only if you also
  pass `--standalone`. This skill does **not** pass `--standalone`,
  so YAML metadata is dropped. If the user wants a cover/title page,
  surface that limitation rather than silently losing it.
- **First-time SSH password prompt** is normal. Don't retry on
  password failure — let the user enter it once; suggest `ssh-copy-id`
  for the next run.
- **`xochitl` restart is intrusive**: it kicks the user out of any
  open notebook for ~5s. If they're in the middle of writing, ask
  before restarting (only relevant when they're sitting next to the
  tablet — usually they are if it's USB-tethered).
- **Never `rm` on the tablet.** This skill only writes new documents.
  Deletion/rename is out of scope; if asked, point the user to `rmapi`
  or the device UI.
