# =====================================================================
# S2 - Red: VNet + snet-app + NSG de mínimo privilegio (entrada y salida)
# E2 - IP pública Standard zonal-redundante + Load Balancer Standard + sonda /health
# =====================================================================

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.snet_app_cidr]

  # Necesario para incluir la subred en el firewall del Key Vault y del Storage (S3)
  service_endpoints = ["Microsoft.KeyVault", "Microsoft.Storage"]

  # Sin "default outbound access": las instancias NO tienen ruta implícita a Internet.
  # Junto con el LB sin SNAT de salida y el NSG, la salida queda restringida a lo permitido.
  default_outbound_access_enabled = false
}

resource "azurerm_network_security_group" "app" {
  #checkov:skip=CKV_AZURE_160:HTTP 80 desde Internet es el servicio público de la tienda detrás del LB (único puerto abierto). Riesgo aceptado: tráfico sin TLS; mitigación futura: Application Gateway/Front Door con WAF y HTTPS (443) y redirección 80->443.
  name                = "nsg-snet-app"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  # ---------------- ENTRADA ----------------
  security_rule {
    name                       = "Allow-HTTP-Internet"
    description                = "Única entrada pública: HTTP 80 hacia la app detrás del LB"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = var.snet_app_cidr
  }

  security_rule {
    name                       = "Allow-LB-HealthProbe"
    description                = "Sondas del Load Balancer (168.63.129.16)"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = var.snet_app_cidr
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    description                = "Todo lo demás (incl. 22/3389 y tráfico lateral de la VNet) denegado"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # ---------------- SALIDA (egress filtrado) ----------------
  security_rule {
    name                       = "Allow-KeyVault-Out"
    description                = "La app lee el secreto en Key Vault (vía service endpoint)"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.snet_app_cidr
    destination_address_prefix = "AzureKeyVault"
  }

  security_rule {
    name                       = "Deny-Internet-Out"
    description                = "Sin salida a sitios arbitrarios (exfiltración / C2). IMDS y DNS de Azure no pasan por el NSG."
    priority                   = 4096
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }
}

# CKV2_AZURE_31 - la subred siempre tiene NSG
resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

# ---------------------------------------------------------------------
# E2 - Balanceador
# ---------------------------------------------------------------------
resource "azurerm_public_ip" "lb" {
  name                = "pip-lb-${local.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"] # zonal-redundante
  domain_name_label   = "${local.name}-${local.suffix}"
  tags                = local.tags
}

resource "azurerm_lb" "main" {
  name                = "lb-${local.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard"
  tags                = local.tags

  frontend_ip_configuration {
    name                 = "fe-public"
    public_ip_address_id = azurerm_public_ip.lb.id
  }
}

resource "azurerm_lb_backend_address_pool" "app" {
  name            = "be-vmss-app"
  loadbalancer_id = azurerm_lb.main.id
}

# Sonda HTTP sobre un endpoint dedicado: /health devuelve 200 solo si la app está sana
resource "azurerm_lb_probe" "health" {
  name                = "probe-http-health"
  loadbalancer_id     = azurerm_lb.main.id
  protocol            = "Http"
  port                = 80
  request_path        = "/health"
  interval_in_seconds = 5
  number_of_probes    = 2 # ~10 s para sacar una instancia de rotación
  probe_threshold     = 2
}

resource "azurerm_lb_rule" "http" {
  name                           = "rule-http-80"
  loadbalancer_id                = azurerm_lb.main.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "fe-public"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.app.id]
  probe_id                       = azurerm_lb_probe.health.id
  idle_timeout_in_minutes        = 4
  tcp_reset_enabled              = true
  load_distribution              = "Default"

  # Sin SNAT de salida: el LB solo sirve tráfico entrante (egress controlado, S2)
  disable_outbound_snat = true
}
