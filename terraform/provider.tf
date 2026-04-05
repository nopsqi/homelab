terraform {
  cloud {
    organization = "nopsqi"
    workspaces {
      name = "homelab"
    }
  }

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.50"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}
