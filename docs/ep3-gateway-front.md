# EP3 · Gateway, front y prueba de carga

**Proyecto:** Nexo, Caso 1 Nexus Retail (Equipo 2), ITY1102.
**Responsable:** Francisca Alarcón ([@FranAlarcon24](https://github.com/FranAlarcon24)).
**Repositorios:** [gateway-nexus](https://github.com/FranAlarcon24/gateway-nexus) y [Frontend-Nexus](https://github.com/ealejandro23/Frontend-Nexus).
**Imágenes:** `ghcr.io/franalarcon24/gateway:ep3` y `ghcr.io/ealejandro23/front:ep3`.
**URL:** `https://3-215-113-161.sslip.io` (EC2 t3.medium, us-east-1, IP elástica).

## 1. Camino de una petición

```
Internet ──443──► edge (Caddy, TLS) ──► gateway (Nginx :8080) ──► front :8000
                     │ 80 → 308 HTTPS          │  401 · 429 · 413   ├──► dominio / dominio2 :8000 ──► ia :8000
                     │ cuerpo > 2 MB → 413     │                    └──► campanas :8090 ──► RabbitMQ ──► worker ──► NVIDIA
```

- Solo Caddy publica puertos (80 y 443). El gateway escucha en la red interna de Docker.
- Toda la API pasa por el gateway, excepto `GET /api/health`, que es pública y Caddy la envía directo a `campanas`.

## 2. Rutas del enunciado

| Ruta pública | Clave | Destino interno |
|---|---|---|
| `GET /api/health` | no | `campanas:8090/api/health` (estado de la base de datos, la cola, SageMaker y el LLM) |
| `POST /api/predict` | sí | `dominio`/`dominio2` → `POST /predicciones` (modelo propio, round-robin) |
| `GET /api/predicciones/{id}` | sí | `campanas:8090/api/campanas/jobs/{id}` (texto del LLM según el `job_id`) |
| `POST /api/campanas/{usuario}` | sí | `campanas:8090/api/campanas/{usuario}` (encola el job del LLM; 202) |
| `GET /docs` | no | OpenAPI de `campanas` |

- Una entrada inválida responde `422`, nunca `500`.
- Todos los errores tienen el formato `{"detail": "..."}`, incluidos los que genera el propio gateway (401, 404, 413, 429 y 503).

## 3. Seguridad y límites en el gateway

| Control | Implementación | Respuesta |
|---|---|---|
| **Autenticación** | Cabecera `X-API-Key` comparada con `API_KEY`. Exigida en todo `/api/...` salvo `/api/health` | `401 {"detail": ...}` |
| **Rate limiting** | `limit_req` por IP del cliente: `RATE_LIMIT` (10 r/s por defecto) con una ráfaga de 20 | `429` + `Retry-After` |
| **Tamaño máximo** | `client_max_body_size 1m` (segunda barrera; Caddy corta en 2 MB) | `413` |
| **Servicio caído** | `error_page 502 503 504` | `503 {"detail": ...}` |

**Decisiones de diseño**

- **La clave no está en el repositorio ni en la imagen.** Al arrancar, `docker/05-nexo-seguridad.sh` lee `API_KEY` del `.env` del servidor y genera la configuración. Si falta o tiene menos de 16 caracteres, **el gateway no arranca** (*fail closed*), así nunca queda la API abierta por error.
- **La clave no se reenvía a los servicios internos** (`proxy_set_header X-API-Key ""`): solo el gateway la conoce.
- **IP real detrás de Caddy.** Sin ajuste, todas las peticiones parecerían venir de Caddy y compartirían un solo límite. Por eso se usa `X-Real-IP`, aceptada solo desde la red interna de Docker (`set_real_ip_from`).
- **El front no consume cupo por los usuarios:** el límite se aplica solo a `/api/...`.

## 4. Front

| Requisito | Cómo se cumple |
|---|---|
| Entre 4 y 8 productos | `GET /api/dominio/api/recomendaciones?usuario_id=...&limite=8` (compras en conjunto y popularidad) |
| Lista de reserva (más vendidos) | Se usa si el recomendador falla, si el cliente no tiene historial o si llegan menos de 4 productos. La lista se guarda en memoria 5 minutos para seguir funcionando aunque el dominio falle |
| Texto del LLM | `POST /api/campanas/{usuario}` devuelve un `job_id`; la página consulta cada 2 s, hasta 30 s, `GET /api/predicciones/{job_id}` a través del servidor del front |
| Modo degradado | Si la campaña no se encola, no llega a tiempo o el worker la marca como `degradado`: aviso visible, y las recomendaciones siguen funcionando |
| Seguridad | La clave `X-API-Key` nunca llega al navegador (hay un test que lo comprueba) |

**Dashboard:** recomendaciones entregadas, cuántas usaron la lista de reserva y su **proporción**, mensajes del LLM entregados y respuestas en modo degradado. Son contadores en memoria desde el último reinicio del front.

## 5. Tests automáticos y CI/CD

| Repo | Qué se prueba | Dónde |
|---|---|---|
| gateway | **401** sin clave o con clave inválida, **429** al superar el límite, **413** con 2 MB (test propio), 404 en JSON, `/api/health` pública y que el gateway no arranque sin `API_KEY` | `tests/test_gateway.sh`, job `test` |
| front | 19 tests: productos, lista de reserva, LLM listo/pendiente/degradado, `job_id` inválido → 422, clave no expuesta, dashboard | `pytest`, job `test` |

**Correcciones de la retroalimentación de EP2**

- Se quitó `|| echo "Warning..."` del gateway y `|| true` del front: ahora un test que falla **detiene** el pipeline. En el front, eso dejó a la vista 3 tests que llevaban tiempo fallando sin que nadie lo notara, y se corrigieron.
- `build-and-push` depende de `test` (`needs: test`).
- La imagen `:ep3` se construye desde el commit del tag `ep3` sobre `main` (`type=ref,event=tag`), en vez de re-etiquetar `:latest`.
- Gitflow: cada cambio va en una rama `feat/...` con PR hacia `dev`; luego `dev → main` por PR y el tag `ep3`.
- Nada secreto en el repositorio: solo `.env.example` sin valores reales, y `.env` está en `.gitignore`.

## 6. Prueba de carga (Locust)

- **Escenario:** `POST /api/predict` contra AWS, con usuarios y categorías reales y 20 usuarios virtuales durante 3 minutos. **No apunta al LLM.**
- **Script:** `carga/locustfile.py`; la tabla se genera con `carga/resumen.py`.

| Métrica | Con límite (10 r/s) | Capacidad (`RATE_LIMIT=200r/s`) |
|---|---|---|
| Peticiones totales | _completar_ | _completar_ |
| Req/s promedio | _completar_ | _completar_ |
| p50 | _completar_ ms | _completar_ ms |
| p95 | _completar_ ms | _completar_ ms |
| p99 | _completar_ ms | _completar_ ms |
| Errores | _completar_ (429 esperados) | _completar_ |

**Lectura:** con el límite activo, los `429` demuestran que el rate limiting protege el sistema ante un solo cliente. Al subir el límite se mide la capacidad real del recomendador (dominio → IA → PostgreSQL) en una t3.medium.

## 7. Limitaciones conocidas

- Los contadores del dashboard viven en memoria del front y se reinician si se reinicia el contenedor.
- El rate limiting es por IP. Varios usuarios detrás de una misma red (NAT) comparten el cupo.
- SageMaker: si `SAGEMAKER_ENDPOINT_NAME` no está configurado, el servicio de campañas usa las predicciones guardadas en PostgreSQL y `/api/health` lo informa como `no_configurado`.
