#!/usr/bin/env bash
# Verificaciones ANTES de desplegar: región con zonas, cuota de vCPU, tamaño disponible, IP del operador.
# Uso: ./scripts/00-preflight.sh [region] [vm_size]
set -euo pipefail
LOCATION="${1:-centralus}"
SIZE="${2:-Standard_B2ps_v2}"

echo "== Cuenta activa"
az account show --query "{suscripcion:name, id:id, usuario:user.name}" -o table

echo "== Cuota de vCPU en $LOCATION (familia B y total regional)"
az vm list-usage -l "$LOCATION" -o table \
  | grep -Ei "Total Regional vCPUs|BS Family|BSv2 Family|BpsV2 Family|Name" || true

echo "== Zonas donde $SIZE está disponible en $LOCATION"
az vm list-skus -l "$LOCATION" --size "$SIZE" --resource-type virtualMachines \
  --query "[].{sku:name, zonas:join(',', locationInfo[0].zones), restricciones:length(restrictions)}" -o table

echo "== Su IP pública (use este valor como operator_ip)"
curl -s https://api.ipify.org; echo

cat <<'TXT'

Revise:
  * max vCPU necesarios = autoscale_max x vCPU del tamaño (B2ps_v2 = 2). Con 6 vCPU de cuota -> autoscale_max = 3.
  * El tamaño debe estar disponible en al menos 2 zonas (E1).
  * Si su suscripción tiene política de regiones permitidas, use una de esas (y que tenga zonas).
TXT
