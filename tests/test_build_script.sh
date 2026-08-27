#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

cat > "$TEMP_DIR/test.env" <<'EOF'
WEB_PORT=8080
BACKEND_HOST=rd.example.com
PROTO=https
RUSTDESK_TAG=enable-wss
EOF

output="$(ENV_FILE="$TEMP_DIR/test.env" "$ROOT_DIR/build.sh" config)"
grep -Fq 'Web-Port            : 8080 -> 80' <<<"$output"
grep -Fq 'RustDesk-Backend    : rd.example.com' <<<"$output"
grep -Fq 'Backend-Protokoll   : https' <<<"$output"
grep -Fq 'Quell-Referenz      : enable-wss' <<<"$output"

output="$(WEB_PORT=9090 ENV_FILE="$TEMP_DIR/test.env" "$ROOT_DIR/build.sh" config)"
grep -Fq 'Web-Port            : 9090 -> 80' <<<"$output"

if "$ROOT_DIR/build.sh" config unerwartetes-argument >/dev/null 2>&1; then
    echo "Ein überzähliges Argument wurde akzeptiert" >&2
    exit 1
fi
