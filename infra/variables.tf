# -------------------- Generales --------------------
variable "subscription_id" {
  description = "ID de la suscripción. Dejar null para usar ARM_SUBSCRIPTION_ID / la sesión de az."
  type        = string
  default     = null
}

variable "prefix" {
  description = "Prefijo corto para nombrar recursos."
  type        = string
  default     = "caribeshop"

  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.prefix))
    error_message = "prefix: 3-12 caracteres, solo minúsculas y dígitos."
  }
}

variable "location" {
  description = "Región de Azure CON zonas de disponibilidad (E1). Verificar cuota: az vm list-usage -l <region> -o table."
  type        = string
  default     = "centralus" # permitida por la política de Azure for Students y con 3 zonas
}

variable "tags" {
  description = "Etiquetas comunes."
  type        = map(string)
  default = {
    proyecto   = "caribeshop"
    curso      = "infraestructura-ti-utb"
    ambiente   = "prod"
    gestionado = "terraform"
  }
}

# -------------------- Operador / notificaciones --------------------
variable "operator_ip" {
  description = "IP pública del operador (sin /32). Única IP fuera de snet-app autorizada en el firewall del Key Vault y del Storage, y la única que puede llamar /simulate-failure."
  type        = string

  validation {
    condition     = can(cidrhost("${var.operator_ip}/32", 0))
    error_message = "operator_ip debe ser una IPv4 válida, p. ej. 181.50.10.20."
  }
}

variable "alert_email" {
  description = "Correo que recibe las alertas de Azure Monitor (E5) y notificaciones de autoscale."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email no es un correo válido."
  }
}

# -------------------- Red --------------------
variable "vnet_cidr" {
  description = "Espacio de direcciones de la VNet."
  type        = string
  default     = "10.20.0.0/16"
}

variable "snet_app_cidr" {
  description = "Subred de aplicación (VMSS)."
  type        = string
  default     = "10.20.1.0/24"
}

# -------------------- Cómputo --------------------
variable "vm_size" {
  description = "Tamaño de instancia. B2ps_v2 = 2 vCPU Arm64 (único tamaño B zonal disponible en la suscripción); con max 3 instancias se usan 6 vCPU (cuota regional)."
  type        = string
  default     = "Standard_B2ps_v2"
}

variable "image_sku" {
  description = "SKU de Ubuntu 24.04 LTS: server-arm64 para tamaños Arm64 (B2ps_v2), server para x86."
  type        = string
  default     = "server-arm64"
}

variable "trusted_launch_enabled" {
  description = "Secure Boot + vTPM. Desactivado por defecto: soporte limitado en tamaños Arm64."
  type        = bool
  default     = false
}

variable "zones" {
  description = "Zonas de disponibilidad del VMSS (E1: al menos 2)."
  type        = list(string)
  default     = ["1", "2"]

  validation {
    condition     = length(var.zones) >= 2
    error_message = "E1 exige al menos 2 zonas de disponibilidad."
  }
}

variable "admin_username" {
  description = "Usuario administrador (solo llave SSH; SSH no está expuesto)."
  type        = string
  default     = "azureops"
}

# -------------------- Autoscale (E3) --------------------
variable "autoscale_min" {
  description = "Instancias mínimas (E1: 2). Para P1.1 se usa temporalmente 1."
  type        = number
  default     = 2
}

variable "autoscale_default" {
  description = "Instancias por defecto si no hay métricas."
  type        = number
  default     = 2
}

variable "autoscale_max" {
  description = "Instancias máximas. Ajustar a la cuota de vCPU de la región."
  type        = number
  default     = 3
}

variable "cpu_scale_out_threshold" {
  description = "CPU promedio (%) que dispara scale-out."
  type        = number
  default     = 70
}

variable "cpu_scale_in_threshold" {
  description = "CPU promedio (%) que dispara scale-in. Debe ser bastante menor que el de scale-out (histéresis)."
  type        = number
  default     = 30
}

variable "scale_out_cooldown" {
  description = "Cooldown tras scale-out (ISO 8601). Cubre arranque + cloud-init + 2 sondas sanas (~3-4 min)."
  type        = string
  default     = "PT5M"
}

variable "scale_in_cooldown" {
  description = "Cooldown tras scale-in (ISO 8601). Más largo que el de scale-out: retirar capacidad es lo arriesgado."
  type        = string
  default     = "PT10M"
}

# -------------------- Secretos --------------------
variable "secret_expiration_days" {
  description = "Días de vigencia del secreto de la base de datos (S3: secreto con expiración)."
  type        = number
  default     = 90
}

variable "log_retention_days" {
  description = "Retención del Log Analytics Workspace."
  type        = number
  default     = 30
}
