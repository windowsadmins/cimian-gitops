variable "resource_group_name" {
  description = "Resource group that holds the Cimian repo resources."
  type        = string
  default     = "rg-cimian-example"
}

variable "location" {
  description = "Azure region for the resource group, storage and Key Vault."
  type        = string
  default     = "canadacentral"
}

variable "storage_account_name" {
  description = "Globally unique storage account name: 3-24 lowercase letters and digits."
  type        = string
  default     = "examplecimianstorage"
}

variable "key_vault_name" {
  description = "Globally unique Key Vault name: 3-24 letters, digits and hyphens."
  type        = string
  default     = "kv-cimian-example"
}

variable "frontdoor_profile_name" {
  description = "Azure Front Door profile name."
  type        = string
  default     = "afd-cimian-example"
}

variable "frontdoor_endpoint_name" {
  description = "Front Door endpoint name. It becomes <name>-<hash>.z01.azurefd.net."
  type        = string
  default     = "cimian-example"
}

variable "custom_domain" {
  description = "Optional custom host name for the CDN, e.g. cimian.example.com. Leave empty to use the azurefd.net host only. Validate the domain in DNS after the first apply."
  type        = string
  default     = ""
}

variable "pipeline_principal_id" {
  description = "Object ID of the identity the pipelines run as (the service connection's workload identity, or the GitHub OIDC app's service principal). It gets data-plane access to storage, read access to Key Vault secrets and purge rights on Front Door."
  type        = string
}

variable "admin_group_object_id" {
  description = "Optional object ID of an Entra group that administers the vault and storage. Leave empty to skip."
  type        = string
  default     = ""
}

variable "sas_rotation_days" {
  description = "How often the read-only SAS that Front Door appends for authenticated clients is reissued. A new SAS is only applied when Terraform runs, so run the infra pipeline at least this often."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    managed-by = "terraform"
    workload   = "cimian"
  }
}
