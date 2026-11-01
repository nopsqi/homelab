#!/usr/bin/env bash
# Seal the harness pod's three secrets into helm/assistant/values.prod.yaml (sealedSecret.harness).
# Run from the homelab repo root:  KUBECONFIG=~/.kube/config bash helm/assistant/files/seal-harness-secret.sh
# The Discord bot token is read silently; the two internal secrets are generated. Nothing secret is echoed,
# put on argv or written to disk unencrypted. Sealed for secret assistant-harness-secret in namespace assistant
# (strict scope, the same as the other sealedSecret values).
set -euo pipefail
values=helm/assistant/values.prod.yaml
ns=assistant; name=assistant-harness-secret
ctl=(--controller-name sealed-secrets --controller-namespace sealed-secrets)

[ -f "$values" ] || { echo "run from the homelab repo root ($values not found)" >&2; exit 1; }
for c in kubeseal openssl python3 kubectl; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }; done
kubectl get ns "$ns" >/dev/null 2>&1 || { echo "cluster not reachable (check KUBECONFIG)" >&2; exit 1; }
cert=$(kubeseal "${ctl[@]}" --fetch-cert 2>/dev/null) && [ -n "$cert" ] || { echo "cannot fetch the sealed-secrets certificate" >&2; exit 1; }

if [ -t 0 ]; then
  read -rs -p "Discord bot token: " DISCORD_TOKEN >&2 || true; echo >&2
else
  read -r DISCORD_TOKEN || true
fi
[[ $DISCORD_TOKEN =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] \
  || { echo "empty or not a bot token (expected three dot-separated base64url parts)" >&2; exit 1; }
GATEWAY_DISCORD_SECRET=$(openssl rand -hex 32)
CORE_TOOLS_SECRET=$(openssl rand -hex 32)
[ "$GATEWAY_DISCORD_SECRET" != "$CORE_TOOLS_SECRET" ] || { echo "generated secrets are equal" >&2; exit 1; }

seal() { printf '%s' "${!1}" | kubeseal --raw --namespace "$ns" --name "$name" --scope strict --cert <(printf '%s\n' "$cert"); }
enc_discord=$(seal DISCORD_TOKEN)
enc_gateway=$(seal GATEWAY_DISCORD_SECRET)
enc_core=$(seal CORE_TOOLS_SECRET)
unset DISCORD_TOKEN GATEWAY_DISCORD_SECRET CORE_TOOLS_SECRET

ENC_DISCORD=$enc_discord ENC_GATEWAY=$enc_gateway ENC_CORE=$enc_core python3 - "$values" <<'PY'
import os, sys, re
p = sys.argv[1]
lines = open(p, newline="").read().split("\n")
start = next((i for i, l in enumerate(lines) if l.startswith("sealedSecret:")), None)
if start is None:
    sys.exit("no sealedSecret: block in " + p)
end = len(lines)
for i in range(start + 1, len(lines)):
    if lines[i] and not lines[i][0].isspace() and not lines[i].startswith("#"):
        end = i; break
# drop an existing harness entry (indent 2) inside the block
h = next((i for i in range(start + 1, end) if re.match(r"  harness:", lines[i])), None)
if h is not None:
    j = h + 1
    while j < end and (lines[j].startswith("    ") or not lines[j].strip()):
        j += 1
    del lines[h:j]; end -= j - h
ins = end
while ins > start + 1 and not lines[ins - 1].strip():
    ins -= 1
new = ["  harness:",
       "    CORE_TOOLS_SECRET: " + os.environ["ENC_CORE"],
       "    DISCORD_TOKEN: " + os.environ["ENC_DISCORD"],
       "    GATEWAY_DISCORD_SECRET: " + os.environ["ENC_GATEWAY"]]
lines[ins:ins] = new
open(p, "w", newline="").write("\n".join(lines))
PY
unset enc_discord enc_gateway enc_core cert
echo "wrote sealedSecret.harness (DISCORD_TOKEN, GATEWAY_DISCORD_SECRET, CORE_TOOLS_SECRET) to $values"
echo "next: commit and promote; then log in at https://naila.nopsqi.dev/harness"
