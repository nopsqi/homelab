#!/usr/bin/env bash
# Usage: tests/render-modes.sh [git-ref]   (default origin/master)
# Renders helm/assistant at <git-ref> and in the working tree, then checks ConfigMap assistant-claude:
#  - the RC keys (CLAUDE.md, agent-*.md) are byte-identical between the two renders;
#  - no harness-* key contains SendMessage, ListAgents, naila-c4 or phone.
set -euo pipefail
ref="${1:-origin/master}"
root="$(git rev-parse --show-toplevel)"
cd "$root"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git archive "$ref" helm/assistant | tar -x -C "$tmp"
helm template "$tmp/helm/assistant" -f "$tmp/helm/assistant/values.yaml" -f "$tmp/helm/assistant/values.prod.yaml" > "$tmp/old.yaml"
helm template helm/assistant -f helm/assistant/values.yaml -f helm/assistant/values.prod.yaml > "$tmp/new.yaml"

python3 - "$tmp/old.yaml" "$tmp/new.yaml" <<'PY'
import sys, yaml

def keys(path):
    for d in yaml.safe_load_all(open(path)):
        if d and d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "assistant-claude":
            return d["data"]
    sys.exit(f"FAIL: ConfigMap assistant-claude not found in {path}")

old, new = keys(sys.argv[1]), keys(sys.argv[2])
rc = sorted(k for k in set(old) | set(new) if k == "CLAUDE.md" or (k.startswith("agent-") and k.endswith(".md")))
bad = []
for k in rc:
    if old.get(k) != new.get(k):
        bad.append(f"RC key {k} differs (or is missing on one side)")
harness = sorted(k for k in new if k.startswith("harness-"))
if not harness:
    bad.append("no harness-* keys in the working-tree render")
for k in harness:
    for w in ("SendMessage", "ListAgents", "naila-c4", "phone"):
        if w in new[k]:
            bad.append(f"{k} contains {w!r}")
if bad:
    print("FAIL:\n  " + "\n  ".join(bad))
    sys.exit(1)
print("RC render identical; harness keys clean")
PY
