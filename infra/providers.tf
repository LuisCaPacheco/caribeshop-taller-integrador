terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# S1 - Sin credenciales en código: el proveedor usa la sesión de `az login`
# (o variables ARM_* / OIDC en CI). subscription_id viene de ARM_SUBSCRIPTION_ID o de la variable.
provider "azurerm" {
  subscription_id = var.subscription_id

  # La cuenta de almacenamiento tiene las llaves compartidas deshabilitadas:
  # el plano de datos se opera con Entra ID.
  storage_use_azuread = true

  features {
    key_vault {
      # purge_protection_enabled = true impide purgar; al destruir solo queda en soft-delete.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
