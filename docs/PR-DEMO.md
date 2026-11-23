# D1 — PR que falla por seguridad y su corrección

El taller exige **al menos dos PR cerrados**: uno donde el pipeline falla por un hallazgo introducido a propósito y su corrección.

## 0. Preparación (una vez)

```bash
git init -b main && git add . && git commit -m "feat: plataforma CaribeShop base"
git remote add origin https://github.com/<org>/<repo>.git && git push -u origin main
```

En GitHub: *Settings → Branches → Add branch protection rule* para `main`:
- ✅ Require a pull request before merging
- ✅ Require status checks to pass → seleccionar los 4 jobs de `ci`

## 1. PR #1 — introducir un hallazgo (debe FALLAR)

```bash
git checkout -b demo/ssh-abierto
```

Agregar en `infra/network.tf`, dentro de `azurerm_network_security_group.app`:

```hcl
  security_rule {
    name                       = "Allow-SSH-Internet" # ¡INSEGURO A PROPÓSITO!
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
```

```bash
git commit -am "demo: abrir SSH a Internet (debe fallar Checkov)"
git push -u origin demo/ssh-abierto
# Abrir el PR hacia main
```

Resultado esperado en el job **checkov (bloqueante)**:

```
Check: CKV_AZURE_10: "Ensure that SSH access is restricted from the internet"
	FAILED for resource: azurerm_network_security_group.app
```

El botón *Merge* queda bloqueado. **Capturar pantalla** del PR con el check en rojo.

## 2. PR #2 — corrección (debe PASAR)

```bash
git checkout demo/ssh-abierto
git revert --no-edit HEAD            # o eliminar el bloque manualmente
git commit --amend -m "fix: cerrar SSH; acceso de emergencia vía az vmss run-command"
git push
```

Todos los checks pasan en verde → *Squash and merge*. Capturar pantalla.

> Alternativa: cerrar el PR #1 sin merge y abrir un PR #2 desde otra rama con la corrección. Lo importante es que en el historial queden dos PR cerrados: uno rojo y otro verde.

## Otros hallazgos útiles para la demo

| Cambio inseguro | Check que falla |
|---|---|
| `purge_protection_enabled = false` en el Key Vault | `CKV_AZURE_110`, `CKV_AZURE_42` |
| `network_acls { default_action = "Allow" ... }` | `CKV_AZURE_109` |
| Quitar `expiration_date` del secreto | `CKV_AZURE_41` |
| `disable_password_authentication = false` en el VMSS | `CKV_AZURE_49` |
| Contraseña literal en un `.tf` | `CKV_SECRET_*` (framework secrets) y gitleaks |
