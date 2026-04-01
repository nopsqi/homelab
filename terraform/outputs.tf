output "ipv4" {
  value = hcloud_server.main.ipv4_address
	sensitive = false
}
