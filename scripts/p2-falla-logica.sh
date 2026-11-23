#!/usr/bin/env bash
# P2.1 - Falla lógica: /health de UNA instancia responde 503 durante carga moderada.
# Se mide: tiempo hasta que deja de recibir tráfico y peticiones fallidas (% de error en la ventana).
# La reparación automática (E4) la reemplaza al vencer el grace period (10 min).
set -euo pipefail
source "$(dirname "$0")/_env.sh"
OUT="$EVID/p2-falla-logica"

echo ">> 1) Carga moderada (40 usuarios, 15 min) en segundo plano"
LOAD_PROFILE=moderate USERS=40 DURATION=900 locust -f "$ROOT/loadtest/locustfile.py" --host "$APP_URL" \
  --headless --csv "$OUT" --csv-full-history --html "$OUT.html" > "$OUT-locust.log" 2>&1 &
LOCUST_PID=$!

echo ">> 2) Sonda externa cada 0,5 s en segundo plano"
python "$ROOT/scripts/monitor.py" "$APP_URL" "$OUT-monitor.csv" 0.5 1000 > "$OUT-monitor.log" 2>&1 &
MON_PID=$!

sleep 120   # 2 min de línea base
T_FAIL="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
echo ">> 3) Inyectando falla lógica ($T_FAIL): /health -> 503 durante 15 min en la instancia que atienda"
curl -s "$APP_URL/simulate-failure?seconds=900" | tee "$OUT-inyeccion.json"; echo
SICK="$(python -c 'import json,sys;print(json.load(open(sys.argv[1]))["instancia"])' "$OUT-inyeccion.json")"
echo "   instancia enferma: $SICK"
echo "$T_FAIL $SICK" > "$OUT-tiempos.txt"

echo ">> 4) Observando 13 min (reparación automática: grace 10 min + reemplazo)"
for i in $(seq 1 26); do
  az vmss list-instances -g "$RG" -n "$VMSS" \
    --query "[].{id:instanceId, nombre:osProfile.computerName, zona:zones[0], estado:provisioningState}" -o tsv \
    | sed "s/^/$(date -u +%H:%M:%S) /" | tee -a "$OUT-instancias.txt"
  az vmss get-instance-view -g "$RG" -n "$VMSS" --query "orchestrationServices" -o tsv >> "$OUT-instancias.txt" 2>/dev/null || true
  sleep 30
done

kill "$MON_PID" 2>/dev/null || true
wait "$LOCUST_PID" 2>/dev/null || true
echo ">> 5) Resumen desde la inyección"
python "$ROOT/scripts/monitor.py" --resumen "$OUT-monitor.csv" "${T_FAIL%Z}" | tee "$OUT-resumen.txt"
cat <<TXT

Interprete:
  * Tiempo hasta sacar de rotación = última respuesta de $SICK - $T_FAIL (esperado ~10 s: 2 sondas x 5 s).
  * % error de la ventana = resumen anterior; en Locust: $OUT_stats.csv (Failures).
  * Reemplazo (E4): ver $OUT-instancias.txt (aparece un instanceId nuevo) y el Activity Log:
      az monitor activity-log list -g $RG --offset 1h --query "[?contains(operationName.value,'virtualMachineScaleSets')].{t:eventTimestamp,op:operationName.localizedValue,by:caller}" -o table
TXT
