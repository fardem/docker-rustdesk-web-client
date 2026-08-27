# Schnellstart

## Docker Compose

```bash
git clone https://github.com/pmietlicki/docker-rustdesk-web-client.git
cd docker-rustdesk-web-client
cp config-examples.env .env
$EDITOR .env
docker compose up --build --detach
curl --fail http://127.0.0.1:5000/
```

Setzen Sie in `.env` die Variable `BACKEND_HOST` auf einen Host, der aus dem Container heraus erreichbar ist. Der Web-Dienst wird auf `WEB_PORT` veröffentlicht, der interne Port des aktuellen Images ist `80`.

## Verwaltungsskript

```bash
./build.sh config
./build.sh build
./build.sh status
./build.sh logs
```

Das Skript bietet außerdem `image`, `start`, `stop`, `clean` und `compose`. Führen Sie `./build.sh --help` aus, um die aktuelle Liste zu sehen.

## Vorgefertigte Variante v1

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

Details zu Variablen, Proxy-Routen und Validierungsschritten finden Sie in [README.md](README.md).
