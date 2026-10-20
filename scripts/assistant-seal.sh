#!/usr/bin/env bash
# Seal the five assistant secrets for one env from one plaintext env file and print a values.<env>.yaml
# `sealedSecret:` block to paste. The env file never enters git or chat; shred it afterwards.
#   scripts/assistant-seal.sh staging ~/homelab-backups/assistant-staging.env   (KUBECONFIG picked per env)
# Env file keys: OPENROUTER_API_KEY ACTUAL_URL ACTUAL_PASSWORD ACTUAL_SYNC_ID TELEGRAM_BOT_TOKEN TELEGRAM_USER_ID GHCR_USER GHCR_PAT
# GATEWAY_SECRET and INTERNAL_SECRET are generated here (openssl rand) unless present in the file.
set -euo pipefail
env=${1:?staging|prod}; f=${2:?env file}
case $env in staging) export KUBECONFIG=~/.kube/staging-config;; prod) export KUBECONFIG=~/.kube/config;; *) echo "env must be staging|prod"; exit 1;; esac
set -a; . "$f"; set +a
: "${GATEWAY_SECRET:=$(openssl rand -hex 32)}"; : "${INTERNAL_SECRET:=$(openssl rand -hex 32)}"
seal() { # seal <secret-name> KEY=VAL...  → prints "    KEY: blob" lines
  local name=$1; shift; local args=(); for kv in "$@"; do args+=("--from-literal=$kv"); done
  kubectl -n assistant create secret generic "$name" "${args[@]}" --dry-run=client -o yaml \
    | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
    | python3 -c 'import sys,yaml; d=yaml.safe_load(sys.stdin); [print(f"    {k}: {v}") for k,v in d["spec"]["encryptedData"].items()]'
}
echo "sealedSecret:"
printf '  ghcrPull: %s\n' "$(kubectl -n assistant create secret docker-registry ghcr-pull --docker-server=ghcr.io --docker-username="$GHCR_USER" --docker-password="$GHCR_PAT" --dry-run=client -o yaml \
  | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  | python3 -c 'import sys,yaml; print(yaml.safe_load(sys.stdin)["spec"]["encryptedData"][".dockerconfigjson"])')"
echo "  core:";     seal assistant-core-secret     "OPENROUTER_API_KEY=$OPENROUTER_API_KEY" "GATEWAY_SECRET=$GATEWAY_SECRET" "INTERNAL_SECRET=$INTERNAL_SECRET"
echo "  finance:";  seal assistant-finance-secret  "OPENROUTER_API_KEY=$OPENROUTER_API_KEY" "INTERNAL_SECRET=$INTERNAL_SECRET" "ACTUAL_URL=$ACTUAL_URL" "ACTUAL_PASSWORD=$ACTUAL_PASSWORD" "ACTUAL_SYNC_ID=$ACTUAL_SYNC_ID"
echo "  ops:";      seal assistant-ops-secret      "OPENROUTER_API_KEY=$OPENROUTER_API_KEY" "INTERNAL_SECRET=$INTERNAL_SECRET"
echo "  telegram:"; seal assistant-telegram-secret "GATEWAY_SECRET=$GATEWAY_SECRET" "TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN" "TELEGRAM_USER_ID=$TELEGRAM_USER_ID"
