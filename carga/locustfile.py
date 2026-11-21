"""Prueba de carga EP3: POST /api/predict contra el sistema en AWS.

- Solo apunta al modelo propio (/api/predict -> dominio -> IA). NO llama al LLM.
- La clave se lee de la variable API_KEY (nunca va escrita en el repo).
- Usuarios y categorías se toman del propio sistema al comenzar, para enviar entradas válidas.

Ejecutar (3 minutos, sin interfaz):
    locust -f carga/locustfile.py --host https://3-215-113-161.sslip.io \
           --headless -u 20 -r 5 -t 3m --csv carga/resultados/ep3 --html carga/resultados/ep3.html
"""
import os
import random

from locust import HttpUser, between, events, task

API_KEY = os.getenv("API_KEY", "")
CATEGORIAS_RESPALDO = ["Audio", "Notebooks", "Smartphones", "Monitores", "Gaming"]
USUARIOS: list[str] = []
CATEGORIAS: list[str] = []


@events.test_start.add_listener
def preparar(environment, **_):
    """Antes de empezar: valida la clave y carga usuarios/categorías reales."""
    if len(API_KEY) < 16:
        raise SystemExit("Falta API_KEY (mínimo 16 caracteres). En PowerShell: "
                         "$env:API_KEY = Get-Content $HOME\\.ssh\\nexo-api-key.txt")
    import httpx

    cabeceras = {"X-API-Key": API_KEY}
    base = environment.host.rstrip("/")
    with httpx.Client(timeout=20, headers=cabeceras) as cliente:
        r = cliente.get(f"{base}/api/dominio/usuarios")
        r.raise_for_status()
        USUARIOS.extend(str(u["usuario_id"]) for u in r.json() if isinstance(u, dict) and u.get("usuario_id"))
        try:
            c = cliente.get(f"{base}/api/dominio/categorias")
            CATEGORIAS.extend(str(x) for x in c.json() if x)
        except Exception:
            pass
    if not USUARIOS:
        raise SystemExit("El sistema no devolvió usuarios: revisa que la base de datos tenga datos.")
    CATEGORIAS[:] = CATEGORIAS or CATEGORIAS_RESPALDO
    print(f"Prueba lista: {len(USUARIOS)} usuarios y {len(CATEGORIAS)} categorías")


class Cliente(HttpUser):
    wait_time = between(0.5, 1.5)   # cada usuario virtual espera entre 0,5 y 1,5 s entre peticiones

    @task
    def predecir(self):
        cuerpo = {"usuario_id": random.choice(USUARIOS), "categoria": random.choice(CATEGORIAS)}
        with self.client.post("/api/predict", json=cuerpo, headers={"X-API-Key": API_KEY},
                              name="POST /api/predict", catch_response=True) as r:
            if r.status_code == 200:
                r.success()
            elif r.status_code == 429:
                r.failure("429 rate limit (subir RATE_LIMIT para medir capacidad)")
            else:
                r.failure(f"{r.status_code}: {r.text[:120]}")
