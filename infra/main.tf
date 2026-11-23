data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  name   = var.prefix
  suffix = random_string.suffix.result
  tags   = var.tags

  # Nombres globalmente únicos
  kv_name = "kv-${var.prefix}-${local.suffix}"
  st_name = substr("st${var.prefix}${local.suffix}", 0, 24)

  db_secret_name = "db-password"
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.name}-prod"
  location = var.location
  tags     = local.tags
}
