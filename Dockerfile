# syntax=docker/dockerfile:1.7

###############################################################################
# Stufe 1 — Build JS/TS (RustDesk-Frontend)
###############################################################################
FROM node:20-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0 AS js-build

# ————— Build-Parameter ———————————————
ARG RUSTDESK_REPO=MonsieurBiche/rustdesk-web-client
ARG RUSTDESK_TAG=fix-build
# Ein expliziter SHA hat Vorrang vor dem Branch. Der erwartete Commit nagelt nur
# die Standardkombination aus Repository und Branch fest und stört eigene Quellen nicht.
ARG RUSTDESK_COMMIT=
ARG RUSTDESK_EXPECTED_COMMIT=525b5e561faf824850c71500adf463e4e0a504d4
ARG ENABLE_WSS=true

# ————— minimale Systemabhängigkeiten ————
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git python3 python-is-python3 protobuf-compiler ca-certificates \
        build-essential && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src
# ————— reproduzierbarer Clone ———————————
# ─── Repo + Submodule klonen ──────────────────────────────────────────────────
RUN git clone --branch "${RUSTDESK_TAG}" \
        --depth 1 \
        --recursive --shallow-submodules \
        "https://github.com/${RUSTDESK_REPO}.git" rustdesk
RUN target_commit="${RUSTDESK_COMMIT}" \
 && if [ -z "${target_commit}" ] \
      && [ "${RUSTDESK_REPO}" = "MonsieurBiche/rustdesk-web-client" ] \
      && [ "${RUSTDESK_TAG}" = "fix-build" ]; then \
      target_commit="${RUSTDESK_EXPECTED_COMMIT}"; \
    fi \
 && if [ -n "${target_commit}" ]; then \
      current_commit="$(git -C rustdesk rev-parse HEAD)"; \
      if [ "${current_commit}" != "${target_commit}" ]; then \
        git -C rustdesk fetch --depth 1 origin "${target_commit}"; \
        git -C rustdesk checkout --detach "${target_commit}"; \
      fi; \
    fi \
 && git -C rustdesk submodule update --init --recursive --depth 1

# ————— JS-Quellen kopieren —————————
WORKDIR /src/rustdesk/flutter/web
RUN if [ -d "v1" ]; then cp -a v1/* .; fi

RUN set -eu; \
    config=/src/rustdesk/flutter/web/js/vite.config.js; \
    if ! grep -q 'manualChunks(id)' "$config"; then \
      grep -q 'chunkFileNames:' "$config"; \
      sed -i '/chunkFileNames:/a\        manualChunks(id) {\
          if (id.includes("node_modules")) return "vendor";\
        },' "$config"; \
    fi; \
    grep -q 'manualChunks(id)' "$config"

# --- Fix appBarActions parameter (web build) ---
RUN set -eu; \
    source=/src/rustdesk/flutter/lib/mobile/pages/home_page.dart; \
    if grep -q 'ConnectionPage(key: _connKey);' "$source"; then \
      sed -i 's/ConnectionPage(key: _connKey);/ConnectionPage(key: _connKey, appBarActions: const <Widget>[]);/' "$source"; \
    fi; \
    grep -q 'appBarActions:' "$source"

WORKDIR /src/rustdesk/flutter/web/js

# ————— Yarn + Deps installieren (BuildKit-Cache) —
RUN --mount=type=cache,target=/usr/local/share/.cache/yarn \
    corepack enable && \
    corepack prepare "yarn@3.2.0" --activate && \
    yarn install --immutable

# ————— optionaler WSS-Patch ———————
RUN if [ "$ENABLE_WSS" = "true" ]; then \
      find . -type f \( -name "*.ts" -o -name "*.js" \) \
        -exec sed -i 's#ws://#wss://#g' {} +; \
    fi

# --- RustDesk localStorage bootstrap & sanitization ---
# --- Inline <script> in index.html : full localStorage sanitization ---
RUN HTML=/src/rustdesk/flutter/web/index.html && \
    sed -i '0,/<meta charset=.UTF-8./a \
<script>\
(function(){\
  const defaults={\
    "custom-rendezvous-server":"",\
    "rendezvous-server":"",\
    "id":"",\
    "key":"",\
    "remote-id":"",\
    "peers":[],\
    "server_config":{"customServers":[]}\
  };\
  /* Alle Keys durchgehen */\
  for(const k of Object.keys(localStorage)){\
    let v=localStorage.getItem(k);\
    if(v===null||v===""){localStorage.removeItem(k);continue;}\
    /* Potenziell ein JSON-Wert */\
    const f=v[0];\
    if(f==="{"||f==="["){\
      try{JSON.parse(v);}catch{localStorage.setItem(k,f==="["?"[]":"{}");}\
    }\
  }\
  /* Fehlende Standardwerte setzen */\
  for(const [k,val] of Object.entries(defaults))\
    if(localStorage.getItem(k)===null)\
      localStorage.setItem(k,typeof val==="string"?val:JSON.stringify(val));\
})();\
</script>' "$HTML" && \
    grep -q 'const defaults=' "$HTML"


