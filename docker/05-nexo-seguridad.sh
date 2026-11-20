#!/bin/sh
# Se ejecuta al arrancar el contenedor (antes de nginx).
# Nginx no lee variables de entorno: este script toma API_KEY del entorno (.env del servidor)
# y genera la configuración que valida la cabecera X-API-Key.
# La clave nunca queda en el repositorio ni dentro de la imagen.
set -eu

if [ -z "${API_KEY:-}" ]; then
    echo "ERROR: falta la variable API_KEY; el gateway no arranca sin clave." >&2
    exit 1
fi

# Solo caracteres seguros y mínimo 16: evita romper la configuración y claves débiles.
if ! printf '%s' "$API_KEY" | grep -Eq '^[A-Za-z0-9._~-]{16,}$'; then
    echo "ERROR: API_KEY debe tener al menos 16 caracteres (letras, números, . _ ~ -)." >&2
    exit 1
fi

mkdir -p /etc/nginx/nexo
cat > /etc/nginx/nexo/api_key.conf <<CONF
# Generado al arrancar. \$api_key_valida = 1 solo si X-API-Key coincide con API_KEY.
map \$http_x_api_key \$api_key_valida {
    default 0;
    "$API_KEY" 1;
}
CONF
# ---------- Rate limiting ----------
# RATE_LIMIT = peticiones por IP (por ejemplo 10r/s o 600r/m). Por defecto 10r/s.
RATE_LIMIT="${RATE_LIMIT:-10r/s}"
if ! printf '%s' "$RATE_LIMIT" | grep -Eq '^[0-9]+r/[sm]$'; then
    echo "ERROR: RATE_LIMIT debe tener el formato 10r/s o 600r/m." >&2
    exit 1
fi
cat > /etc/nginx/nexo/rate_limit.conf <<CONF
# Generado al arrancar desde RATE_LIMIT.
limit_req_zone \$limite_clave zone=api:10m rate=$RATE_LIMIT;
CONF

chmod 640 /etc/nginx/nexo/api_key.conf
chgrp nginx /etc/nginx/nexo/api_key.conf 2>/dev/null || true
