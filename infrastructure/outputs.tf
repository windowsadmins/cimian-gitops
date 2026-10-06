output "resource_group_name" {
  value = azurerm_resource_group.cimian.name
}

output "storage_account_name" {
  value = azurerm_storage_account.repo.name
}

output "key_vault_name" {
  value = azurerm_key_vault.cimian.name
}

output "frontdoor_profile_name" {
  value = azurerm_cdn_frontdoor_profile.cimian.name
}

output "frontdoor_endpoint_name" {
  value = azurerm_cdn_frontdoor_endpoint.cimian.name
}

output "software_repo_url" {
  description = "SoftwareRepoURL for Cimian clients."
  value       = "https://${var.custom_domain != "" ? var.custom_domain : azurerm_cdn_frontdoor_endpoint.cimian.host_name}/deployment"
}

output "bootstrap_manifest_url" {
  description = "The URL BootstrapMate reads management.json from."
  value       = "https://${var.custom_domain != "" ? var.custom_domain : azurerm_cdn_frontdoor_endpoint.cimian.host_name}/bootstrap/management.json"
}

output "client_token_secret_name" {
  description = "Key Vault secret holding the X-Cimian-Token value."
  value       = azurerm_key_vault_secret.client_token.name
}

output "custom_domain_validation_token" {
  description = "TXT record value for _dnsauth.<custom_domain>, when a custom domain is set."
  value       = var.custom_domain == "" ? null : azurerm_cdn_frontdoor_custom_domain.cimian[0].validation_token
}
