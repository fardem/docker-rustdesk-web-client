#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="$ROOT_DIR/docker/nginx/entrypoint.sh"
TEMPLATE="$ROOT_DIR/docker/nginx/default.conf.template"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$TEMP_DIR/bin"
cat > "$TEMP_DIR/bin/nginx" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TEMP_DIR/bin/nginx"

run_entrypoint() {
    PATH="$TEMP_DIR/bin:$PATH" \
    NGINX_TEMPLATE="$TEMPLATE" \
    NGINX_CONFIG="$TEMP_DIR/default.conf" \
    BACKEND_HOST="$1" \
    PROTO="$2" \
    "$ENTRYPOINT"
}

run_entrypoint "rd.example.com" "https"
grep -Fq 'server rd.example.com:21114;' "$TEMP_DIR/default.conf"
grep -Fq 'proxy_pass https://api;' "$TEMP_DIR/default.conf"
if grep -Eq 'PLACEHOLDER_HOST|PROTO://' "$TEMP_DIR/default.conf"; then
    echo "Das Nginx-Template enthält noch einen Platzhalter" >&2
    exit 1
fi

run_entrypoint "[2001:db8::1]" "http"
grep -Fq 'server [2001:db8::1]:21118;' "$TEMP_DIR/default.conf"

if run_entrypoint 'bad/host' 'http' >/dev/null 2>&1; then
    echo "Ein ungültiger BACKEND_HOST wurde akzeptiert" >&2
    exit 1
fi

if run_entrypoint 'rd.example.com' 'ftp' >/dev/null 2>&1; then
    echo "Ein ungültiges PROTO wurde akzeptiert" >&2
    exit 1
fi
