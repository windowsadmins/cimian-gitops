data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "cimian" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ─── Storage ──────────────────────────────────────────────────────────────────
#
# One account, two containers:
#   repo    private. The Cimian repo: deployment/{catalogs,manifests,pkgsinfo,
#           icons,pkgs}. Clients reach it only through Front Door.
#   public  anonymous blob read, no listing. The bootstrap files BootstrapMate
#           fetches at the ESP, under bootstrap/, before the machine has any
#           credential to present.

resource "azurerm_storage_account" "repo" {
  name                            = var.storage_account_name
  resource_group_name             = azurerm_resource_group.cimian.name
  location                        = azurerm_resource_group.cimian.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = true # only the public container uses it
  tags                            = var.tags

  blob_properties {
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }

  # The repo is the fleet's source of software. Losing it is an outage, so a
  # plan that would replace it must be an explicit, reviewed edit.
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "repo" {
  name                  = "repo"
  storage_account_id    = azurerm_storage_account.repo.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "public" {
  name                  = "public"
  storage_account_id    = azurerm_storage_account.repo.id
  container_access_type = "blob"
}

# ─── Key Vault (RBAC, no access policies) ────────────────────────────────────

resource "azurerm_key_vault" "cimian" {
  name                       = var.key_vault_name
  location                   = azurerm_resource_group.cimian.location
  resource_group_name        = azurerm_resource_group.cimian.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 90
  tags                       = var.tags
}

# Terraform itself writes the client token below, so whoever runs it needs to
# set secrets. Everything else only reads.
resource "azurerm_role_assignment" "terraform_kv_secrets_officer" {
  scope                = azurerm_key_vault.cimian.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ─── Pipeline identity ────────────────────────────────────────────────────────

resource "azurerm_role_assignment" "pipeline_blob_contributor" {
  scope                = azurerm_storage_account.repo.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.pipeline_principal_id
}

resource "azurerm_role_assignment" "pipeline_kv_secrets_user" {
  scope                = azurerm_key_vault.cimian.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.pipeline_principal_id
}

resource "azurerm_role_assignment" "pipeline_cdn_endpoint_contributor" {
  scope                = azurerm_cdn_frontdoor_profile.cimian.id
  role_definition_name = "CDN Endpoint Contributor"
  principal_id         = var.pipeline_principal_id
}

# ─── Optional admin group ─────────────────────────────────────────────────────

resource "azurerm_role_assignment" "admin_kv" {
  count                = var.admin_group_object_id == "" ? 0 : 1
  scope                = azurerm_key_vault.cimian.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = var.admin_group_object_id
  principal_type       = "Group"
}

resource "azurerm_role_assignment" "admin_blob" {
  count                = var.admin_group_object_id == "" ? 0 : 1
  scope                = azurerm_storage_account.repo.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = var.admin_group_object_id
  principal_type       = "Group"
}

# ─── Client authentication ────────────────────────────────────────────────────
#
# Clients send a shared token in an X-Cimian-Token header (Cimian's
# AdditionalHttpHeaders setting). Two layers act on it:
#
#   1. A WAF custom rule blocks any /deployment/ request whose header is
#      missing or wrong, with a 403. The WAF runs before the cache lookup, so
#      an unauthenticated request never reaches the cache and can never be
#      served an object an authorised client caused to be cached. The cache key
#      is the URL alone, which is why rejection has to happen first.
#   2. For requests that pass, a rule-set rule strips the header and appends a
#      read-only SAS, so the private container serves them.
#
# The token is generated here and kept in Key Vault, so the preferences package
# that sets AdditionalHttpHeaders reads it from the vault at build time.

resource "random_password" "client_token" {
  length  = 48
  special = false
}

resource "azurerm_key_vault_secret" "client_token" {
  name         = "cimian-client-token"
  value        = random_password.client_token.result
  key_vault_id = azurerm_key_vault.cimian.id
  content_type = "X-Cimian-Token header value for Cimian clients"

  depends_on = [azurerm_role_assignment.terraform_kv_secrets_officer]
}

# A rotating anchor keeps the SAS stable between runs. Deriving it from
# timestamp() would change it on every plan, so every run would show a diff.
resource "time_rotating" "sas" {
  rotation_days = var.sas_rotation_days
}

data "azurerm_storage_account_sas" "read" {
  connection_string = azurerm_storage_account.repo.primary_connection_string
  https_only        = true
  start             = timeadd(time_rotating.sas.id, "-24h")
  # Twice the rotation period, so a missed run does not cut the fleet off.
  expiry = timeadd(time_rotating.sas.id, "${var.sas_rotation_days * 2 * 24}h")

  resource_types {
    service   = false
    container = false
    object    = true
  }

  services {
    blob  = true
    queue = false
    table = false
    file  = false
  }

  permissions {
    read    = true
    write   = false
    delete  = false
    list    = false
    add     = false
    create  = false
    update  = false
    process = false
    tag     = false
    filter  = false
  }
}

# ─── Front Door ───────────────────────────────────────────────────────────────

resource "azurerm_cdn_frontdoor_profile" "cimian" {
  name                = var.frontdoor_profile_name
  resource_group_name = azurerm_resource_group.cimian.name
  sku_name            = "Standard_AzureFrontDoor"
  tags                = var.tags
}

resource "azurerm_cdn_frontdoor_endpoint" "cimian" {
  name                     = var.frontdoor_endpoint_name
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.cimian.id
  tags                     = var.tags
}

resource "azurerm_cdn_frontdoor_custom_domain" "cimian" {
  count                    = var.custom_domain == "" ? 0 : 1
  name                     = replace(var.custom_domain, ".", "-")
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.cimian.id
  host_name                = var.custom_domain

  tls {
    certificate_type = "ManagedCertificate"
  }
}

resource "azurerm_cdn_frontdoor_origin_group" "blob" {
  name                     = "blob"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.cimian.id

  load_balancing {
    sample_size                 = 4
    successful_samples_required = 1
  }
}

resource "azurerm_cdn_frontdoor_origin" "blob" {
  name                           = "blob"
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.blob.id
  host_name                      = azurerm_storage_account.repo.primary_blob_host
  origin_host_header             = azurerm_storage_account.repo.primary_blob_host
  certificate_name_check_enabled = true
  enabled                        = true
  priority                       = 1
  weight                         = 1000
}

resource "azurerm_cdn_frontdoor_rule_set" "repo" {
  name                     = "cimianrepo"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.cimian.id
}

# Packages are version-named and never change in place, so the edge can keep
# them for a year. Metadata (catalogs, manifests, pkgsinfo) keeps the short
# default TTL and is purged by the push pipeline on every deploy. Continue, so
# the auth rule still runs.
resource "azurerm_cdn_frontdoor_rule" "pkg_immutable" {
  name                      = "pkgimmutable"
  cdn_frontdoor_rule_set_id = azurerm_cdn_frontdoor_rule_set.repo.id
  order                     = 1
  behavior_on_match         = "Continue"

  conditions {
    url_file_extension_condition {
      operator     = "Equal"
      match_values = ["nupkg", "msi", "exe", "zip"]
      transforms   = ["Lowercase"]
    }
  }

  actions {
    route_configuration_override_action {
      cache_behavior                = "OverrideAlways"
      cache_duration                = "365.00:00:00"
      query_string_caching_behavior = "IgnoreQueryString"
    }
  }

  depends_on = [azurerm_cdn_frontdoor_origin.blob]
}

resource "azurerm_cdn_frontdoor_rule" "client_token" {
  name                      = "clienttoken"
  cdn_frontdoor_rule_set_id = azurerm_cdn_frontdoor_rule_set.repo.id
  order                     = 2
  behavior_on_match         = "Stop"

  conditions {
    request_header_condition {
      header_name  = "X-Cimian-Token"
      operator     = "Equal"
      match_values = [random_password.client_token.result]
    }
  }

  actions {
    request_header_action {
      header_action = "Delete"
      header_name   = "X-Cimian-Token"
    }

    # The route's origin path adds the /repo container prefix; this only
    # appends the SAS to whatever path the client asked for.
    url_rewrite_action {
      source_pattern          = "/"
      destination             = "/{url_path}?${trimprefix(data.azurerm_storage_account_sas.read.sas, "?")}"
      preserve_unmatched_path = false
    }
  }

  depends_on = [azurerm_cdn_frontdoor_origin.blob]
}

resource "azurerm_cdn_frontdoor_route" "repo" {
  name                            = "repo"
  cdn_frontdoor_endpoint_id       = azurerm_cdn_frontdoor_endpoint.cimian.id
  cdn_frontdoor_origin_group_id   = azurerm_cdn_frontdoor_origin_group.blob.id
  cdn_frontdoor_origin_ids        = [azurerm_cdn_frontdoor_origin.blob.id]
  cdn_frontdoor_rule_set_ids      = [azurerm_cdn_frontdoor_rule_set.repo.id]
  cdn_frontdoor_custom_domain_ids = azurerm_cdn_frontdoor_custom_domain.cimian[*].id
  cdn_frontdoor_origin_path       = "/repo"
  patterns_to_match               = ["/deployment/*"]
  supported_protocols             = ["Http", "Https"]
  https_redirect_enabled          = true
  forwarding_protocol             = "HttpsOnly"
  link_to_default_domain          = true

  cache {
    # Cached objects are shared between clients. That is safe only because the
    # WAF policy below rejects a request without a valid token before the cache
    # is consulted; see "Client authentication" above.
    query_string_caching_behavior = "IgnoreQueryString"
    compression_enabled           = true
    content_types_to_compress     = ["application/json", "application/xml", "text/plain", "text/csv"]
  }
}

resource "azurerm_cdn_frontdoor_route" "bootstrap" {
  name                            = "bootstrap"
  cdn_frontdoor_endpoint_id       = azurerm_cdn_frontdoor_endpoint.cimian.id
  cdn_frontdoor_origin_group_id   = azurerm_cdn_frontdoor_origin_group.blob.id
  cdn_frontdoor_origin_ids        = [azurerm_cdn_frontdoor_origin.blob.id]
  cdn_frontdoor_custom_domain_ids = azurerm_cdn_frontdoor_custom_domain.cimian[*].id
  cdn_frontdoor_origin_path       = "/public/bootstrap"
  patterns_to_match               = ["/bootstrap/*"]
  supported_protocols             = ["Http", "Https"]
  https_redirect_enabled          = true
  forwarding_protocol             = "HttpsOnly"
  link_to_default_domain          = true

  cache {
    query_string_caching_behavior = "IgnoreQueryString"
    compression_enabled           = true
    content_types_to_compress     = ["application/json", "text/plain"]
  }
}

resource "azurerm_cdn_frontdoor_custom_domain_association" "cimian" {
  count                          = var.custom_domain == "" ? 0 : 1
  cdn_frontdoor_custom_domain_id = azurerm_cdn_frontdoor_custom_domain.cimian[0].id
  cdn_frontdoor_route_ids = [
    azurerm_cdn_frontdoor_route.repo.id,
    azurerm_cdn_frontdoor_route.bootstrap.id,
  ]
}

# ─── WAF: reject unauthenticated requests before the cache ───────────────────
#
# Custom rules are available on the Standard tier. The rule matches when the
# path is under /deployment/ AND the token header is not exactly the expected
# value (a missing header also fails the Equal test), and blocks with a 403.
# /bootstrap/* is outside the match and stays public.

resource "azurerm_cdn_frontdoor_firewall_policy" "cimian" {
  name                              = "cimianwaf"
  resource_group_name               = azurerm_resource_group.cimian.name
  sku_name                          = azurerm_cdn_frontdoor_profile.cimian.sku_name
  enabled                           = true
  mode                              = "Prevention"
  custom_block_response_status_code = 403
  tags                              = var.tags

  custom_rule {
    name     = "RequireClientToken"
    enabled  = true
    priority = 1
    type     = "MatchRule"
    action   = "Block"

    match_condition {
      match_variable = "RequestUri"
      operator       = "Contains"
      match_values   = ["/deployment/"]
      transforms     = ["Lowercase"]
    }

    match_condition {
      match_variable     = "RequestHeader"
      selector           = "X-Cimian-Token"
      operator           = "Equal"
      negation_condition = true
      match_values       = [random_password.client_token.result]
    }
  }
}

resource "azurerm_cdn_frontdoor_security_policy" "cimian" {
  name                     = "cimian-waf"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.cimian.id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.cimian.id

      association {
        patterns_to_match = ["/*"]

        domain {
          cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_endpoint.cimian.id
        }

        dynamic "domain" {
          for_each = azurerm_cdn_frontdoor_custom_domain.cimian
          content {
            cdn_frontdoor_domain_id = domain.value.id
          }
        }
      }
    }
  }
}
