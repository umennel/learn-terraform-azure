# Configure the Azure provider

terraform {
  required_version = ">= 1.1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.117"
    }
  }
  backend "azurerm" {
    use_cli              = true
    use_azuread_auth     = true
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "stmenutfstatedev"
    container_name       = "tfstate"
    key                  = "prod/terraform.tfstate"
  }
  # cloud {
  #   organization = "example-org"
  #   workspaces {
  #     name = "learn-terraform-azure"
  #   }
  # }
}

provider "azurerm" {
  features {}
}

variable "resource_group_name" {
  default = "rg-myfirsttfgroup"
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = "westeurope"
  
  tags = {
    Environment = "Terraform Getting Started"
    Team = "DevOps"
  }
}

# Create a virtual network
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-myfirsttfvnet"
  address_space       = ["10.0.0.0/16"]
  location            = "westeurope"
  resource_group_name = azurerm_resource_group.rg.name
}

output "resource_group_id" {
  value = azurerm_resource_group.rg.id
}
