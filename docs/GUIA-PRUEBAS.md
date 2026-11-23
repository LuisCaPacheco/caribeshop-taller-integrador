# Fase 4 — Guía de ejecución de pruebas (P1, P2, P3)

> Ejecutar desde la raíz del repo en Git Bash / WSL / Cloud Shell, con `az login` hecho y `terraform apply` completado.
> Instalar herramientas de carga: `pip install -r loadtest/requirements.txt`.
> **No dejar pruebas corriendo sin supervisión** (créditos de CPU de la serie B y presupuesto).

```bash
source scripts/_env.sh        # exporta RG, APP_URL, VMSS, KV, LAW_ID, ... desde terraform output
```

## Comprobación inicial (antes de medir)

```bash
# E1 - instancias y su zona
az vmss list-instances -g $RG -n $VMSS \
  --query "[].{id:instanceId, nombre:osProfile.computerName, zona:zones[0], estado:provisioningState}" -o table

# E2 - la sonda ve todas las instancias sanas (100 = todas)
az monitor metrics list --resource $LB_ID --metric DipAvailability --interval PT1M --aggregation Average \
  --offset 10m -o table

# D3 - la app arrancó sola; se reparte entre instancias/zonas
for i in $(seq 1 10); do curl -s "$APP_URL/?json" | python -c "import json,sys;d=json.load(sys.stdin);print(d['instancia'],d['zona'])"; done

# S3 - huella del secreto (nunca el valor)
curl -s $APP_URL/secret-check | python -m json.tool
```

---

## P1 — Carga y escalamiento

### P1.1 Capacidad de una instancia (p95 > 1 s)

Automatizado: `./scripts/p1-capacidad.sh`. Manual paso a paso:

```bash
# 1) Autoscale temporal min = max = 1
az monitor autoscale update -g $RG -n $AUTOSCALE --min-count 1 --max-count 1 --count 1
az vmss list-instances -g $RG -n $VMSS -o table          # esperar a que quede 1

# 2) Rampa lenta: +5 usuarios/min. La consola imprime [capacity] rps / p95 cada 15 s.
LOAD_PROFILE=capacity locust -f loadtest/locustfile.py --host $APP_URL --headless \
  --csv evidencias/p1-capacidad --csv-full-history --html evidencias/p1-capacidad.html
#    Ctrl+C 1-2 min después del primer aviso "p95 > 1 s".

# 3) Tabla usuarios -> RPS -> p95 y gráfico
python scripts/graficas.py capacidad evidencias/p1-capacidad_stats_history.csv evidencias/p1-capacidad.png

# 4) Restaurar autoscale (vuelve a min 2 / max 3)
terraform -chdir=infra apply -target=azurerm_monitor_autoscale_setting.app
```

**Registrar:** `RPS_max_1inst` = RPS medio del último escalón con p95 ≤ 1000 ms (lo imprime `graficas.py`). También anotar el RPS del último escalón con p95 ≤ 500 ms (lo usa la pregunta 1).

> Alternativa con interfaz web: `locust -f loadtest/locustfile.py --host $APP_URL` con `LOAD_PROFILE=none`, abrir http://localhost:8089 y subir usuarios a mano.

### P1.2 / P1.3 Prueba escalonada ≥ 25 min con autoscale

Automatizado: `./scripts/p1-escalonada.sh` (28 min de carga + 12 min de observación del scale-in).

Perfil `step` del `locustfile.py`:

| Minutos | Usuarios | Intención |
|---|---|---|
| 0-2 | 30 | calentamiento |
| 2-5 | 120 | subida 1 |
| 5-8 | 240 | subida 2: CPU > 70 % → **scale-out** |
| 8-18 | 300 | carga sostenida |
| 18-23 | 100 | bajada |
| 23-28 | 10 | valle: CPU < 30 % 10 min → **scale-in** |

> Ajustar los usuarios del perfil al resultado de P1.1: el pico debe superar la capacidad de 2 instancias (≈ 1,3 × 2 × capacidad de una) para forzar el scale-out.

