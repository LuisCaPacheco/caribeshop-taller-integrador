#!/usr/bin/env bash
# P1.1 - Capacidad de UNA instancia: autoscale min = max = 1 temporalmente y rampa lenta de usuarios
# hasta que el p95 supere 1 s. Registrar el RPS máximo sostenible (el último escalón con p95 <= 1 s).
set -euo pipefail
source "$(dirname "$0")/_env.sh"

echo ">> Fijando autoscale en 1/1/1 (temporal, SOLO para medir capacidad)"
az monitor autoscale update -g "$RG" -n "$AUTOSCALE" --min-count 1 --max-count 1 --count 1 -o none
echo ">> Esperando a que el VMSS quede en 1 instancia..."
for _ in $(seq 1 60); do
  n=$(az vmss list-instances -g "$RG" -n "$VMSS" --query "length(@)" -o tsv)
  echo "   instancias: $n"; [ "$n" = "1" ] && break; sleep 20
done

echo ">> Rampa de capacidad: +10 usuarios/min; se detiene sola tras 2 min con p95 > 1 s"
LOAD_PROFILE=capacity STEP_USERS="${STEP_USERS:-10}" locust -f "$ROOT/loadtest/locustfile.py" --host "$APP_URL" --headless \
  --csv "$EVID/p1-capacidad" --csv-full-history --html "$EVID/p1-capacidad.html" || true

echo ">> Restaurando el autoscale a los valores de Terraform (min 2)"
az monitor autoscale update -g "$RG" -n "$AUTOSCALE" --min-count 2 --max-count 3 --count 2 -o none  # = valores de Terraform (sin drift)

python "$ROOT/scripts/graficas.py" capacidad "$EVID/p1-capacidad_stats_history.csv" "$EVID/p1-capacidad.png" || true
echo "Listo. Revise $EVID/p1-capacidad_stats_history.csv: RPS máximo con p95 <= 1000 ms."
