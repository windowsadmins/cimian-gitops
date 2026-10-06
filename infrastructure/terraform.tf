terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # State lives in a storage account of its own, created once by hand or by a
  # bootstrap config, never by this one. The pipelines pass the four settings
  # with -backend-config, so nothing about your state account is committed.
  # use_azuread_auth reads state with the pipeline identity's Storage Blob Data
  # Contributor role on the state container instead of an account key.
  backend "azurerm" {
    use_azuread_auth = true
    # resource_group_name  = "<state-resource-group>"
    # storage_account_name = "<state-storage-account>"
    # container_name       = "tfstate"
    # key                  = "cimian.tfstate"
  }
}

provider "azurerm" {
  features {}
  storage_use_azuread = true
}
