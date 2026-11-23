# =====================================================================
# S3 - Key Vault (RBAC, purge protection, firewall) + secreto con expiración
# S4 - Mínimo privilegio: la identidad del VMSS solo lee ESE secreto
# Storage sin llaves compartidas y con firewall (arquitectura de referencia)
# =====================================================================

resource "azurerm_key_vault" "main" {
  #checkov:skip=CKV_AZURE_189:Se requiere acceso público FILTRADO (firewall Deny + snet-app vía service endpoint + IP del operador). Deshabilitarlo exige Private Endpoint + DNS privado (+costo); riesgo aceptado y mitigado por el firewall.
  #checkov:skip=CKV2_AZURE_32:Sin Private Endpoint por costo/alcance del taller; el acceso se restringe con service endpoint + firewall (default_action = Deny).
  name                = local.kv_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled    = true # modelo de permisos RBAC (no access policies)
  purge_protection_enabled      = true # S3: el vault no puede purgarse antes del periodo de retención
  soft_delete_retention_days    = 7
  public_network_access_enabled = true # filtrado por network_acls

  network_acls {
    default_action             = "Deny"
    bypass                     = "AzureServices"
    ip_rules                   = ["${var.operator_ip}/32"]
    virtual_network_subnet_ids = [azurerm_subnet.app.id]
  }

  tags = local.tags
}

# El operador (quien ejecuta Terraform) necesita escribir el secreto: rol de datos sobre el vault.
resource "azurerm_role_assignment" "operator_kv_secrets_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
  description          = "Operador de Terraform: gestionar secretos de CaribeShop"
}

# La propagación de RBAC tarda; sin esta espera el primer apply falla con 403.
resource "time_sleep" "wait_kv_rbac" {
  depends_on      = [azurerm_role_assignment.operator_kv_secrets_officer]
  create_duration = "90s"
}

# El valor nunca está en Git ni en variables: se genera aquí y solo vive en el estado remoto.
resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#%*-_=+"
}

# Fecha de expiración estable (no cambia en cada plan como timestamp())
resource "time_offset" "secret_expiration" {
  offset_days = var.secret_expiration_days
}

resource "azurerm_key_vault_secret" "db_password" {
  name            = local.db_secret_name
  value           = random_password.db.result
  key_vault_id    = azurerm_key_vault.main.id
  content_type    = "text/plain; contraseña de la base de datos de CaribeShop"
  expiration_date = time_offset.secret_expiration.rfc3339 # S3: secreto con expiración
  tags            = local.tags

  depends_on = [time_sleep.wait_kv_rbac]
}

# S4 - Rol de SOLO LECTURA de secretos, con alcance al secreto (no al vault entero),
# asignado exclusivamente a la identidad SystemAssigned del VMSS.
resource "azurerm_role_assignment" "vmss_kv_secret_reader" {
  scope                = "${azurerm_key_vault.main.id}/secrets/${azurerm_key_vault_secret.db_password.name}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine_scale_set.app.identity[0].principal_id
  principal_type       = "ServicePrincipal"
  description          = "VMSS CaribeShop: leer únicamente el secreto db-password"
}

# ---------------------------------------------------------------------
# Storage de la arquitectura de referencia: sin llaves, firewall, ZRS
# (destinado a catálogo/estáticos; la app aún no lo consume -> la identidad del VMSS no tiene rol aquí)
# ---------------------------------------------------------------------
resource "azurerm_storage_account" "main" {
  #checkov:skip=CKV2_AZURE_1:Cifrado con llaves administradas por Microsoft (AES-256) + cifrado de infraestructura. CMK requiere un key vault con llave y rotación propia; fuera del alcance del taller.
  #checkov:skip=CKV2_AZURE_33:Sin Private Endpoint por costo; acceso restringido por firewall (Deny) a snet-app + IP del operador.
  #checkov:skip=CKV_AZURE_33:No se usan colas (Queue service); el registro de colas no aporta evidencia.
  #checkov:skip=CKV_AZURE_59:El acceso público de red se mantiene pero filtrado por network_rules (default Deny); ver CKV2_AZURE_33.
  #checkov:skip=CKV_AZURE_43:Falso positivo: el nombre es "st"+prefix+sufijo aleatorio y Checkov no resuelve random_string. var.prefix se valida con regex ^[a-z0-9]{3,12}$ -> nombre de 10-19 caracteres en minúsculas y dígitos (cumple la regla).
  #checkov:skip=CKV_AZURE_206:Se usa ZRS (tolera la caída de una zona, igual que el VMSS). GRS duplicaría el costo y no hay requisito de recuperación regional.
  name                              = local.st_name
  location                          = azurerm_resource_group.main.location
  resource_group_name               = azurerm_resource_group.main.name
  account_tier                      = "Standard"
  account_replication_type          = "ZRS"
  account_kind                      = "StorageV2"
  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  shared_access_key_enabled         = false # sin llaves: solo Entra ID
  allow_nested_items_to_be_public   = false
  infrastructure_encryption_enabled = true
  public_network_access_enabled     = true

  sas_policy {
    expiration_period = "01.00:00:00"
    expiration_action = "Log"
  }

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }

  network_rules {
    default_action             = "Deny"
    bypass                     = ["AzureServices", "Logging", "Metrics"]
    ip_rules                   = [var.operator_ip]
    virtual_network_subnet_ids = [azurerm_subnet.app.id]
  }

  tags = local.tags
}

resource "azurerm_storage_container" "catalog" {
  #checkov:skip=CKV2_AZURE_21:Los registros de lectura de blobs no se requieren para un contenedor sin consumidores todavía; la auditoría obligatoria (S6) es la del Key Vault.
  name                  = "catalogo"
  storage_account_id    = azurerm_storage_account.main.id # vía ARM: no requiere llaves
  container_access_type = "private"
}