```bash
START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LOAD_PROFILE=step locust -f loadtest/locustfile.py --host $APP_URL --headless \
  --csv evidencias/p1-escalonada --csv-full-history --html evidencias/p1-escalonada.html
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Instancias en el tiempo (métrica del autoscale) y CPU
AUTOSCALE_ID=$(az monitor autoscale show -g $RG -n $AUTOSCALE --query id -o tsv)
az monitor metrics list --resource $AUTOSCALE_ID --metric ObservedCapacity --start-time $START --end-time $END \
  --interval PT1M --aggregation Maximum -o json > evidencias/p1-observed-capacity.json
az monitor metrics list --resource $VMSS_ID --metric "Percentage CPU" --start-time $START --end-time $END \
  --interval PT1M --aggregation Average -o json > evidencias/p1-vmss-cpu.json

# Historial de ejecución del autoscale (E3)
az monitor activity-log list -g $RG --start-time $START --end-time $END \
  --query "[?category.value=='Autoscale'].{hora:eventTimestamp, op:operationName.localizedValue, estado:status.value, desc:description}" -o table

# Gráfico alineado: usuarios / RPS / p95 / instancias + CPU (P1.3)
python scripts/graficas.py escalonada evidencias/p1-escalonada_stats_history.csv evidencias/p1-escalonada.png \
  evidencias/p1-observed-capacity.json evidencias/p1-vmss-cpu.json
```

**Medir para el informe:** tiempo de reacción del scale-out = (hora en que la instancia nueva responde en el CSV / aparece en ObservedCapacity) − (hora en que CPU cruzó 70 %). Se descompone en: ventana de la métrica (5 min) + evaluación del autoscale (~1 min) + aprovisionamiento de VM + cloud-init + 2 sondas sanas.

Portal (captura): *Monitor → Autoscale → autoscale-caribeshop-app → Run history*.

---

## P2 — Pruebas de falla

Ambas con carga moderada (`LOAD_PROFILE=moderate`, 40 usuarios) y la sonda externa `scripts/monitor.py` (una petición cada 0,5 s, registra código HTTP e instancia que respondió).

### P2.1 Falla lógica (`/health` → 503)

Automatizado: `./scripts/p2-falla-logica.sh`. Manual:

```bash
# Terminal 1: carga moderada
LOAD_PROFILE=moderate USERS=40 DURATION=900 locust -f loadtest/locustfile.py --host $APP_URL --headless \
  --csv evidencias/p2-falla-logica --csv-full-history --html evidencias/p2-falla-logica.html
# Terminal 2: sonda externa
python scripts/monitor.py $APP_URL evidencias/p2-falla-logica-monitor.csv 0.5
# Terminal 3: tras 2 min de línea base, inyectar la falla (solo funciona desde operator_ip)
date -u +%FT%T.%3NZ; curl -s "$APP_URL/simulate-failure?seconds=900"
#   -> {"instancia": "vmss-caribeshop-app000001", "health": "503", ...}
```

Qué medir:
1. **Tiempo hasta sacarla de rotación**: última fila del monitor con esa instancia − hora de la inyección. Teórico: `interval 5 s × probe_threshold 2` ≈ 10 s (+ conexiones ya abiertas).
2. **Peticiones fallidas**: idealmente 0 (la instancia sigue respondiendo `/` mientras el LB la retira). `python scripts/monitor.py --resumen <csv> <inicio> <fin>` da el **% de error de la ventana**; Locust da `Failures` en `*_stats.csv`.
3. **Reparación automática (E4)**: tras el grace period (10 min) Azure reemplaza la instancia. Evidencia:
   ```bash
   az vmss list-instances -g $RG -n $VMSS -o table      # aparece un instanceId nuevo
   az monitor activity-log list -g $RG --offset 1h \
     --query "[?contains(operationName.value,'virtualMachineScaleSets')].{t:eventTimestamp,op:operationName.localizedValue,caller:caller}" -o table
   az vmss get-instance-view -g $RG -n $VMSS --query "orchestrationServices"   # AutomaticRepairs: Running
   ```
4. Métrica **Health Probe Status** (DipAvailability) baja de 100 % y la **alerta E5** envía correo (captura del correo).

### P2.2 Falla abrupta (eliminar una instancia)

Automatizado: `./scripts/p2-falla-abrupta.sh`. Manual:

```bash
# Con carga y monitor corriendo como en P2.1:
az vmss list-instances -g $RG -n $VMSS --query "[].{id:instanceId,nombre:osProfile.computerName,zona:zones[0]}" -o table
date -u +%FT%T.%3NZ; az vmss delete-instances -g $RG -n $VMSS --instance-ids <ID> --no-wait
watch -n 15 "az vmss list-instances -g $RG -n $VMSS -o table"
```

Qué medir: errores (conexiones reseteadas en vuelo hasta que la sonda la marca caída, ~10 s), **% de error en la ventana** (monitor + Locust) y **tiempo hasta recuperar la capacidad mínima** = hora en que la instancia nueva aparece respondiendo en el monitor − hora del borrado (autoscale detecta capacidad < min=2 y crea una nueva; esperado ~4-7 min).

