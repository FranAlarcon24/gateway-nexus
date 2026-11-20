# nexo-gateway

API gateway de Nexo (Caso 1 · Nexus Retail). En EP3 queda detrás de Caddy (`edge`, puertos 80/443) y escucha en `8080` solo dentro de la red de Docker.

- Imagen: `ghcr.io/franalarcon24/gateway:ep3`

## Rutas

| Ruta pública | Destino interno |
|---|---|
| `GET /api/health` | `campanas:8090/api/health` |
| `POST /api/predict` | `dominio:8000` o `dominio2:8000` → `POST /predicciones` |
| `GET /api/predicciones/{id}` | `campanas:8090/api/campanas/jobs/{id}` |
| `POST /api/campanas/{usuario}` | `campanas:8090/api/campanas/{usuario}` |
| `GET /docs` | `campanas:8090/docs` (OpenAPI) |
| `/` | `front:8000` |
| `/api/dominio/...` | `dominio:8000` o `dominio2:8000`, round-robin |
| `/api/ia/...` | `ia:8000` |
| `/health` | el propio gateway |

El prefijo se quita al reenviar: `/api/ia/predict` llega a la IA como `/predict`.

## Autenticación (X-API-Key)

- Todo `/api/...` exige la cabecera `X-API-Key`, salvo `GET /api/health`. `/docs` y el front son públicos.
- Sin clave o con clave incorrecta: `401 {"detail": "..."}`, sin llegar a ningún servicio.
- La clave se lee de `API_KEY` (archivo `.env` del servidor, ver `.env.example`). Al arrancar, `docker/05-nexo-seguridad.sh` genera `/etc/nginx/nexo/api_key.conf`. Si falta `API_KEY` o tiene menos de 16 caracteres, el gateway no arranca.
- La clave no está en el repositorio ni en la imagen, y no se reenvía a los servicios internos.

```powershell
curl.exe -si -X POST https://<ip-con-guiones>.sslip.io/api/predict                             # 401
curl.exe -si -X POST -H "X-API-Key: $env:API_KEY" -H "Content-Type: application/json" `
  -d '{\"usuario_id\":\"U100000\",\"categoria\":\"audio\"}' https://<ip-con-guiones>.sslip.io/api/predict   # 200
```

## Rate limiting (429) y tamaño máximo (413)

- `/api/...`: máximo `RATE_LIMIT` peticiones por IP (por defecto `10r/s`) con una ráfaga de 20; sobre eso, `429 {"detail": "..."}` con `Retry-After`.
- La IP real del cliente se toma de `X-Real-IP` (la pone Caddy), solo si la petición viene de la red interna de Docker.
- Cuerpo mayor a 1 MB: `413 {"detail": "..."}` (Caddy ya corta en 2 MB; el gateway es la segunda barrera).

## Tests automáticos

`tests/test_gateway.sh` corre en el CI (job `test`) en cada PR: levanta la imagen con una clave de prueba y revisa:
401 sin clave o con clave incorrecta, 429 al superar el límite, 413 con un cuerpo de 2 MB (test propio), 404 en JSON para rutas `/api/` inexistentes, que `/api/health` sea pública y que el gateway no arranque sin `API_KEY`. Si un test falla, no se publica la imagen.

```bash
docker build -t gateway-test . && bash tests/test_gateway.sh gateway-test
```

## Health checks

- **Pasivos (Nginx):** si una réplica no responde (error de conexión o timeout), queda fuera 10 s (`max_fails=1 fail_timeout=10s`) y la petición se reintenta en la otra (`proxy_next_upstream error timeout`). Un `503` que responde el propio dominio (por ejemplo, porque la IA está caída) no cuenta como falla de la réplica.
- **DNS (`resolve`):** Nginx vuelve a consultar cada 5 s la IP de cada servicio en el DNS de Docker (`127.0.0.11`). Una réplica detenida desaparece del balanceo y, al reiniciarla, vuelve sola aunque cambie de IP.
- **Activos (Docker):** el `healthcheck:` del compose consulta `/health` de cada contenedor cada 10 s.
- Si Nginx no logra hablar con un servicio, responde `503` con JSON en vez de su página de error. Si el servicio responde su propio error, ese JSON pasa intacto.

## Comandos para la defensa (PowerShell)

```powershell
# Ver el balanceo: repetir y mirar cómo cambia X-Upstream
curl.exe -si http://localhost:8080/api/dominio/health

# Detener una réplica y seguir usando el front
docker stop equipo02-dominio-1
docker start equipo02-dominio-1

# Detener la IA y ver qué responde el gateway
docker stop equipo02-ia
curl.exe -si http://localhost:8080/api/ia/health

# Latencia por petición (tiempo=...)
docker compose -p equipo02 logs gateway --tail 20
```
