# nexo-gateway

API gateway de Nexo (Caso 1 · Nexus Retail). Nginx es el único servicio que publica puerto (8080).

- Imagen: `ghcr.io/franalarcon24/gateway:ep2`

## Rutas

| Ruta pública | Destino interno |
|---|---|
| `/` | `front:8000` |
| `/api/dominio/...` | `dominio1:8000` o `dominio2:8000`, round-robin |
| `/api/ia/...` | `ia:8000` |
| `/health` | el propio gateway |

El prefijo se quita al reenviar: `/api/ia/predict` llega a la IA como `/predict`.

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
docker stop equipoNN-dominio1-1
docker start equipoNN-dominio1-1

# Detener la IA y ver qué responde el gateway
docker stop equipoNN-ia-1
curl.exe -si http://localhost:8080/api/ia/health

# Latencia por petición (tiempo=...)
docker compose -p equipoNN logs gateway --tail 20
```
