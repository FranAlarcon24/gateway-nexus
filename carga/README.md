# Prueba de carga (Locust)

`POST /api/predict` contra AWS durante 3 minutos. Solo usa el modelo propio (dominio → IA); **no llama al LLM**.

## Ejecutar (PowerShell)

```powershell
pip install -r carga/requirements.txt
$env:API_KEY = Get-Content $HOME\.ssh\nexo-api-key.txt     # la clave no va en el repo
mkdir carga\resultados -Force
locust -f carga/locustfile.py --host https://3-215-113-161.sslip.io `
       --headless -u 20 -r 5 -t 3m --csv carga/resultados/ep3 --html carga/resultados/ep3.html
python carga/resumen.py carga/resultados/ep3_stats.csv
```

- `-u 20`: 20 usuarios virtuales; `-r 5`: se suman 5 por segundo; `-t 3m`: dura 3 minutos.
- Resultado: tabla con p50, p95, p99, req/s y errores, más el informe `ep3.html` con gráficos.

## Rate limiting

El gateway limita a `RATE_LIMIT` peticiones por IP (10r/s por defecto) y Locust corre desde una sola IP.
Con 20 usuarios (~20 req/s) parte de las peticiones recibirá `429`: eso **demuestra que el límite funciona**.
Para medir la capacidad real del sistema, subir temporalmente `RATE_LIMIT=200r/s` en el `.env` del servidor,
reiniciar el gateway y volver a correr la prueba; después dejarlo de nuevo en `10r/s`.
