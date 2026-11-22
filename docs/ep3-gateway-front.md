# EP3 · Gateway, front y prueba de carga

**Proyecto:** Nexo, Caso 1 Nexus Retail (Equipo 2), ITY1102.
**Responsable:** Francisca Alarcón ([@FranAlarcon24](https://github.com/FranAlarcon24)).
**Repositorios:** [gateway-nexus](https://github.com/FranAlarcon24/gateway-nexus) y [Frontend-Nexus](https://github.com/ealejandro23/Frontend-Nexus).
**Imágenes:** `ghcr.io/franalarcon24/gateway:ep3` y `ghcr.io/ealejandro23/front:ep3`.
**URL:** `https://3-215-113-161.sslip.io` (EC2 t3.medium, us-east-1, IP elástica).

## 1. Camino de una petición

```
Internet ──443──► edge (Caddy, TLS) ──► gateway (Nginx :8080) ──► front :8000
                     │ 80 → 308 HTTPS          │  401 · 429 · 413   ├──► dominio / dominio2 :8000 ──► SageMaker serverless (200 ms)
                     │ cuerpo > 2 MB → 413     │                    │                               └─ reserva: ia :8000 (modelo local)
                     │                         │                    └──► campanas :8090 ──► RabbitMQ ──► worker ──► NVIDIA
```

- `POST /api/predict` invoca el endpoint **serverless de SageMaker** `nexo-recomendacion` (XGBoost integrado 1.7-1, 2048 MB, concurrencia 10). Si no responde en `TIMEOUT_MODELO_MS` (200 ms), por ejemplo por un cold start o por throttling, el dominio usa la **reserva** (el modelo local del servicio `ia`). La respuesta indica `origen` (`sagemaker` o `reserva`), `latencia_ms` y `motivo_reserva`.
- Medido en AWS: con el endpoint frío, la petición salió por `reserva` (`ReadTimeoutError` a los 200 ms) mientras SageMaker encendía el contenedor. Ya en caliente, `origen: sagemaker` con **~40 ms**. La primera petición de cada réplica tarda ~1 s, porque abre la conexión TLS y obtiene las credenciales de `LabInstanceProfile`.
- **Cold start medido** (21/11/2026, 22:28, después de 11 minutos sin uso):

  | Petición | Origen | Latencia en el dominio | Lectura |
  |---|---|---|---|
  | 1.ª | `reserva` | 66 ms | SageMaker enciende el contenedor; el dominio corta a los 200 ms (`ReadTimeoutError`) y responde con el modelo local |
  | 2.ª (10 s después) | `sagemaker` | 148 ms | Contenedor recién arrancado |
  | 3.ª | `sagemaker` | 124 ms | |
  | 4.ª a 6.ª | `sagemaker` | 42–48 ms | En caliente |

  El cliente nunca recibe un error: durante el cold start responde la reserva. Antes de la demo conviene hacer una predicción y esperar unos 10 s.
- El endpoint se crea con `sagemaker/desplegar.py` (en Backend-Nexus, adaptado de la guía del curso) desde CloudShell. El cold start se mide con `sagemaker/probar.py`.

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

**Consentimiento (RN2):** solo se personaliza a quien tiene `acepta_marketing = 1` (2.077 de 4.000 clientes). Para el resto, el dominio responde los más vendidos con `origen: "regla"` y el front muestra el motivo ("El cliente no dio consentimiento para usar su historial"). Cuenta como respuesta con lista de reserva en el dashboard.

**Observabilidad:** los servicios de la aplicación envían sus logs a CloudWatch Logs (`/ity1102/proyecto`, driver `awslogs` con el rol de la EC2). Cada predicción deja un log `{"evento": "prediccion", "id": ..., "origen": ..., "latencia_ms": ...}`, buscable por `id`. El dashboard `proyecto-ep3` muestra `Invocations`, `ModelLatency`, `ModelSetupTime`, errores 4XX/5XX, la CPU de la EC2 y las últimas predicciones; hay alarmas para 5XX del endpoint y para CPU > 80 %. `/api/health` informa base de datos, cola, LLM y el estado del endpoint de SageMaker.

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

Cuatro mediciones con el mismo escenario (`POST /api/predict`, 20 usuarios virtuales, 3 minutos, desde Chile contra `https://3-215-113-161.sslip.io`). Para medir capacidad se subió temporalmente `RATE_LIMIT=200r/s` y después se volvió a `10r/s`. El informe final está en [evidencias/locust-ep3-final.html](evidencias/locust-ep3-final.html).

| Medición | Peticiones | req/s | p50 | p95 | p99 | Errores |
|---|---|---|---|---|---|---|
| 1. Inicial (modelo local, sin índices; 21/11) | 658 | 3,7 | 4.200 ms | 5.300 ms | 5.700 ms | 0 % |
| 2. SageMaker + índices | 1.088 | 6,1 | 2.200 ms | 2.800 ms | 3.600 ms | 0,09 % |
| 3. + PostgreSQL a 1 CPU | 2.134 | 12,0 | 590 ms | 1.200 ms | 1.800 ms | 0 % |
| **4. + pool de conexiones + dominio a 0,5 CPU (22/11)** | **2.775** | **15,6** | **210 ms** | **380 ms** | **1.100 ms** | **0,11 %** (3 × 504) |

**Cómo se encontró cada cuello de botella:** `docker stats` durante la carga y los tiempos del log del gateway (`upstream_tiempo`).

| # | Optimización | Qué mejoró (medido) | Costo |
|---|---|---|---|
| 1 | Índices en `transacciones(usuario_id, pedido_id, sku)` y `clickstream(usuario_id)` | p50 4,2 s → 2,2 s | USD 0 |
| 2 | PostgreSQL de 0,25 a 1 CPU (estaba en su límite, 26,8 %) | p50 2,2 s → 590 ms; req/s ×2 | USD 0 (capacidad ociosa de la t3.medium) |
| 3 | Pool de conexiones en el dominio (antes abría 3 conexiones por predicción) + dominio a 0,5 CPU | p50 590 → 210 ms; req/s ×1,3 | USD 0 |

**RNF1 (p95 < 200 ms):** no se cumple aún: el p95 es de 380 ms medido desde Chile, y ~150 ms de eso corresponden a la red Chile–us-east-1. Próximo paso: precalcular las propensiones de noche (la consulta en línea pasaría a ser una lectura) o desplegar en `sa-east-1`. El rate limiting se demuestra aparte, con 40 peticiones en paralelo: 15 a 17 reciben `429`.

## 7. Verificación en AWS

El script `scripts/verificar-aws.ps1` se ejecutó contra el sistema desplegado: **15 de 15 pruebas OK**. La salida completa está en [evidencias/verificacion-aws.txt](evidencias/verificacion-aws.txt).

- `/health`, `/api/health`, `/`, `/docs` y `/dashboard` → 200. HTTP redirige a HTTPS con 308, y el certificado lo emite Caddy.
- Sin clave o con clave inválida, en `/api/predict`, `/api/campanas/{usuario}` y `/api/predicciones/{id}` → 401 `{"detail": ...}`.
- `POST /api/predict` con clave → 200. Con `{}` → 422.
- `X-Upstream` alterna entre las 2 réplicas del dominio (round-robin).
- Cuerpo de 1,5 MB → 413. 40 peticiones en paralelo → 17 con 429.
- `POST /api/campanas/{usuario}` → 202 con `job_id`. `GET /api/predicciones/{job_id}` → 200. En la prueba, NVIDIA rechazó la clave (403) y el worker entregó el mensaje genérico marcado `degradado: true`: el modo degradado funcionando de punta a punta.

**Error encontrado y corregido durante la verificación:** `GET /api/predicciones/{id}` llegaba a `campanas` sin el id. En nginx, los `map` con expresión regular que se evalúan después (rate limiting) sobrescriben `$1`. Se cambió a `rewrite ... break` y se agregó `tests/test_rutas.sh` al CI: levanta servicios falsos con los nombres del compose y comprueba que las 7 rutas lleguen a su servicio y ruta interna sin la cabecera `X-API-Key`.

## 8. Limitaciones conocidas

- Los contadores del dashboard viven en memoria del front y se reinician si se reinicia el contenedor.
- El rate limiting es por IP. Varios usuarios detrás de una misma red (NAT) comparten el cupo.
- El servicio de campañas no invoca el endpoint (lo hace el dominio): su `SAGEMAKER_ENDPOINT_NAME` queda vacío y toma las propensiones guardadas en PostgreSQL; `/api/health` igual informa el estado del endpoint vía `ENDPOINT_MODELO`.
- **Fuga de etiqueta (corregida el 22/11/2026):** en `datos/preparar.py`, la etiqueta es `propension_compra = num_compras_categoria > 0`. Entrenar con `num_compras_categoria`, `total_gastado_categoria` o `dias_ultima_compra` (que salen de esas mismas compras) daba ROC-AUC 1,000, un modelo "perfecto" que no aprendía nada. El modelo del endpoint ahora usa 6 variables: vistas y clics en la categoría (el dominio las calcula desde el clickstream), frecuencia de compra, ticket promedio, edad y acepta_marketing. Validación en SageMaker: **PR-AUC 0,967** (train 0,975), contra 0,798 del azar (la proporción de positivos). Fuera de la línea, con un clasificador equivalente: ROC-AUC 0,915.
