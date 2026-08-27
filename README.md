# RustDesk Web Client — Docker-Images

Dieses Repository baut und betreibt den RustDesk-Web-Client in zwei klar getrennten Varianten.

| Variante | Image | Interner Port | Laufzeit-Konfiguration |
|---|---|---:|---|
| Aktuell | `pmietlicki/docker-rustdesk-web-client:latest` | `80` | Nginx-Proxy über `BACKEND_HOST` und `PROTO` |
| Alt (v1) | `pmietlicki/docker-rustdesk-web-client:v1` | `5000` | RustDesk-Variablen werden in den `localStorage` injiziert |

Die Variante `v1` bleibt für alle erhalten, die Rendezvous-, Relay- und API-Server direkt beim Start des Containers angeben müssen.

## Start der aktuellen Variante

Kopieren Sie die Beispielkonfiguration und passen Sie mindestens das RustDesk-Backend an:

```bash
cp config-examples.env .env
$EDITOR .env
docker compose up --build --detach
```

Die Oberfläche ist anschließend unter <http://localhost:5000> erreichbar.

Der Nginx-Container stellt ausschließlich seinen HTTP-Port `80` bereit. API- und WebSocket-Verbindungen werden über denselben Port weitergeleitet:

- `/api/` an den Backend-Port `21114`;
- `/ws/id` an den Backend-Port `21118`;
- `/ws/relay` an den Backend-Port `21119`.

`BACKEND_HOST` muss ein Hostname oder eine IP-Adresse sein, die aus dem Container heraus erreichbar ist — ohne Schema und ohne Port. Eine IPv6-Adresse gehört in eckige Klammern. `PROTO` akzeptiert nur `http` oder `https` und beschreibt die Verbindung zwischen Nginx und dem Backend; die öffentliche TLS-Terminierung muss ein Reverse-Proxy oder ein Ingress übernehmen.

Direkter Start des veröffentlichten Images:

```bash
docker run --detach \
  --name rustdesk-web-client \
  --publish 5000:80 \
  --env BACKEND_HOST=rustdesk.example.com \
  --env PROTO=https \
  pmietlicki/docker-rustdesk-web-client:latest
```

## Variante v1

```bash
docker run --detach \
  --name rustdesk-web-v1 \
  --publish 5000:5000 \
  --env CUSTOM_RENDEZVOUS_SERVER=rustdesk.example.com:21116 \
  --env RELAY_SERVER=rustdesk.example.com:21117 \
  --env API_SERVER=api.example.com \
  --env KEY='votre-clé-publique' \
  pmietlicki/docker-rustdesk-web-client:v1
```

| Variable | Standard | Beschreibung |
|---|---|---|
| `CUSTOM_RENDEZVOUS_SERVER` | leer | Rendezvous-Server samt Port |
| `RELAY_SERVER` | leer | Relay-Server samt Port |
| `API_SERVER` | `api.rustdesk.com` | API-Server |
| `KEY` | leer | Öffentlicher RustDesk-Schlüssel |
| `PORT` | `5000` | Interner HTTP-Port der Variante v1 |

Die Werte werden als JSON serialisiert, bevor sie in `env-config.js` geschrieben werden, damit Anführungszeichen, Backslashes und Zeilenumbrüche das erzeugte JavaScript nicht zerstören können.

Lokaler Build dieser Variante:

```bash
docker build --file v1/Dockerfile --tag rustdesk-web-client:v1-local .
```

## Lokaler Build

Das Skript lädt `.env` automatisch, ohne es als Shell-Code auszuführen.

```bash
./build.sh config   # effektive Konfiguration
./build.sh image    # nur das Image bauen
./build.sh build    # aufräumen, bauen, starten und Health-Check ausführen
./build.sh status   # tatsächlicher Docker-Status
./build.sh logs     # Logs verfolgen
./build.sh stop
./build.sh start
./build.sh clean
./build.sh compose  # derselbe Ablauf über Docker Compose
```

Der Standard-Build verwendet `MonsieurBiche/rustdesk-web-client`, Branch `fix-build`, festgenagelt auf den Commit aus `RUSTDESK_EXPECTED_COMMIT`. Über `RUSTDESK_REPO` und `RUSTDESK_TAG` lässt sich eine andere Quelle wählen; `RUSTDESK_COMMIT` nagelt jede beliebige Quelle explizit auf einen SHA fest.

Das Archiv `web_deps.tar.gz` wird aus dem aktuellen Checkout gelesen: Der Build eines bestimmten Commits verwendet damit nicht mehr stillschweigend das Archiv einer anderen Revision von `main`.

## Konfiguration `.env`

Alle verfügbaren Werte sind in [config-examples.env](config-examples.env) dokumentiert. Variablen, die bereits in der aufrufenden Umgebung gesetzt sind, haben Vorrang vor denen aus der Datei `.env`.

Die wichtigsten Werte:

| Variable | Standard | Verwendung |
|---|---|---|
| `WEB_PORT` | `5000` | Auf dem Host veröffentlichter HTTP-Port |
| `BACKEND_HOST` | `127.0.0.1` | Backend für die API-/WebSocket-Routen |
| `PROTO` | `http` | Protokoll des Backends (`http` oder `https`) |
| `RUSTDESK_REPO` | `MonsieurBiche/rustdesk-web-client` | Quell-Repository |
| `RUSTDESK_TAG` | `fix-build` | Quell-Branch oder -Tag |
| `RUSTDESK_COMMIT` | leer | Optionaler expliziter SHA |
| `ENABLE_WSS` | `true` | Umwandlung von `ws://`- in `wss://`-URLs während des Builds |
| `FLUTTER_VERSION` | `3.22.1` | Zum Kompilieren verwendete Flutter-Version |
| `RUST_VERSION` | `1.97.0` | Rust-Toolchain für das WebAssembly-Ziel |

Achtung: `127.0.0.1` bezeichnet den Web-Container selbst. Geben Sie einen anderen Host an, wenn das RustDesk-Backend in einem anderen Container oder auf einer anderen Maschine läuft.

## Validierung

Die schnellen lokalen Prüfungen sind:

```bash
bash -n build.sh v1/server/server.sh tests/*.sh
sh -n docker/nginx/entrypoint.sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
tests/test_build_script.sh
tests/test_nginx_entrypoint.sh
docker compose config --quiet
docker build --check .
```

Die CI führt dieselben Prüfungen aus, zusätzlich ShellCheck und Hadolint.

## Kubernetes

Das historische Deployment-Beispiel für die Variante `v1` ist in [docs/KUBERNETES.md](docs/KUBERNETES.md) erhalten. Es muss an Ingress, Storage und Secrets der jeweiligen Umgebung angepasst werden.

## Fehlersuche

```bash
./build.sh status
docker compose ps
docker compose logs --tail=100 rustdesk-web
curl --fail http://127.0.0.1:5000/
```

Wenn die Routen `/api/` oder `/ws/*` fehlschlagen, obwohl die Oberfläche lädt, prüfen Sie, ob `BACKEND_HOST` aus dem Container heraus aufgelöst wird und die betroffenen RustDesk-Ports im Docker-Netzwerk erreichbar sind.

## Lizenz

Dieses Repository folgt der AGPL-3.0-Lizenz des RustDesk-Projekts. Lesen Sie [LICENSE](LICENSE) sowie die Lizenzen der mitgelieferten Abhängigkeiten.
