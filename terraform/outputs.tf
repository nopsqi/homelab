output "ipv4" {
  value     = hcloud_server.main.ipv4_address
  sensitive = false
}

output "storage_box" {
  value = "${hcloud_storage_box.archive.username}@${hcloud_storage_box.archive.server}"
}

output "obsidian_webdav" {
  value = "https://${hcloud_storage_box_subaccount.obsidian.server} (user: ${hcloud_storage_box_subaccount.obsidian.username})"
}

output "syncthing_smb" {
  value = "//${hcloud_storage_box_subaccount.syncthing.server}/${hcloud_storage_box_subaccount.syncthing.username}"
}

output "assistant_smb" {
  value = "//${hcloud_storage_box_subaccount.assistant.server}/${hcloud_storage_box_subaccount.assistant.username}"
}
