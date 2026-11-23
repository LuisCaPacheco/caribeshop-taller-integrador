#!/usr/bin/env bash
# Carga los outputs de Terraform como variables de entorno para los scripts de prueba.
# Uso: source scripts/_env.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Git Bash (Windows): rutas C:/... que entienden terraform/python/locust nativos
if command -v cygpath >/dev/null 2>&1; then
  ROOT="$(cygpath -m "$ROOT")"
  export MSYS_NO_PATHCONV=1   # evita que /subscriptions/... se convierta en ruta de Windows
fi
export ROOT
_tf() { terraform -chdir="$ROOT/infra" output -raw "$1"; }

export RG="$(_tf resource_group_name)"
export APP_URL="$(_tf app_url)"
export VMSS="$(_tf vmss_name)"
export VMSS_ID="$(_tf vmss_id)"
export VMSS_PRINCIPAL_ID="$(_tf vmss_principal_id)"
export AUTOSCALE="$(_tf autoscale_name)"
export KV="$(_tf key_vault_name)"
export SECRET="$(_tf key_vault_secret_name)"
export LAW_ID="$(_tf log_analytics_workspace_id)"
export LB_ID="$(_tf lb_id)"
export EVID="$ROOT/evidencias"
mkdir -p "$EVID"

echo "RG=$RG  VMSS=$VMSS  KV=$KV"
echo "APP_URL=$APP_URL"

# Si 'locust' no está en el PATH (p. ej. pip install --user en Windows), usar el módulo de Python
if ! command -v locust >/dev/null 2>&1; then
  locust() { python -m locust "$@"; }
  export -f locust
fi
