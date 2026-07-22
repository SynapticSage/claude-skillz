#!/usr/bin/env bash
# upload.sh — push a PDF to a reMarkable tablet via the first transport that works.
#
# Shared by remarkable-md and remarkable-html. Extracted from remarkable-md's
# inline bash so a firmware/SSH change is one edit, not two.
#
# Usage: upload.sh <pdf> <name> [transport] [folder]
#   transport: auto (default) | ssh | ssh-usb | ssh-wifi | cloud | manual
#              An explicit transport does NOT fall through — if the user names a
#              path and it's unreachable, that's an error worth seeing, not a
#              silent detour onto a different one.
#
# Stdout contract:
#   PROBE: ssh-usb=<0|1> ssh-wifi=<0|1> rmapi=<0|1> host=<host|none>
#   UPLOADED: <transport> uuid=<uuid>     document is on the tablet
#   STAGED: manual <path>                 staged only; the human must drop it
#   FAIL: <reason>
set -euo pipefail
. "$(dirname "$0")/lib.sh"

PDF="${1:?usage: upload.sh <pdf> <name> [transport] [folder]}"
NAME="${2:?usage: upload.sh <pdf> <name> [transport] [folder]}"
TRANSPORT="${3:-auto}"
FOLDER="${4:-/}"
[ -r "$PDF" ] || { echo "FAIL: pdf not readable: $PDF"; exit 0; }

RM_USB_HOST="10.11.99.1"
XOCHITL="/home/root/.local/share/remarkable/xochitl"

# ── probe transports (cheap, 1s timeouts) ────────────────────────────────────
SSH_USB_OK=0
nc -z -G 1 "$RM_USB_HOST" 22 2>/dev/null && SSH_USB_OK=1

SSH_WIFI_OK=0; SSH_WIFI_HOST=""
if [ -r "$HOME/.config/remarkable/host" ]; then
  SSH_WIFI_HOST="$(tr -d '[:space:]' < "$HOME/.config/remarkable/host")"
  [ -n "$SSH_WIFI_HOST" ] && nc -z -G 1 "$SSH_WIFI_HOST" 22 2>/dev/null && SSH_WIFI_OK=1
fi

RMAPI_OK=0
have rmapi && rmapi version >/dev/null 2>&1 && RMAPI_OK=1

echo "PROBE: ssh-usb=$SSH_USB_OK ssh-wifi=$SSH_WIFI_OK rmapi=$RMAPI_OK host=${SSH_WIFI_HOST:-none}"

# ── pick ─────────────────────────────────────────────────────────────────────
PICK=""
case "$TRANSPORT" in
  auto)
    if   [ "$SSH_USB_OK"  = 1 ]; then PICK=ssh-usb
    elif [ "$SSH_WIFI_OK" = 1 ]; then PICK=ssh-wifi
    elif [ "$RMAPI_OK"    = 1 ]; then PICK=cloud
    else                              PICK=manual; fi ;;
  ssh)
    if   [ "$SSH_USB_OK"  = 1 ]; then PICK=ssh-usb
    elif [ "$SSH_WIFI_OK" = 1 ]; then PICK=ssh-wifi
    else echo "FAIL: --transport ssh but no tablet reachable on USB or WiFi"; exit 0; fi ;;
  ssh-usb)
    [ "$SSH_USB_OK" = 1 ] || { echo "FAIL: tablet not reachable at $RM_USB_HOST (tethered?)"; exit 0; }
    PICK=ssh-usb ;;
  ssh-wifi)
    [ "$SSH_WIFI_OK" = 1 ] || { echo "FAIL: no reachable host in ~/.config/remarkable/host"; exit 0; }
    PICK=ssh-wifi ;;
  cloud)
    [ "$RMAPI_OK" = 1 ] || { echo "FAIL: rmapi missing or unregistered (run: rmapi)"; exit 0; }
    PICK=cloud ;;
  manual) PICK=manual ;;
  *) echo "FAIL: unknown transport: $TRANSPORT"; exit 0 ;;
