#!/usr/bin/env bash
# Restore local-path PV contents from a tar made of /var/lib/rancher/k3s/storage.
# Directories are named pvc-<uid>_<namespace>_<pvcname>; UIDs change after a rebuild, so
# each old directory is copied into the new directory with the same <namespace>_<pvcname>.
# Run on the node as root: restore-local-path.sh /root/k3s-storage-<date>.tgz
set -euo pipefail
TAR=${1:?tar file}; STORE=/var/lib/rancher/k3s/storage; WORK=/root/restore
mkdir -p "$WORK" && tar xzf "$TAR" -C "$WORK"
for old in "$WORK"/pvc-*; do
  suffix=${old#*_}                       # namespace_pvcname
  new=$(ls -d "$STORE"/pvc-*_"$suffix" 2>/dev/null | head -1 || true)
  if [ -z "$new" ]; then echo "SKIP  $suffix: no new PV directory yet"; continue; fi
  find "$new" -mindepth 1 -delete   # the app may have initialised the empty PV before being scaled down
  cp -a "$old"/. "$new"/ && echo "ok    $suffix -> $(basename "$new") ($(du -sh "$new" | cut -f1))"
done
