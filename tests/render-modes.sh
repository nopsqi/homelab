#!/usr/bin/env bash
# Usage: tests/render-modes.sh [git-ref]   (default origin/master)
# Renders helm/assistant at <git-ref> and in the working tree, then checks ConfigMap assistant-claude:
#  - the RC keys (CLAUDE.md, agent-*.md) are byte-identical between the two renders;
#  - no harness-*.md key contains SendMessage, ListAgents, naila-c4 or phone, nor the finance write bearer;
#  - harness-settings.json denies the write tools, SendMessage, ListAgents and Agent, and allows the core tools;
#  - the RC checksum ignores a harness-only mode edit and follows an RC one.
set -euo pipefail
ref="${1:-origin/master}"
root="$(git rev-parse --show-toplevel)"
cd "$root"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git archive "$ref" helm/assistant | tar -x -C "$tmp"
helm template "$tmp/helm/assistant" -f "$tmp/helm/assistant/values.yaml" -f "$tmp/helm/assistant/values.prod.yaml" > "$tmp/old.yaml"
helm template helm/assistant -f helm/assistant/values.yaml -f helm/assistant/values.prod.yaml > "$tmp/new.yaml"
# The checksum that restarts the RC lines: unchanged by a harness-only edit, changed by an RC mode edit.
cp -a helm/assistant "$tmp/h" && printf '\nharness-only edit\n' >> "$tmp/h/files/modes/harness/naila.md"
helm template "$tmp/h" -f "$tmp/h/values.yaml" -f "$tmp/h/values.prod.yaml" > "$tmp/harness-edit.yaml"
cp -a helm/assistant "$tmp/r" && printf '\nrc edit\n' >> "$tmp/r/files/modes/rc/naila.md"
helm template "$tmp/r" -f "$tmp/r/values.yaml" -f "$tmp/r/values.prod.yaml" > "$tmp/rc-edit.yaml"

python3 - "$tmp/old.yaml" "$tmp/new.yaml" "$tmp/harness-edit.yaml" "$tmp/rc-edit.yaml" <<'PY'
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
harness = sorted(k for k in new if k.startswith("harness-") and k.endswith(".md"))   # instructions; harness-test.sh denies those tools by name
if not harness:
    bad.append("no harness-* keys in the working-tree render")
for k in harness:
    for w in ("SendMessage", "ListAgents", "naila-c4", "phone"):
        if w in new[k]:
            bad.append(f"{k} contains {w!r}")
import re
WRITES = ["mcp__finance__add_transaction", "mcp__finance__transfer", "mcp__finance__update_transaction",
          "mcp__finance__actual_write", "mcp__finance-notes__write_note"]
want = {"finance-bookkeeper": ({"mcp__core__propose_plan"}, {"mcp__core__ask_worker"}),
        "finance-advisor": ({"mcp__core__propose_plan", "mcp__core__ask_worker"}, set()),
        "ops-oncall": (set(), {"mcp__core__propose_plan", "mcp__core__ask_worker"})}
for name, (has, hasnt) in want.items():
    k = f"harness-agent-{name}.md"
    m = re.search(r"^tools: (.*)$", new.get(k, ""), re.M)
    if not m:
        bad.append(f"{k}: no tools line"); continue
    tools = set(m.group(1).split(", "))
    for t in has - tools: bad.append(f"{k}: tools lack {t}")
    for t in (hasnt | set(WRITES) | {"SendMessage", "ListAgents"}) & tools: bad.append(f"{k}: tools include {t}")
# Harness runs never hold the write bearer: the bookkeeper's `finance` server gets the read-only one (it lists no write tools).
for k in harness:
    if "__MCP_FINANCE_TOKEN__" in new[k]:
        bad.append(f"{k} holds the finance write bearer")
bk = new.get("harness-agent-finance-bookkeeper.md", "")
if not re.search(r'^  - finance:\n(?:      .*\n)*?        Authorization: "Bearer __MCP_FINANCE_READ_TOKEN__"$', bk, re.M):
    bad.append("harness-agent-finance-bookkeeper.md: server `finance` does not use __MCP_FINANCE_READ_TOKEN__")
import json
try:
    hs = json.loads(new.get("harness-settings.json", ""))["permissions"]
except Exception as e:
    hs = None; bad.append(f"harness-settings.json missing or not JSON: {e}")
if hs is not None:
    deny, allow = set(hs.get("deny", [])), set(hs.get("allow", []))
    for t in set(WRITES) | {"SendMessage", "ListAgents", "Agent"}:
        if t not in deny: bad.append(f"harness-settings.json does not deny {t}")
    for t in ("mcp__core__propose_plan", "mcp__core__ask_worker"):
        if t not in allow: bad.append(f"harness-settings.json does not allow {t}")
    for t in allow & (set(WRITES) | {"SendMessage", "ListAgents", "Agent"}): bad.append(f"harness-settings.json allows {t}")
    if hs.get("defaultMode") != "dontAsk": bad.append("harness-settings.json: defaultMode is not dontAsk")
def checksum(path):
    for d in yaml.safe_load_all(open(path)):
        if d and d.get("kind") == "Deployment" and d["metadata"]["name"] == "assistant-claude":
            return d["spec"]["template"]["metadata"]["annotations"]["checksum/config"]
base = checksum(sys.argv[2])
if checksum(sys.argv[3]) != base: bad.append("a harness-only mode edit changes the RC checksum (would restart the RC lines)")
if checksum(sys.argv[4]) == base: bad.append("an RC mode edit leaves the RC checksum unchanged")
if bad:
    print("FAIL:\n  " + "\n  ".join(bad))
    sys.exit(1)
print("RC render identical; harness keys clean")
PY
