#!/usr/bin/env bash
# P3 - Pruebas negativas de seguridad + evidencias de S2, S4, S5, S6.
# Ejecutar P3.1 desde Azure Cloud Shell (red NO autorizada); el resto desde cualquier terminal con az.
set -uo pipefail   # sin -e: se ESPERAN errores
source "$(dirname "$0")/_env.sh"
set +e   # aquí los errores son el resultado esperado
OUT="$EVID/p3"
SUB_ID="$(az account show --query id -o tsv)"

echo "================ S2: ninguna instancia con IP pública ================"
az vmss list-instance-public-ips -g "$RG" -n "$VMSS" -o table | tee "$OUT-s2-ips-publicas.txt"
echo "(vacío = sin IPs públicas)"
az vmss nic list -g "$RG" --vmss-name "$VMSS" \
  --query "[].{nic:name, ip_privada:ipConfigurations[0].privateIPAddress, ip_publica:ipConfigurations[0].publicIPAddress}" -o table \
  | tee -a "$OUT-s2-ips-publicas.txt"
az network nsg rule list -g "$RG" --nsg-name "$(terraform -chdir="$ROOT/infra" output -raw nsg_name)" \
  --include-default -o table | tee "$OUT-s2-nsg.txt"
echo ">> SSH desde Internet (debe fallar por timeout):"
timeout 8 bash -c "echo > /dev/tcp/$(terraform -chdir="$ROOT/infra" output -raw lb_public_ip)/22" \
  && echo "ABIERTO (¡mal!)" || echo "22/tcp cerrado ✔" | tee -a "$OUT-s2-nsg.txt"

echo "================ S4: roles de la identidad del VMSS ================"
az role assignment list --assignee "$VMSS_PRINCIPAL_ID" --all \
  --query "[].{rol:roleDefinitionName, alcance:scope}" -o table | tee "$OUT-s4-roles.txt"

echo "================ S3: la app lee el secreto sin mostrarlo ================"
curl -s "$APP_URL/secret-check" | tee "$OUT-s3-secret-check.json"; echo

echo "================ P3.1: lectura desde red NO autorizada ================"
echo "Contraste - desde la IP del operador (autorizada) SÍ responde (solo se pide la fecha de expiración):"
az keyvault secret show --vault-name "$KV" -n "$SECRET" --query "attributes.expires" -o tsv 2>&1 \
  | tee "$OUT-p3-1-kv-desde-ip-operador.txt"
cat <<TXT | tee "$OUT-p3-1-instrucciones.txt"

>>> Ahora abra Azure Cloud Shell (https://shell.azure.com, red NO autorizada) con el MISMO usuario
    (que tiene el rol Key Vault Secrets Officer) y ejecute:

    az keyvault secret show --vault-name $KV -n $SECRET --query attributes.expires

    Resultado esperado: (Forbidden) Client address is not authorized and caller is not a trusted service.
    Code: ForbiddenByFirewall   -> capture la pantalla como evidencia de P3.1.
TXT

echo "================ P3.2: egress bloqueado desde una instancia ================"
ID0="$(az vmss list-instances -g "$RG" -n "$VMSS" --query "[0].instanceId" -o tsv)"
az vmss run-command invoke -g "$RG" -n "$VMSS" --instance-id "$ID0" --command-id RunShellScript \
  --scripts 'echo "--- Internet arbitrario (debe fallar):"; curl -sS -m 8 -o /dev/null -w "%{http_code}\n" https://example.com || echo BLOQUEADO;
             echo "--- Key Vault (permitido: cualquier código HTTP = alcanzable):"; curl -sS -m 8 -o /dev/null -w "%{http_code}\n" https://'"$KV"'.vault.azure.net/healthstatus || echo FALLO;
             echo "--- IMDS (link-local, permitido):"; curl -sS -m 3 -H Metadata:true "http://169.254.169.254/metadata/instance/compute/zone?api-version=2021-02-01&format=text"' \
  --query "value[0].message" -o tsv | tee "$OUT-p3-2-egress.txt"

echo "================ P3.3 / S5: violar la política Deny ================"
echo "-- a) NIC con IP pública:"
az network public-ip create -g "$RG" -n pip-prueba-politica --sku Standard -o none 2>&1 | tail -1
az network nic create -g "$RG" -n nic-prueba-politica \
  --vnet-name "vnet-$(echo "$RG" | sed -E 's/^rg-(.*)-prod$/\1/')" --subnet snet-app \
  --public-ip-address pip-prueba-politica 2>&1 | tee "$OUT-p3-3-policy-nic.txt"
echo "-- b) Recurso fuera de la región permitida:"
az network public-ip create -g "$RG" -n pip-fuera-region -l "${OTRA_REGION:-westus3}" --sku Standard 2>&1 \
  | tee "$OUT-p3-3-policy-location.txt"
echo "(esperado en ambos: RequestDisallowedByPolicy)"
az network public-ip delete -g "$RG" -n pip-prueba-politica 2>/dev/null

echo "================ S6: KQL - lecturas del secreto por la identidad del VMSS ================"
sleep 5
az monitor log-analytics query -w "$LAW_ID" --analytics-query "
AZKVAuditLogs
| where TimeGenerated > ago(24h)
| where OperationName == 'SecretGet'
| extend Identidad = tostring(Identity.claim.oid)
| project TimeGenerated, OperationName, ResultSignature, CallerIpAddress, Identidad,
          EsVMSS = Identidad == '$VMSS_PRINCIPAL_ID', Id = tostring(split(Id, '/')[4])
| order by TimeGenerated desc
| take 20" -o table | tee "$OUT-s6-kql-secretget.txt"

az monitor log-analytics query -w "$LAW_ID" --analytics-query "
AZKVAuditLogs
| where TimeGenerated > ago(24h)
| where ResultSignature == 'Forbidden'
| project TimeGenerated, OperationName, ResultSignature, ResultDescription, CallerIpAddress
| order by TimeGenerated desc
| take 20" -o table | tee "$OUT-s6-kql-denegados.txt"
echo "Nota: los logs tardan 5-15 min en llegar a Log Analytics; si está vacío, repita la consulta."