esac

# ── transport A: SSH (usb or wifi) ───────────────────────────────────────────
if [ "$PICK" = ssh-usb ] || [ "$PICK" = ssh-wifi ]; then
  [ "$PICK" = ssh-usb ] && HOST="$RM_USB_HOST" || HOST="$SSH_WIFI_HOST"
  UUID="$(uuidgen | tr 'A-Z' 'a-z')"
  TS_MS="$(( $(date +%s) * 1000 ))"
  W="$(mktemp -d -t rm-upload.XXXXXX)"
  trap 'rm -rf "$W"' EXIT

  # xochitl identifies a document by a UUID and two JSON sidecars. The PDF must
  # land as <uuid>.pdf alongside them or the tablet ignores it entirely.
  cat > "$W/$UUID.metadata" <<EOF
{"visibleName":"$NAME","type":"DocumentType","parent":"","deleted":false,
 "lastModified":"$TS_MS","metadatamodified":false,"modified":false,
 "pinned":false,"synced":false,"version":0}
EOF
  cat > "$W/$UUID.content" <<'EOF'
{"fileType":"pdf","extraMetadata":{},"lineHeight":-1,"margins":100,
 "textScale":1,"transform":{},"orientation":"portrait"}
EOF

  SSHOPT=(-o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new)
  if ! scp -q "${SSHOPT[@]}" "$PDF" "$W/$UUID.metadata" "$W/$UUID.content" \
         "root@$HOST:$XOCHITL/" 2>/dev/null; then
    echo "FAIL: scp to root@$HOST failed (password? try: ssh-copy-id root@$HOST)"; exit 0
  fi
  # Rename on-device so the PDF matches its sidecars, then make xochitl re-scan.
  ssh "${SSHOPT[@]}" "root@$HOST" \
    "mv '$XOCHITL/$(basename "$PDF")' '$XOCHITL/$UUID.pdf' && systemctl restart xochitl" \
    >/dev/null 2>&1 || { echo "FAIL: on-device rename/restart failed"; exit 0; }

  echo "UPLOADED: $PICK uuid=$UUID"
  exit 0
fi

# ── transport B: rmapi cloud ─────────────────────────────────────────────────
if [ "$PICK" = cloud ]; then
  [ "$FOLDER" = "/" ] || rmapi mkdir "$FOLDER" >/dev/null 2>&1 || true

  # `rmapi put` names the document after the FILE, ignoring any name we pass —
  # so $NAME was silently a no-op on this path until we staged the PDF under the
  # name we actually want. (The SSH path has no such problem: visibleName is set
  # explicitly in the .metadata sidecar.)
  CW="$(mktemp -d -t rm-cloud.XXXXXX)"
  trap 'rm -rf "$CW"' EXIT
  cp "$PDF" "$CW/$NAME.pdf"

  if rmapi put "$CW/$NAME.pdf" "$FOLDER" >/dev/null 2>&1; then
    echo "UPLOADED: cloud uuid=- name=$NAME folder=$FOLDER"
  else
    echo "FAIL: rmapi put failed (registered? run bare 'rmapi' once)"
  fi
  exit 0
fi

# ── transport C: manual handoff ──────────────────────────────────────────────
# Not "success" — the skill only staged it; the upload is still the human's job.
# ~/Desktop exists on macOS but not everywhere (headless boxes, Linux, a test
# HOME). Don't let a missing directory abort the last-resort transport.
DEST_DIR="$HOME/Desktop"; [ -d "$DEST_DIR" ] || DEST_DIR="$HOME"
DEST="$DEST_DIR/$NAME.pdf"
cp "$PDF" "$DEST"
open -R "$DEST" 2>/dev/null || true
open "https://my.remarkable.com/" 2>/dev/null || true
echo "STAGED: manual $DEST"
