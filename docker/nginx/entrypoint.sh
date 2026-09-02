#!/bin/sh
set -eu

host="${BACKEND_HOST:-127.0.0.1}"
proto="${PROTO:-http}"
template="${NGINX_TEMPLATE:-/etc/nginx/templates/default.conf.template}"
config="${NGINX_CONFIG:-/etc/nginx/conf.d/default.conf}"

case "$proto" in
    http|https) ;;
    *)
        echo "PROTO muss 'http' oder 'https' sein (erhaltener Wert: $proto)" >&2
        exit 64
        ;;
esac

if ! printf '%s\n' "$host" | grep -Eq '^([A-Za-z0-9._-]+|\[[0-9A-Fa-f:]+\])$'; then
    echo "BACKEND_HOST muss ein Hostname, eine IPv4 oder eine IPv6 in eckigen Klammern sein" >&2
    exit 64
fi

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

escaped_host="$(escape_sed_replacement "$host")"
escaped_proto="$(escape_sed_replacement "$proto")"

cp "$template" "$config"
sed -i \
    -e "s|PLACEHOLDER_HOST|$escaped_host|g" \
    -e "s|PROTO|$escaped_proto|g" \
    "$config"

nginx -t
exec nginx -g 'daemon off;'
