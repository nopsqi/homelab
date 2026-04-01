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
