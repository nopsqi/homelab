variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "public_key" {
  description = "Public Key"
  type        = string
  sensitive   = false
}

variable "storage_box_password" {
  description = "Storage Box password (Hetzner password policy applies)"
  type        = string
  sensitive   = true
  validation {
    condition = alltrue([
      can(regex("[A-Z]", var.storage_box_password)),
      can(regex("[a-z]", var.storage_box_password)),
      can(regex("[0-9]", var.storage_box_password)),
      can(regex("[^A-Za-z0-9]", var.storage_box_password)),
    ])
    error_message = "Hetzner Storage Box policy: needs an upper case letter, a lower case letter, a number and a special character."
  }
}

variable "obsidian_password" {
  description = "Storage Box sub-account password for Obsidian Remotely Save"
  type        = string
  sensitive   = true
  validation {
    condition = alltrue([
      can(regex("[A-Z]", var.obsidian_password)),
      can(regex("[a-z]", var.obsidian_password)),
      can(regex("[0-9]", var.obsidian_password)),
      can(regex("[^A-Za-z0-9]", var.obsidian_password)),
    ])
    error_message = "Hetzner Storage Box policy: needs an upper case letter, a lower case letter, a number and a special character."
  }
}

variable "syncthing_password" {
  description = "Storage Box sub-account password for the Syncthing SMB mount"
  type        = string
  sensitive   = true
  validation {
    condition = alltrue([
      can(regex("[A-Z]", var.syncthing_password)),
      can(regex("[a-z]", var.syncthing_password)),
      can(regex("[0-9]", var.syncthing_password)),
      can(regex("[^A-Za-z0-9]", var.syncthing_password)),
    ])
    error_message = "Hetzner Storage Box policy: needs an upper case letter, a lower case letter, a number and a special character."
  }
}