# ————— JS bauen ————————————————
RUN yarn build

###############################################################################
# Stufe 2 — Build Flutter Web
###############################################################################
FROM debian:bookworm-slim@sha256:60eac759739651111db372c07be67863818726f754804b8707c90979bda511df AS flutter-build

ARG FLUTTER_VERSION=3.22.1
ARG RUST_VERSION=1.97.0
ENV FLUTTER_HOME=/opt/flutter
ENV PATH="$FLUTTER_HOME/bin:$FLUTTER_HOME/bin/cache/dart-sdk/bin:$PATH"
ENV RUSTFLAGS='--cfg getrandom_backend="js"'

# ————— Systemabhängigkeiten —————————
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash curl git xz-utils zip unzip ca-certificates \
        build-essential clang cmake ninja-build pkg-config \
        python3 python-is-python3 protobuf-compiler \
        libgtk-3-dev libgl1-mesa-dev libglu1-mesa wget && \
    rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ————— Rust + wasm-Target (BuildKit-Cache) —
RUN --mount=type=cache,target=/usr/local/cargo \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --no-modify-path --default-toolchain "${RUST_VERSION}" && \
    source "$HOME/.cargo/env" && \
    rustup target add wasm32-unknown-unknown

# ————— Flutter SDK (BuildKit-Cache) —————
RUN --mount=type=cache,target=/root/.cache/flutter \
    git clone --depth 1 --branch "${FLUTTER_VERSION}" \
        https://github.com/flutter/flutter.git "$FLUTTER_HOME" && \
    flutter config --enable-web --no-analytics && \
    flutter precache --web

# ————— Quellen aus js-build kopieren ————
COPY --from=js-build /src/rustdesk /build/rustdesk
WORKDIR /build/rustdesk/flutter

# 3) Externe Web-Abhängigkeiten, versioniert mit diesem Repository
COPY web_deps.tar.gz /tmp/web_deps.tar.gz
RUN tar -xzf /tmp/web_deps.tar.gz -C web/ && \
    rm /tmp/web_deps.tar.gz

# ─── Flutter-Web bauen (Stage flutter-build) ────────────────────────────────
ENV FLUTTER_ALLOW_ROOT=1
RUN --mount=type=cache,target=/usr/local/cargo \
    --mount=type=cache,target=/root/.cache/flutter \
    source "$HOME/.cargo/env" && \
    flutter build web --release && \
    \
    # Vite-Bundle ablegen
    mkdir -p build/web/js && \
    cp -r web/js/dist build/web/js/

###############################################################################
# Stufe 3 — Ultraleichte Nginx-Laufzeit (angepasst für RustDesk Web v1)
###############################################################################
FROM nginx:alpine@sha256:54f2a904c251d5a34adf545a72d32515a15e08418dae0266e23be2e18c66fefa AS final

# ————— statische Assets —————————————
COPY --from=flutter-build /build/rustdesk/flutter/build/web /usr/share/nginx/html

# ————— Nginx-Konfiguration und Entrypoint ———————————
COPY docker/nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY docker/nginx/entrypoint.sh /docker-entrypoint.sh
RUN chmod 0755 /docker-entrypoint.sh

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1/ >/dev/null || exit 1
STOPSIGNAL SIGQUIT
ENTRYPOINT ["/docker-entrypoint.sh"]
