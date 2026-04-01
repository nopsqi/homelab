resource "hcloud_ssh_key" "main" {
	name		= "thinkpad-t480"
	public_key	= var.public_key
}
