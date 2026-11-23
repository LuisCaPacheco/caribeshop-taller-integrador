# =====================================================================
# S6 - Diagnostic settings del Key Vault -> Log Analytics (AuditEvent)
# E5 - Alertas de Azure Monitor -> Action Group con correo
# =====================================================================

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${local.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  daily_quota_gb      = 1 # tope de costo para el taller
  tags                = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "kv" {
  name                       = "diag-kv-to-law"
  target_resource_id         = azurerm_key_vault.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  # Tablas específicas (AZKVAuditLogs) en lugar de AzureDiagnostics
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "AuditEvent"
  }

  enabled_log {
    category = "AzurePolicyEvaluationDetails"
  }
}

# Métricas del LB (DipAvailability / VipAvailability) también a Log Analytics para el informe
resource "azurerm_monitor_diagnostic_setting" "lb" {
  name                       = "diag-lb-to-law"
  target_resource_id         = azurerm_lb.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_action_group" "ops" {
  name                = "ag-${local.name}-ops"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "cs-ops"
  tags                = local.tags

  email_receiver {
    name                    = "operador"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

# E5 (a) - Alguna instancia falla la sonda: Health Probe Status (DipAvailability) < 100 %
resource "azurerm_monitor_metric_alert" "probe_degraded" {
  name                = "alert-${local.name}-probe-below-100"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_lb.main.id]
  description         = "Una o más instancias del VMSS fallan la sonda /health (Health Probe Status < 100 %)."
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"
  auto_mitigate       = true
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.Network/loadBalancers"
    metric_name      = "DipAvailability"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 100
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

# E5 (b) - CPU sostenida alta aun con el autoscale actuando (posible límite de max_instances / cuota)
resource "azurerm_monitor_metric_alert" "cpu_sustained" {
  name                = "alert-${local.name}-cpu-sustained"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_linux_virtual_machine_scale_set.app.id]
  description         = "CPU promedio del VMSS > 85 % durante 15 min: el autoscale llegó al máximo o no alcanza."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  auto_mitigate       = true
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachineScaleSets"
    metric_name      = "Percentage CPU"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 85
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

# Auditoría de gobierno: cualquier denegación por Azure Policy en el RG notifica al operador
resource "azurerm_monitor_activity_log_alert" "policy_deny" {
  name                = "alert-${local.name}-policy-deny"
  resource_group_name = azurerm_resource_group.main.name
  location            = "global"
  scopes              = [azurerm_resource_group.main.id]
  description         = "Se intentó crear/modificar un recurso que viola una política Deny (S5)."
  tags                = local.tags

  criteria {
    category       = "Policy"
    operation_name = "Microsoft.Authorization/policies/deny/action"
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}
