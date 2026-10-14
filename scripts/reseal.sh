#!/usr/bin/env bash
# Seal a secret for the cluster KUBECONFIG points at and print the encryptedData block to paste
# into the chart's values.<env>.yaml. Plaintext comes from an env file (KEY=value per line) that
# never enters git or chat. For a docker registry secret use: --docker <server> <user> <token>.
#   scripts/reseal.sh <namespace> <secret-name> <env-file>
#   scripts/reseal.sh <namespace> <secret-name> --docker ghcr.io <github-user> <pat>
set -euo pipefail
ns=${1:?namespace}; name=${2:?secret name}; shift 2
if [ "${1:-}" = "--docker" ]; then
  manifest=$(kubectl -n "$ns" create secret docker-registry "$name" --docker-server="$2" --docker-username="$3" --docker-password="$4" --dry-run=client -o yaml)
else
  args=(); while IFS='=' read -r k v || [ -n "$k" ]; do [ -z "$k" ] || [[ "$k" == \#* ]] && continue; args+=("--from-literal=$k=$v"); done < "${1:?env file}"
  manifest=$(kubectl -n "$ns" create secret generic "$name" "${args[@]}" --dry-run=client -o yaml)
fi
echo "$manifest" | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  | python3 -c 'import sys,yaml; d=yaml.safe_load(sys.stdin); [print(f"{k}: {v}") for k,v in d["spec"]["encryptedData"].items()]'
