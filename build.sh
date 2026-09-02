#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

log_info() { printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$*"; }
log_success() { printf '%b[SUCCESS]%b %s\n' "$GREEN" "$NC" "$*"; }
log_warning() { printf '%b[WARNING]%b %s\n' "$YELLOW" "$NC" "$*"; }
log_error() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; }

load_env_file() {
    local env_file="$1" line key value
    [[ -f "$env_file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*export[[:space:]]+ ]] && line="${line#*export }"
        if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            log_error "Ungültige .env-Zeile: $line"
            return 64
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        if [[ ${#value} -ge 2 ]] \
            && { [[ "$value" == \"*\" ]] || [[ "$value" == \'*\' ]]; }; then
            value="${value:1:${#value}-2}"
        fi
        if [[ ! -v "$key" ]]; then
            printf -v "$key" '%s' "$value"
            export "${key?}"
        fi
    done < "$env_file"
}

ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
load_env_file "$ENV_FILE"

FLUTTER_VERSION="${FLUTTER_VERSION:-3.22.1}"
RUST_VERSION="${RUST_VERSION:-1.97.0}"
RUSTDESK_TAG="${RUSTDESK_TAG:-fix-build}"
RUSTDESK_REPO="${RUSTDESK_REPO:-MonsieurBiche/rustdesk-web-client}"
RUSTDESK_COMMIT="${RUSTDESK_COMMIT:-}"
RUSTDESK_EXPECTED_COMMIT="${RUSTDESK_EXPECTED_COMMIT:-525b5e561faf824850c71500adf463e4e0a504d4}"
ENABLE_WSS="${ENABLE_WSS:-true}"
IMAGE_NAME="${IMAGE_NAME:-rustdesk-web-client}"
CONTAINER_NAME="${CONTAINER_NAME:-rustdesk-web-client}"
WEB_PORT="${WEB_PORT:-5000}"
BACKEND_HOST="${BACKEND_HOST:-127.0.0.1}"
PROTO="${PROTO:-http}"

COMPOSE=()

detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE=(docker-compose)
    else
        log_error "Docker Compose ist nicht installiert"
        return 1
    fi
}

check_prerequisites() {
    command -v docker >/dev/null 2>&1 || {
        log_error "Docker ist nicht installiert"
        return 1
    }
    docker info >/dev/null 2>&1 || {
        log_error "Der Docker-Daemon ist nicht erreichbar"
        return 1
    }
    local available_space
    available_space="$(df -Pk . | awk 'NR == 2 {print $4}')"
    if (( available_space < 4194304 )); then
        log_warning "Verfügbarer Speicherplatz unter 4 GiB"
    fi
}

container_exists() {
    docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1
}

cleanup() {
    if container_exists; then
        log_info "Container $CONTAINER_NAME wird entfernt"
        docker rm --force "$CONTAINER_NAME" >/dev/null
    fi
    if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        log_info "Image $IMAGE_NAME wird entfernt"
        docker image rm "$IMAGE_NAME" >/dev/null
    fi
    log_success "Aufräumen abgeschlossen"
}

build_image() {
    local -a build_args=(
        --build-arg "FLUTTER_VERSION=$FLUTTER_VERSION"
        --build-arg "RUST_VERSION=$RUST_VERSION"
        --build-arg "RUSTDESK_TAG=$RUSTDESK_TAG"
        --build-arg "RUSTDESK_REPO=$RUSTDESK_REPO"
        --build-arg "RUSTDESK_COMMIT=$RUSTDESK_COMMIT"
        --build-arg "RUSTDESK_EXPECTED_COMMIT=$RUSTDESK_EXPECTED_COMMIT"
        --build-arg "ENABLE_WSS=$ENABLE_WSS"
    )

    log_info "Build $RUSTDESK_REPO@$RUSTDESK_TAG mit Flutter $FLUTTER_VERSION"
    DOCKER_BUILDKIT=1 docker build \
        "${build_args[@]}" \
        --progress=plain \
        --tag "$IMAGE_NAME" \
        .
    log_success "Image gebaut: $IMAGE_NAME"
}

create_container() {
    if container_exists; then
        log_error "Container $CONTAINER_NAME existiert bereits; verwenden Sie 'start' oder 'clean'"
        return 1
    fi

    docker run --detach \
        --name "$CONTAINER_NAME" \
        --publish "$WEB_PORT:80" \
        --env "BACKEND_HOST=$BACKEND_HOST" \
        --env "PROTO=$PROTO" \
        --restart unless-stopped \
        "$IMAGE_NAME" >/dev/null
    log_success "Container erstellt: $CONTAINER_NAME"
}

start_container() {
    if container_exists; then
        docker start "$CONTAINER_NAME" >/dev/null
        log_success "Container gestartet: $CONTAINER_NAME"
    else
        create_container
    fi
}

health_check() {
    local attempt
    command -v curl >/dev/null 2>&1 || {
        log_error "curl wird für den lokalen Health-Check benötigt"
        return 1
    }
    for attempt in {1..30}; do
        if (( attempt == 1 )); then
            log_info "Warte auf den Dienst auf Port $WEB_PORT"
        fi
        if curl --fail --silent --show-error \
            "http://127.0.0.1:$WEB_PORT/" >/dev/null 2>&1; then
            log_success "Dienst erreichbar unter http://127.0.0.1:$WEB_PORT"
            return 0
        fi
        sleep 2
    done
    log_error "Dienst nach 60 Sekunden nicht erreichbar"
    docker logs --tail 50 "$CONTAINER_NAME" >&2 || true
    return 1
}

show_config() {
    cat <<EOF
Image               : $IMAGE_NAME
Container           : $CONTAINER_NAME
Web-Port            : $WEB_PORT -> 80
RustDesk-Backend    : $BACKEND_HOST
Backend-Protokoll   : $PROTO
Quell-Repository    : $RUSTDESK_REPO
Quell-Referenz      : $RUSTDESK_TAG
Expliziter Commit   : ${RUSTDESK_COMMIT:-<automatisch>}
Stabiler Commit     : $RUSTDESK_EXPECTED_COMMIT
Flutter             : $FLUTTER_VERSION
Rust                : $RUST_VERSION
WSS-Umwandlung      : $ENABLE_WSS
EOF
}

show_status() {
    if ! container_exists; then
        log_error "Container $CONTAINER_NAME existiert nicht"
        return 1
    fi

    local state health image ports
    state="$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")"
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}nicht konfiguriert{{end}}' "$CONTAINER_NAME")"
    image="$(docker inspect --format '{{.Config.Image}}' "$CONTAINER_NAME")"
    ports="$(docker port "$CONTAINER_NAME" 80/tcp 2>/dev/null || true)"

    printf 'Container  : %s\nImage      : %s\nZustand    : %s\nGesundheit : %s\nWeb-Port   : %s\n' \
        "$CONTAINER_NAME" "$image" "$state" "$health" "${ports:-nicht veröffentlicht}"
}

compose_up() {
    detect_compose
    "${COMPOSE[@]}" config --quiet
    "${COMPOSE[@]}" up --build --detach
    health_check
}

usage() {
    cat <<EOF
Aufruf: $0 BEFEHL

Befehle:
  build    Aufräumen, Image bauen und Container starten
  image    Nur das Image bauen
  start    Vorhandenen Container starten oder aus dem Image erzeugen
  stop     Container stoppen
  logs     Logs des Containers verfolgen
  status   Tatsächlichen Docker-Status anzeigen
  config   Effektive Konfiguration anzeigen
  compose  Mit Docker Compose bauen und starten
  clean    Container und lokales Image entfernen
EOF
}

run_command() {
    local command="${1:-}"
    case "$command" in
        build)
            check_prerequisites
            cleanup
            build_image
            create_container
            health_check
            ;;
        image)
            check_prerequisites
            build_image
            ;;
        start)
            check_prerequisites
            start_container
            health_check
            ;;
        stop)
            check_prerequisites
            container_exists && docker stop "$CONTAINER_NAME" >/dev/null
            ;;
        logs)
            check_prerequisites
            docker logs --follow "$CONTAINER_NAME"
            ;;
        status)
            command -v docker >/dev/null 2>&1 || return 1
            show_status
            ;;
        config)
            show_config
            ;;
        compose)
            check_prerequisites
            compose_up
            ;;
        clean)
            check_prerequisites
            cleanup
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            usage >&2
            return 64
            ;;
    esac
}

show_menu() {
    cat <<'EOF'

RustDesk Web Client
1. Kompletter Build
2. Nur das Image bauen
3. Starten
4. Stoppen
5. Logs
6. Status
7. Konfiguration
8. Docker Compose
9. Aufräumen
0. Beenden
EOF
}

interactive_menu() {
    local choice
    while true; do
        show_menu
        read -r -p "Wählen Sie eine Option [0-9]: " choice
        case "$choice" in
            1) run_command build ;;
            2) run_command image ;;
            3) run_command start ;;
            4) run_command stop ;;
            5) run_command logs ;;
            6) run_command status ;;
            7) run_command config ;;
            8) run_command compose ;;
            9) run_command clean ;;
            0) return 0 ;;
            *) log_error "Ungültige Option" ;;
        esac
    done
}

trap 'log_error "Skript abgebrochen"; exit 130' INT TERM

if (( $# == 0 )); then
    interactive_menu
else
    if (( $# != 1 )); then
        usage >&2
        exit 64
    fi
    run_command "$1"
fi
