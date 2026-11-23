# Solo valores NO sensibles. El secreto y la llave privada nunca se exponen como output.

output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "app_url" {
  description = "URL pública de la aplicación (a través del Load Balancer)."
  value       = "http://${azurerm_public_ip.lb.fqdn}"
}

output "lb_public_ip" {
  value = azurerm_public_ip.lb.ip_address
}

output "lb_id" {
  value = azurerm_lb.main.id
}

output "vmss_name" {
  value = azurerm_linux_virtual_machine_scale_set.app.name
}

output "vmss_id" {
  value = azurerm_linux_virtual_machine_scale_set.app.id
}

output "vmss_principal_id" {
  description = "principal_id de la identidad administrada del VMSS (S4: az role assignment list --assignee)."
  value       = azurerm_linux_virtual_machine_scale_set.app.identity[0].principal_id
}

output "autoscale_name" {
  value = azurerm_monitor_autoscale_setting.app.name
}

output "key_vault_name" {
  value = azurerm_key_vault.main.name
}

output "key_vault_secret_name" {
  value = azurerm_key_vault_secret.db_password.name
}

output "storage_account_name" {
  value = azurerm_storage_account.main.name
}

output "log_analytics_workspace_id" {
  description = "customerId (GUID) del workspace para az monitor log-analytics query."
  value       = azurerm_log_analytics_workspace.main.workspace_id
}

output "nsg_name" {
  value = azurerm_network_security_group.app.name
}
