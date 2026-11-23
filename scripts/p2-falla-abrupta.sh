#!/usr/bin/env bash
# P2.2 - Falla abrupta: se ELIMINA una instancia durante carga moderada.
# Se mide: errores en la ventana y tiempo hasta recuperar la capacidad mínima (2 instancias sanas).
set -euo pipefail
source "$(dirname "$0")/_env.sh"
OUT="$EVID/p2-falla-abrupta"

LOAD_PROFILE=moderate USERS=40 DURATION=900 locust -f "$ROOT/loadtest/locustfile.py" --host "$APP_URL" \
  --headless --csv "$OUT" --csv-full-history --html "$OUT.html" > "$OUT-locust.log" 2>&1 &
LOCUST_PID=$!
python "$ROOT/scripts/monitor.py" "$APP_URL" "$OUT-monitor.csv" 0.5 > "$OUT-monitor.log" 2>&1 &
MON_PID=$!

sleep 120
VICTIM="$(az vmss list-instances -g "$RG" -n "$VMSS" --query "[0].instanceId" -o tsv)"
VICTIM_NAME="$(az vmss list-instances -g "$RG" -n "$VMSS" --query "[0].osProfile.computerName" -o tsv)"
T_FAIL="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
echo ">> $T_FAIL eliminando instancia $VICTIM ($VICTIM_NAME) sin drenar"
echo "$T_FAIL $VICTIM $VICTIM_NAME" > "$OUT-tiempos.txt"
az vmss delete-instances -g "$RG" -n "$VMSS" --instance-ids "$VICTIM" --no-wait

echo ">> Esperando recuperación de la capacidad mínima (autoscale min=2 crea una instancia nueva)"
while true; do
  healthy=$(python "$ROOT/scripts/monitor.py" --resumen "$OUT-monitor.csv" "${T_FAIL%Z}" 2>/dev/null \
    | awk '/->/ && $1 != "ventana:" {print $1}' | grep -vc "$VICTIM_NAME" || true)
  n=$(az vmss list-instances -g "$RG" -n "$VMSS" --query "length([?provisioningState=='Succeeded'])" -o tsv)
  echo "$(date -u +%H:%M:%S) instancias Succeeded=$n  hostnames sirviendo (sin la víctima)=$healthy" | tee -a "$OUT-instancias.txt"
  if [ "$n" -ge 2 ] && [ "$healthy" -ge 2 ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) capacidad mínima recuperada" | tee -a "$OUT-tiempos.txt"
    break
  fi
  sleep 15
done

sleep 60
kill "$MON_PID" 2>/dev/null || true
kill "$LOCUST_PID" 2>/dev/null || true
python "$ROOT/scripts/monitor.py" --resumen "$OUT-monitor.csv" "${T_FAIL%Z}" | tee "$OUT-resumen.txt"
echo "Tiempo de recuperación = segunda línea de $OUT-tiempos.txt - $T_FAIL"
