# =====================================================================
# E1 - VMSS multi-zona (min 2)   E3 - Autoscale con histéresis
# E4 - Reparación automática      D3 - cloud-init sin pasos manuales
# S2 - Sin IP pública, SSH no expuesto   S3/S4 - Identidad administrada
# =====================================================================

# Llave SSH exigida por Azure para Linux; la privada no se exporta (nadie entra por SSH:
# no hay IP pública ni puerto 22 abierto). Acceso de emergencia: az vmss run-command / consola serie.
resource "tls_private_key" "admin" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

locals {
  cloud_init = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    app_py      = file("${path.module}/../app/app.py")
    kv_name     = azurerm_key_vault.main.name
    secret_name = local.db_secret_name
    operator_ip = var.operator_ip
  })
}

resource "azurerm_linux_virtual_machine_scale_set" "app" {
  #checkov:skip=CKV_AZURE_97:Encryption at host requiere registrar la feature EncryptionAtHost en la suscripción (no siempre disponible en suscripciones de estudiante). Los discos ya se cifran en reposo con SSE + PMK; no hay datos persistentes en las instancias (stateless).
  name                = "vmss-${local.name}-app"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = var.vm_size
  instances           = var.autoscale_default
  zones               = var.zones
  zone_balance        = false # permite 3 instancias en 2 zonas sin bloquear el scale-out

  admin_username                  = var.admin_username
  disable_password_authentication = true
  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.admin.public_key_openssh
  }

  custom_data = base64encode(local.cloud_init)

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = var.image_sku
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 30
  }

  # S3/S4 - Identidad administrada del VMSS (lee el secreto vía IMDS)
  identity {
    type = "SystemAssigned"
  }

  network_interface {
    name                      = "nic-app"
    primary                   = true
    network_security_group_id = azurerm_network_security_group.app.id

    ip_configuration {
      name                                   = "ipcfg-app"
      primary                                = true
      subnet_id                              = azurerm_subnet.app.id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.app.id]
      # S2: sin bloque public_ip_address -> ninguna instancia tiene IP pública
    }
  }

  # E4 - La sonda del LB define la salud; Rolling es obligatorio para usar health_probe_id
  health_probe_id = azurerm_lb_probe.health.id
  upgrade_mode    = "Rolling"

  rolling_upgrade_policy {
    max_batch_instance_percent              = 50
    max_unhealthy_instance_percent          = 50
    max_unhealthy_upgraded_instance_percent = 50
    pause_time_between_batches              = "PT30S"
  }

  automatic_instance_repair {
    enabled      = true
    grace_period = "PT10M" # mínimo permitido: deja terminar cloud-init antes de juzgar la salud
    action       = "Replace"
  }

  boot_diagnostics {
    storage_account_uri = null # almacenamiento administrado (sin llaves)
  }

  provision_vm_agent  = true
  overprovision       = false # evita VMs extra transitorias que consumen cuota de vCPU
  secure_boot_enabled = var.trusted_launch_enabled
  vtpm_enabled        = var.trusted_launch_enabled

  tags = local.tags

  lifecycle {
    # E3 - El autoscale manda sobre el número de instancias; Terraform no lo revierte
    ignore_changes = [instances]
  }

  # La regla del LB debe existir antes de usar la sonda en el VMSS
  depends_on = [azurerm_lb_rule.http, azurerm_subnet_network_security_group_association.app]
}

# ---------------------------------------------------------------------
# E3 - Autoscale con histéresis (70 % sube / 30 % baja)
# ---------------------------------------------------------------------
resource "azurerm_monitor_autoscale_setting" "app" {
  name                = "autoscale-${local.name}-app"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.app.id
  enabled             = true
  tags                = local.tags

  profile {
    name = "default-cpu"

    capacity {
      minimum = var.autoscale_min
      default = var.autoscale_default
      maximum = var.autoscale_max
    }

    # Scale-out: CPU promedio > 70 % durante 5 min -> +1 instancia.
    # Ventana corta = reacción rápida ante picos; cooldown 5 min = tiempo de arranque + cloud-init
    # + 2 sondas sanas, para no volver a escalar antes de que la nueva instancia absorba carga.
    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.app.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = var.cpu_scale_out_threshold
      }
      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = 1
        cooldown  = var.scale_out_cooldown
      }
    }

    # Scale-in: CPU promedio < 30 % durante 10 min -> -1 instancia.
    # Umbral muy por debajo del de scale-out (histéresis 40 pp): tras retirar 1 de N instancias la
    # CPU de las restantes sube ~N/(N-1); con 30 % el resultado (~45 % con 2->3) queda lejos de 70 %,
    # evitando el "flapping". Ventana y cooldown de 10 min: reducir capacidad es lo riesgoso.
    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.app.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = var.cpu_scale_in_threshold
      }
      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = 1
        cooldown  = var.scale_in_cooldown
      }
    }
  }

  notification {
    email {
      custom_emails = [var.alert_email]
    }
  }
}
