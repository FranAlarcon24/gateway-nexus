#!/usr/bin/env bash
# Tests automáticos del gateway: levanta la imagen y revisa los códigos de respuesta.
# Uso: bash tests/test_gateway.sh <imagen>   (en CI: gateway-test)
# Sin los demás servicios, las rutas válidas responden 503 (JSON del gateway):
# eso basta para probar que la clave, el límite y el tamaño se aplican ANTES del servicio.
set -u
IMAGEN="${1:-gateway-test}"
CLAVE="clave-de-prueba-ci-123456"   # clave falsa, solo para el test
URL="http://localhost:8080"
FALLOS=0

docker rm -f gw-test >/dev/null 2>&1 || true
docker run -d --name gw-test -p 8080:8080 -e API_KEY="$CLAVE" -e RATE_LIMIT=5r/s "$IMAGEN" >/dev/null
trap 'docker rm -f gw-test >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 30); do
    curl -fs "$URL/health" >/dev/null 2>&1 && break
    sleep 0.5
done

codigo() { curl -s -o /tmp/cuerpo -w '%{http_code}' "$@"; }

revisar() {  # revisar "<nombre>" <esperado> <obtenido>
    if [ "$2" = "$3" ]; then
        echo "OK    $1 -> $3"
    else
        echo "FALLA $1 -> esperado $2, obtenido $3"; cat /tmp/cuerpo 2>/dev/null; echo
        FALLOS=$((FALLOS + 1))
    fi
}

json_detail() {  # el cuerpo debe ser {"detail": "..."}
    if grep -q '"detail"' /tmp/cuerpo; then echo "OK    $1 responde {\"detail\": ...}"
    else echo "FALLA $1 no responde JSON con detail"; FALLOS=$((FALLOS + 1)); fi
}

echo "== Salud y rutas públicas"
revisar "GET /health" 200 "$(codigo "$URL/health")"
c=$(codigo "$URL/api/health"); [ "$c" != 401 ] && echo "OK    GET /api/health es pública ($c)" || { echo "FALLA /api/health pidió clave"; FALLOS=$((FALLOS + 1)); }

echo "== 401: autenticación con X-API-Key"
revisar "POST /api/predict sin clave" 401 "$(codigo -X POST "$URL/api/predict")"
json_detail "401"
revisar "POST /api/predict con clave incorrecta" 401 "$(codigo -X POST -H 'X-API-Key: clave-incorrecta-000000' "$URL/api/predict")"
revisar "GET /api/predicciones/abc sin clave" 401 "$(codigo "$URL/api/predicciones/abc")"
revisar "POST /api/campanas/U1 sin clave" 401 "$(codigo -X POST "$URL/api/campanas/U1")"
c=$(codigo -X POST -H "X-API-Key: $CLAVE" "$URL/api/predict"); [ "$c" != 401 ] && echo "OK    con clave correcta pasa al servicio ($c)" || { echo "FALLA rechazó la clave correcta"; FALLOS=$((FALLOS + 1)); }

echo "== 413 (test propio): cuerpo mayor a 1 MB"
head -c 2000000 /dev/zero | tr '\0' 'a' > /tmp/grande.txt
revisar "POST /api/predict con 2 MB" 413 "$(codigo -X POST -H "X-API-Key: $CLAVE" --data-binary @/tmp/grande.txt "$URL/api/predict")"
json_detail "413"

echo "== 404 en JSON para rutas /api/ inexistentes"
revisar "GET /api/no-existe" 404 "$(codigo -H "X-API-Key: $CLAVE" "$URL/api/no-existe")"

echo "== 429: rate limiting (5r/s + ráfaga de 20)"
sleep 5   # recupera el cupo usado por los tests anteriores
N429=0
for _ in $(seq 1 40); do
    [ "$(codigo -H "X-API-Key: $CLAVE" "$URL/api/predicciones/abc")" = 429 ] && N429=$((N429 + 1))
done
if [ "$N429" -gt 0 ]; then echo "OK    40 peticiones seguidas -> $N429 respondieron 429"; else echo "FALLA ninguna petición recibió 429"; FALLOS=$((FALLOS + 1)); fi
revisar "petición 41 (sobre el límite)" 429 "$(codigo -H "X-API-Key: $CLAVE" "$URL/api/predicciones/abc")"
json_detail "429"

echo "== curl disponible para el healthcheck del compose"
docker exec gw-test curl -fsS http://localhost:8080/health >/dev/null && echo "OK    curl existe en la imagen" || { echo "FALLA la imagen no tiene curl"; FALLOS=$((FALLOS + 1)); }

echo
if [ "$FALLOS" -eq 0 ]; then echo "Todos los tests pasaron"; else echo "$FALLOS test(s) fallaron"; docker logs gw-test 2>&1 | tail -20; exit 1; fi