| Métrica | P2.1 lógica | P2.2 abrupta |
|---|---|---|
| Inicio de la falla (UTC) | | |
| Último tráfico a la instancia afectada | | |
| Tiempo hasta sacar de rotación (s) | | |
| Peticiones totales en la ventana | | |
| Peticiones fallidas | | |
| % de error en la ventana | | |
| Tiempo hasta recuperar capacidad mínima | (reparación) | |

---

## P3 — Pruebas de seguridad

Automatizado (salvo P3.1, que requiere Cloud Shell): `./scripts/p3-seguridad.sh`.

### P3.1 Secreto ilegible desde red no autorizada

```bash
# Desde la IP del operador (autorizada): funciona
az keyvault secret show --vault-name $KV -n db-password --query attributes.expires
# Desde Azure Cloud Shell (mismo usuario, que SÍ tiene el rol Secrets Officer):
az keyvault secret show --vault-name <kv-name> -n db-password --query attributes.expires
# -> (Forbidden) Client address is not authorized and caller is not a trusted service. Code: ForbiddenByFirewall
```

KQL del intento rechazado:

```kusto
AZKVAuditLogs
| where TimeGenerated > ago(2h)
| where ResultSignature == "Forbidden"
| project TimeGenerated, OperationName, ResultSignature, ResultDescription, CallerIpAddress
```

### P3.2 Egress bloqueado

```bash
ID0=$(az vmss list-instances -g $RG -n $VMSS --query "[0].instanceId" -o tsv)
az vmss run-command invoke -g $RG -n $VMSS --instance-id $ID0 --command-id RunShellScript \
  --scripts 'curl -sS -m 8 https://example.com -o /dev/null -w "%{http_code}\n" || echo BLOQUEADO; \
             curl -sS -m 8 https://'$KV'.vault.azure.net/healthstatus -o /dev/null -w "%{http_code}\n"' \
  --query "value[0].message" -o tsv
# esperado: Internet -> timeout / BLOQUEADO ; Key Vault -> cualquier código HTTP (200/401/403) = alcanzable
```

Tres capas lo garantizan: subred sin *default outbound access*, LB con `disable_outbound_snat = true`, y regla NSG `Deny-Internet-Out`. Evidencia adicional: `az network nsg rule list -g $RG --nsg-name nsg-snet-app -o table`.

### P3.3 Violar la política Deny (S5)

```bash
# a) NIC con IP pública
az network public-ip create -g $RG -n pip-prueba --sku Standard
az network nic create -g $RG -n nic-prueba --vnet-name vnet-caribeshop --subnet snet-app --public-ip-address pip-prueba
# -> (RequestDisallowedByPolicy) Resource 'nic-prueba' was disallowed by policy ... "deny-nic-public-ip"
az network public-ip delete -g $RG -n pip-prueba

# b) Región no permitida
az network public-ip create -g $RG -n pip-fuera -l westus3 --sku Standard   # región permitida por la suscripción, NO por la política del RG
# -> (RequestDisallowedByPolicy) ... "allowed-locations"
```

La alerta de Activity Log `alert-caribeshop-policy-deny` envía correo en cada denegación.

---

## Evidencias de S4 y S6 (KQL)

```bash
az role assignment list --assignee $VMSS_PRINCIPAL_ID --all -o table
# Esperado: UNA fila -> Key Vault Secrets User, scope .../vaults/<kv>/secrets/db-password
```

```kusto
// S6 - Lecturas del secreto por la identidad administrada del VMSS
AZKVAuditLogs
| where TimeGenerated > ago(24h)
| where OperationName == "SecretGet"
| extend Identidad = tostring(Identity.claim.oid), Secreto = tostring(split(Id, "/")[4])
| project TimeGenerated, OperationName, ResultSignature, CallerIpAddress, Identidad, Secreto
| order by TimeGenerated desc
```

Reemplazar/filtrar `Identidad == "<vmss_principal_id>"`. `CallerIpAddress` muestra la IP privada de snet-app (gracias al service endpoint). Ejecutar con:

```bash
az monitor log-analytics query -w $LAW_ID --analytics-query "<consulta>" -o table
```

```kusto
// Resumen de accesos por identidad y resultado
AZKVAuditLogs
| where TimeGenerated > ago(24h)
| summarize Lecturas = count() by OperationName, ResultSignature, Identidad = tostring(Identity.claim.oid), CallerIpAddress
```

```kusto
// E2/P2 - Disponibilidad de la sonda (métricas del LB enviadas por diagnostic settings)
AzureMetrics
| where ResourceProvider == "MICROSOFT.NETWORK" and MetricName == "DipAvailability"
| summarize Disponibilidad = avg(Average) by bin(TimeGenerated, 1m)
| render timechart
```

---

## Cierre

```bash
terraform -chdir=infra destroy
az group exists -n rg-caribeshop-prod        # false
```
