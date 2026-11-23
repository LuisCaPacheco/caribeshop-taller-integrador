#!/usr/bin/env bash
# Acceso de soporte a las instancias SIN SSH (corrección del PR #1).
# az vmss run-command ejecuta el script a través del agente de la VM (canal de Azure, no la red):
#   * autenticado con Entra ID y autorizado por RBAC (Virtual Machine Contributor o superior)
#   * auditado en el Activity Log (operación virtualMachineScaleSets/virtualMachines/runCommand/action)
#   * no requiere IP pública ni el puerto 22 abierto (S2 se mantiene)
# Uso: ./scripts/soporte-run-command.sh [instance_id|todas] ["comando"]
set -euo pipefail
source "$(dirname "$0")/_env.sh"
TARGET="${1:-todas}"
CMD="${2:-hostname; systemctl is-active caribeshop; curl -s localhost/health; echo; journalctl -u caribeshop -n 20 --no-pager}"

if [ "$TARGET" = "todas" ]; then
  IDS="$(az vmss list-instances -g "$RG" -n "$VMSS" --query "[].instanceId" -o tsv)"
else
  IDS="$TARGET"
fi
for ID in $IDS; do
  echo "===== instancia $ID ====="
  az vmss run-command invoke -g "$RG" -n "$VMSS" --instance-id "$ID" \
    --command-id RunShellScript --scripts "$CMD" --query "value[0].message" -o tsv
done
