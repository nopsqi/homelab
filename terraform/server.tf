resource "hcloud_server" "main" {
	name		= "nopsqi"
	location	= "fsn1"
	image		= "debian-12"
	server_type	= "cx23"
  ssh_keys = [hcloud_ssh_key.main.id]
  firewall_ids = [hcloud_firewall.drop_all_inbound.id]
}
