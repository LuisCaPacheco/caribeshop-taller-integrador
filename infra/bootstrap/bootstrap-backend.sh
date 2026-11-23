#!/usr/bin/env bash
# =====================================================================
# S1 - Crea (una sola vez) la cuenta de almacenamiento del estado remoto.
# Es el único recurso fuera del Terraform principal (problema huevo-gallina).
# Endurecida: sin llaves compartidas, TLS 1.2, sin acceso anónimo,
# versionado + soft delete (recuperar un estado corrupto) y RBAC.
# Uso:  ./bootstrap-backend.sh [region]
# =====================================================================
set -euo pipefail

LOCATION="${1:-centralus}"
RG="rg-caribeshop-tfstate"
SUFFIX="$(tr -dc 'a-z0-9' </dev/urandom | head -c 6 || true)"
SA="stcstfstate${SUFFIX}"
CONTAINER="tfstate"

ME_OID="$(az ad signed-in-user show --query id -o tsv)"
SUB_ID="$(az account show --query id -o tsv)"

echo ">> Registrando proveedores de recursos necesarios"
for ns in Microsoft.Storage Microsoft.Network Microsoft.Compute Microsoft.KeyVault \
          Microsoft.Insights Microsoft.OperationalInsights Microsoft.PolicyInsights; do
  az provider register --namespace "$ns" --output none
done

echo ">> Grupo de recursos del estado: $RG ($LOCATION)"
az group create -n "$RG" -l "$LOCATION" --output none

echo ">> Cuenta de almacenamiento: $SA"
az storage account create -n "$SA" -g "$RG" -l "$LOCATION" \
  --sku Standard_ZRS --kind StorageV2 \
  --min-tls-version TLS1_2 --https-only true \
  --allow-blob-public-access false \
  --allow-shared-key-access false \
  --output none

az storage account blob-service-properties update -n "$SA" -g "$RG" \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 30 \
  --enable-container-delete-retention true --container-delete-retention-days 30 \
  --output none

echo ">> Rol 'Storage Blob Data Owner' para el operador (acceso al estado con Entra ID)"
az role assignment create --assignee-object-id "$ME_OID" --assignee-principal-type User \
  --role "Storage Blob Data Owner" \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$SA" \
  --output none

echo ">> Esperando propagación de RBAC (60 s)..."
sleep 60

az storage container create -n "$CONTAINER" --account-name "$SA" --auth-mode login --output none

cat > "$(dirname "$0")/../backend.hcl" <<EOF
resource_group_name  = "$RG"
storage_account_name = "$SA"
container_name       = "$CONTAINER"
key                  = "caribeshop/prod.tfstate"
EOF

echo
echo "Listo. Se escribió infra/backend.hcl (ignorado por Git). Siguiente paso:"
echo "  cd infra && terraform init -backend-config=backend.hcl"
