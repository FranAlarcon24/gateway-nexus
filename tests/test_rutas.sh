#!/usr/bin/env bash
# Test de enrutamiento: servicios falsos con los nombres reales del compose (campanas, dominio, dominio2...)
# responden con la ruta y las cabeceras que les llegaron. Así se comprueba que cada ruta del enunciado
# llega al servicio y a la ruta interna correctos, y que la clave X-API-Key NO se reenvía.
# Uso: bash tests/test_rutas.sh <imagen>
set -u
IMAGEN="${1:-gateway-test}"
CLAVE="clave-de-prueba-ci-123456"
URL="http://localhost:8081"
RED="nexo-test-rutas"
FALLOS=0

ECO='
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def responder(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n: self.rfile.read(n)
        cuerpo = json.dumps({"servicio": sys.argv[2], "ruta": self.path,
                             "api_key": self.headers.get("X-API-Key")}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(cuerpo))); self.end_headers(); self.wfile.write(cuerpo)
    do_GET = do_POST = responder
    def log_message(self, *a): pass
HTTPServer(("0.0.0.0", int(sys.argv[1])), H).serve_forever()
'

limpiar() { docker rm -f gw-rutas eco-campanas eco-8000 >/dev/null 2>&1; docker network rm "$RED" >/dev/null 2>&1; }
limpiar; trap limpiar EXIT
docker network create "$RED" >/dev/null
docker run -d --name eco-campanas --network "$RED" --network-alias campanas \
    python:3.12-alpine python -c "$ECO" 8090 campanas >/dev/null
docker run -d --name eco-8000 --network "$RED" \
    --network-alias dominio --network-alias dominio2 --network-alias front --network-alias ia \
    python:3.12-alpine python -c "$ECO" 8000 dominio >/dev/null
docker run -d --name gw-rutas --network "$RED" -p 8081:8080 -e API_KEY="$CLAVE" -e RATE_LIMIT=50r/s "$IMAGEN" >/dev/null

for _ in $(seq 1 40); do
    curl -fs -H "X-API-Key: $CLAVE" "$URL/api/health" 2>/dev/null | grep -q campanas && break
    sleep 0.5
done

ruta() {  # ruta "<nombre>" "<servicio esperado>" "<ruta interna esperada>" <args de curl...>
    local nombre="$1" servicio="$2" esperada="$3"; shift 3
    local r; r=$(curl -s "$@")
    if echo "$r" | grep -q "\"servicio\": \"$servicio\"" && echo "$r" | grep -q "\"ruta\": \"$esperada\"" \
       && echo "$r" | grep -q '"api_key": null'; then
        echo "OK    $nombre -> $servicio $esperada (sin X-API-Key)"
    else
        echo "FALLA $nombre -> esperado $servicio $esperada, obtenido: $r"; FALLOS=$((FALLOS + 1))
    fi
}

K=(-H "X-API-Key: $CLAVE")
ruta "GET /api/health"              campanas "/api/health"                 "$URL/api/health"
ruta "POST /api/predict"            dominio  "/predicciones"               -X POST "${K[@]}" -d '{}' "$URL/api/predict"
ruta "GET /api/predicciones/{id}"   campanas "/api/campanas/jobs/abc-123"  "${K[@]}" "$URL/api/predicciones/abc-123"
ruta "POST /api/campanas/{usuario}" campanas "/api/campanas/U100000"       -X POST "${K[@]}" "$URL/api/campanas/U100000"
ruta "GET /docs"                    campanas "/docs"                       "$URL/docs"
ruta "GET /openapi.json"            campanas "/openapi.json"               "$URL/openapi.json"
ruta "GET /api/dominio/usuarios"    dominio  "/usuarios"                   "${K[@]}" "$URL/api/dominio/usuarios"

echo
if [ "$FALLOS" -eq 0 ]; then echo "Todas las rutas llegan a su destino"; else echo "$FALLOS ruta(s) fallaron"; docker logs gw-rutas 2>&1 | tail -20; exit 1; fi
