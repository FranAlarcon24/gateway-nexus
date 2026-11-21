# Demo · Gateway y front (presentación jueves 26/11)

Guion de unos 5 minutos. Antes: encender la EC2, abrir el navegador en la URL y tener PowerShell en la carpeta `gateway-nexus`.

| # | Mostrar | Cómo | Qué decir |
|---|---|---|---|
| 1 | El sistema arriba con HTTPS | Abrir `https://3-215-113-161.sslip.io` (candado) | "Caddy saca el certificado solo con sslip.io; solo están abiertos el 80 y el 443." |
| 2 | Recomendaciones | Elegir un cliente → *Calcular* | "Entre 4 y 8 productos del recomendador; si falla o el cliente es nuevo, usamos los más vendidos." |
| 3 | Texto del LLM | Esperar el mensaje personalizado | "El front encola un job: el worker lo toma de RabbitMQ, llama a NVIDIA y el front consulta hasta que llega." |
| 4 | Modo degradado | `docker compose stop campanas-worker` → repetir el paso 2 → `start` | "Si el LLM no llega en 30 s, se avisa y las recomendaciones siguen funcionando." |
| 5 | Seguridad | `powershell -ExecutionPolicy Bypass -File .\scripts\verificar-aws.ps1` | "Sin clave, 401; con más de 1 MB, 413; con 40 peticiones seguidas, 429. Todo responde con `{"detail": ...}`." |
| 6 | `/docs` | Abrir `/docs` | "Documentación OpenAPI pública." |
| 7 | Dashboard | Abrir `/dashboard` | "Recomendaciones entregadas y qué porcentaje usó la lista de reserva." |
| 8 | CI/CD | GitHub → Actions del gateway | "Si un test falla, no se publica la imagen; quitamos el `|| echo` que nos marcaron en EP2." |
| 9 | Carga | Tabla de `docs/ep3-gateway-front.md` | p50, p95, p99, req/s y errores; explicar los 429. |

**Preguntas probables**
- *¿Dónde está la clave?* En el `.env` del servidor. El gateway la lee al arrancar y no arranca si falta o es débil. No está en el repo ni en la imagen.
- *¿Por qué `X-Real-IP`?* Detrás de Caddy, todas las peticiones vendrían de la misma IP y compartirían el límite.
- *¿Qué pasa si se cae una réplica del dominio?* Nginx reintenta en la otra (`proxy_next_upstream`) y la deja fuera 10 s.
