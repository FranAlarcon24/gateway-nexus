"""Resume los resultados de Locust en una tabla para el informe: p50, p95, p99, req/s y errores.
Uso: python carga/resumen.py carga/resultados/ep3_stats.csv
"""
import csv
import sys

ruta = sys.argv[1] if len(sys.argv) > 1 else "carga/resultados/ep3_stats.csv"
with open(ruta, newline="", encoding="utf-8") as f:
    fila = next(r for r in csv.DictReader(f) if r["Name"] == "POST /api/predict")

total = int(fila["Request Count"])
fallos = int(fila["Failure Count"])
print("| Métrica | Valor |")
print("|---|---|")
print(f"| Peticiones totales | {total} |")
print(f"| Req/s promedio | {float(fila['Requests/s']):.2f} |")
print(f"| p50 (mediana) | {fila['50%']} ms |")
print(f"| p95 | {fila['95%']} ms |")
print(f"| p99 | {fila['99%']} ms |")
print(f"| Errores | {fallos} ({(fallos / total if total else 0):.2%}) |")
