#!/usr/bin/env bash
# P1.2 / P1.3 - Prueba escalonada de 28 min con autoscale activo + exportación de métricas
# alineadas en el tiempo (instancias observadas por el autoscale, CPU, sonda) y gráfico combinado.
# NO dejar sin supervisión: las VMs serie B consumen créditos de CPU.
set -euo pipefail
source "$(dirname "$0")/_env.sh"
AUTOSCALE_ID="$(az monitor autoscale show -g "$RG" -n "$AUTOSCALE" --query id -o tsv)"

START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ">> Inicio: $START"
LOAD_PROFILE=step locust -f "$ROOT/loadtest/locustfile.py" --host "$APP_URL" --headless \
  --csv "$EVID/p1-escalonada" --csv-full-history --html "$EVID/p1-escalonada.html" || true

echo ">> Esperando 12 min adicionales para capturar el scale-in completo (Ctrl+C para omitir)"
sleep 720 || true
END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ">> Fin: $END. Exportando métricas..."

az monitor metrics list --resource "$AUTOSCALE_ID" --metric ObservedCapacity \
  --start-time "$START" --end-time "$END" --interval PT1M --aggregation Maximum -o json \
  > "$EVID/p1-observed-capacity.json"
az monitor metrics list --resource "$VMSS_ID" --metric "Percentage CPU" \
  --start-time "$START" --end-time "$END" --interval PT1M --aggregation Average -o json \
  > "$EVID/p1-vmss-cpu.json"
az monitor metrics list --resource "$LB_ID" --metric DipAvailability \
  --start-time "$START" --end-time "$END" --interval PT1M --aggregation Average -o json \
  > "$EVID/p1-lb-dipavailability.json"

# Historial de ejecución del autoscale (E3)
az monitor activity-log list -g "$RG" --start-time "$START" --end-time "$END" \
  --query "[?category.value=='Autoscale'].{hora:eventTimestamp, operacion:operationName.localizedValue, estado:status.value, descripcion:description}" \
  -o table | tee "$EVID/p1-autoscale-historial.txt"

python "$ROOT/scripts/graficas.py" escalonada "$EVID/p1-escalonada_stats_history.csv" \
  "$EVID/p1-escalonada.png" "$EVID/p1-observed-capacity.json" "$EVID/p1-vmss-cpu.json"
echo "Evidencias en $EVID"
