resource "hcloud_storage_box" "archive" {
  name             = "archive"
  storage_box_type = "bx11"
  location         = "fsn1"
  password         = var.storage_box_password

  # SSH keys can't be updated via the API: changing this list replaces the box (= data loss).
  ssh_keys = [var.public_key]

  access_settings = {
    reachable_externally = true # laptop restic + phone browsing come from outside Hetzner
    ssh_enabled          = true # sftp, rsync, restic, rclone
    samba_enabled        = false
    webdav_enabled       = false
    zfs_enabled          = false
  }

  snapshot_plan = {
    max_snapshots = 7
    hour          = 3
    minute        = 0
  }

  delete_protection = true

  lifecycle {
    prevent_destroy = true
  }
}

# Obsidian Remotely Save (WebDAV). Scoped to obsidian/ so the phone's password can't reach the archive.
resource "hcloud_storage_box_subaccount" "obsidian" {
  storage_box_id = hcloud_storage_box.archive.id
  name           = "obsidian"
  home_directory = "obsidian/"
  password       = var.obsidian_password

  access_settings = {
    reachable_externally = true
    webdav_enabled       = true
    ssh_enabled          = false
    samba_enabled        = false
    readonly             = false
  }
}

# Syncthing hub on the CX33 mounts this over SMB. Scoped to Projects/ so it can't reach the archive or obsidian/.
# Not reachable externally: only Hetzner's network (the CX33) can connect.
resource "hcloud_storage_box_subaccount" "syncthing" {
  storage_box_id = hcloud_storage_box.archive.id
  name           = "syncthing"
  home_directory = "Projects/"
  password       = var.syncthing_password

  access_settings = {
    reachable_externally = false
    samba_enabled        = true
    ssh_enabled          = false
    webdav_enabled       = false
    readonly             = false
  }
}

# Naila (assistant namespace) mounts the Obsidian vault over SMB: same directory as the obsidian WebDAV
# sub-account the devices sync to, separate password, not reachable externally (only the CX33 can connect).
resource "hcloud_storage_box_subaccount" "assistant" {
  storage_box_id = hcloud_storage_box.archive.id
  name           = "assistant"
  home_directory = "obsidian/"
  password       = var.assistant_password

  access_settings = {
    reachable_externally = false
    samba_enabled        = true
    ssh_enabled          = false
    webdav_enabled       = false
    readonly             = false
  }
}
