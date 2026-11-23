# =====================================================================
# S5 - Azure Policy con efecto Deny asignada por Terraform al grupo de recursos
# =====================================================================

# Built-in "Network interfaces should not have public IPs" (efecto Deny).
# Garantiza a nivel de plataforma lo que el NSG/Terraform ya cumplen: ninguna NIC con IP pública,
# aunque alguien intente crearla a mano desde el portal o la CLI.
data "azurerm_policy_definition" "nic_no_public_ip" {
  name = "83a86a26-fd1f-447c-b59d-e51f44264114"
}

resource "azurerm_resource_group_policy_assignment" "deny_nic_public_ip" {
  name                 = "deny-nic-public-ip"
  display_name         = "CaribeShop - Denegar NICs con IP pública"
  description          = "S5: ninguna interfaz de red del RG puede tener IP pública (solo el Load Balancer expone la app)."
  resource_group_id    = azurerm_resource_group.main.id
  policy_definition_id = data.azurerm_policy_definition.nic_no_public_ip.id
  enforce              = true

  non_compliance_message {
    content = "CaribeShop: las NICs no pueden tener IP pública. Exponga servicios solo a través del Load Balancer."
  }
}

# Built-in "Allowed locations" (efecto Deny): los recursos solo pueden crearse en la región aprobada
# (residencia de datos / control de costos).
data "azurerm_policy_definition" "allowed_locations" {
  name = "e56962a6-4747-49cd-b67b-bf8b01975c4c"
}

resource "azurerm_resource_group_policy_assignment" "allowed_locations" {
  name                 = "allowed-locations"
  display_name         = "CaribeShop - Solo regiones aprobadas"
  description          = "S5: los recursos del RG solo pueden desplegarse en la región aprobada (y 'global')."
  resource_group_id    = azurerm_resource_group.main.id
  policy_definition_id = data.azurerm_policy_definition.allowed_locations.id
  enforce              = true

  parameters = jsonencode({
    listOfAllowedLocations = { value = [var.location, "global"] }
  })

  non_compliance_message {
    content = "CaribeShop: solo se permite desplegar en la región aprobada."
  }
}
