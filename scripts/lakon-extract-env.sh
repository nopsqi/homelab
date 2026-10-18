#!/usr/bin/env bash
# One-off for the naila→lakon rename (plan Task 2, Steps 1–3). Reads the live prod secrets and
# writes plaintext env files under ~/homelab-backups (mode 600). Never prints values. Shred after Task 7.
set -euo pipefail
umask 077; mkdir -p ~/homelab-backups
export KUBECONFIG=~/.kube/config
f=~/homelab-backups/lakon-prod.env
kubectl -n naila get secret naila-secret -o json | jq -r '.data | to_entries[] | "\(.key)=\(.value|@base64d)"' > "$f"
kubectl -n naila get secret ghcr-pull -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d \
  | jq -r '.auths["ghcr.io"] | "GHCR_USER=\(.username)\nGHCR_PAT=\(.password)"' > ~/homelab-backups/lakon-ghcr.env
echo "old db host: $(grep -o '@[^/]*' "$f")"
sed -i -e 's/^POSTGRES_USER=.*/POSTGRES_USER=lakon/' -e 's/^POSTGRES_DB=.*/POSTGRES_DB=lakon/' \
  -e 's#^DATABASE_URL=postgres://[^:]*:\([^@]*\)@[^/]*/.*#DATABASE_URL=postgres://lakon:\1@lakon-postgres:5432/lakon#' "$f"
cp "$f" ~/homelab-backups/lakon-staging.env
sed -i "s/^APP_SECRET=.*/APP_SECRET=$(openssl rand -hex 32)/" ~/homelab-backups/lakon-staging.env
echo "keys: $(cut -d= -f1 "$f" | sort | tr '\n' ' ')"
echo "new url shape: $(sed -n 's#^DATABASE_URL=postgres://\([^:]*\):[^@]*@\(.*\)#\1:***@\2#p' "$f")"
echo "required keys: $(grep -cE '^(DATABASE_URL|APP_SECRET|POSTGRES_USER|POSTGRES_PASSWORD|POSTGRES_DB|OPENROUTER_API_KEY|GATEWAY_SECRET)=' "$f") / 7"
ls -l ~/homelab-backups/lakon-*.env | awk '{print $1, $NF}'
