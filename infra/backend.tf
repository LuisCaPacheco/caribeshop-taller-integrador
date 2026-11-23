# S1 - Estado remoto en Azure Storage (nunca en Git).
# Configuración parcial: los valores reales se pasan en `terraform init -backend-config=backend.hcl`
# (backend.hcl está en .gitignore; ver backend.hcl.example y infra/bootstrap/bootstrap-backend.sh).
# use_azuread_auth = true -> el estado se lee/escribe con Entra ID, sin llaves de cuenta.
terraform {
  backend "azurerm" {
    use_azuread_auth = true
  }
}
