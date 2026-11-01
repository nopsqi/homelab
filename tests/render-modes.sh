#!/usr/bin/env bash
# Usage: tests/render-modes.sh [git-ref]   (default origin/master)
# Renders helm/assistant at <git-ref> and in the working tree, then checks ConfigMap assistant-claude:
#  - the RC keys (CLAUDE.md, agent-*.md) are byte-identical between the two renders;
#  - no harness-*.md key contains SendMessage, ListAgents, naila-c4 or phone, nor the finance write bearer;
#  - harness-settings.json denies the write tools, SendMessage, ListAgents and Agent, and allows the core tools;
#  - the RC checksum ignores a harness-only mode edit and follows an RC one.
# Then the assistant-harness pod (harness.enabled, harness.phase):
#  - it renders only when enabled, and enabling it leaves the RC objects as they were;
#  - test phase points at assistant-finance-test and /vault/Harness-test, real phase at assistant-finance and /vault;
#  - the real phase denies //vault/Harness-test/** to the runs (settings patch run as rendered) and sets VAULT_EXCLUDE;
#  - the finance write bearer reaches only the core's env (the harness container's MCP_FINANCE_TOKEN), never another container;
#  - login alerts are per pod, and cloudflared routes naila.nopsqi.dev/harness to the harness login page.
# Then the RC off switch (claude.rcLines, both phases): false stops the RC pod (replicas 0) and drops its login alerts;
#  every other object, the harness pod and its checksum among them, renders exactly as with rcLines true.
# Then the channels (harness.channels): the discord container and the core env render as at <git-ref>, a second channel gets
#  its own container and secrets, bad channel config fails the render, one gateway alert covers every gateway, the harness
#  prompts name no channel, and harness-start.sh unsets every per-channel secret before the core starts.
set -euo pipefail
ref="${1:-origin/master}"
root="$(git rev-parse --show-toplevel)"
cd "$root"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git archive "$ref" helm/assistant | tar -x -C "$tmp"
# harness off: a ref that already has the harness pod compares like one that predates it
helm template "$tmp/helm/assistant" -f "$tmp/helm/assistant/values.yaml" -f "$tmp/helm/assistant/values.prod.yaml" --set harness.phase=test --set claude.rcLines=true --set harness.enabled=false > "$tmp/old.yaml"
helm template helm/assistant -f helm/assistant/values.yaml -f helm/assistant/values.prod.yaml --set harness.phase=test --set claude.rcLines=true > "$tmp/new.yaml"
# The checksum that restarts the RC lines: unchanged by a harness-only edit, changed by an RC mode edit.
cp -a helm/assistant "$tmp/h" && printf '\nharness-only edit\n' >> "$tmp/h/files/modes/harness/naila.md"
helm template "$tmp/h" -f "$tmp/h/values.yaml" -f "$tmp/h/values.prod.yaml" --set harness.phase=test --set claude.rcLines=true > "$tmp/harness-edit.yaml"
cp -a helm/assistant "$tmp/r" && printf '\nrc edit\n' >> "$tmp/r/files/modes/rc/naila.md"
helm template "$tmp/r" -f "$tmp/r/values.yaml" -f "$tmp/r/values.prod.yaml" --set harness.phase=test --set claude.rcLines=true > "$tmp/rc-edit.yaml"
# The harness pod: off, test phase, real phase, staging values. Every render from values.prod.yaml pins the test phase with
# the RC lines on, whatever prod runs now (real since 2026-11-01); the real phase and rcLines=false are set where checked.
P=(-f helm/assistant/values.yaml -f helm/assistant/values.prod.yaml --set harness.phase=test --set claude.rcLines=true)
helm template helm/assistant "${P[@]}" --set harness.enabled=false > "$tmp/off.yaml"
helm template helm/assistant "${P[@]}" --set harness.phase=real > "$tmp/real.yaml"
helm template helm/assistant "${P[@]}" --set claude.rcLines=false > "$tmp/test-rcoff.yaml"
helm template helm/assistant "${P[@]}" --set harness.phase=real --set claude.rcLines=false > "$tmp/real-rcoff.yaml"
helm template helm/assistant -f helm/assistant/values.yaml -f helm/assistant/values.staging.yaml > "$tmp/staging.yaml"
helm template helm/cloudflared -f helm/cloudflared/values.yaml > "$tmp/cloudflared.yaml"
# The channels: the ref with the harness on (as the working tree's test-phase render), and a second channel next to discord.
helm template "$tmp/helm/assistant" -f "$tmp/helm/assistant/values.yaml" -f "$tmp/helm/assistant/values.prod.yaml" --set harness.phase=test --set claude.rcLines=true > "$tmp/old-harness.yaml"
helm template helm/assistant "${P[@]}" --set-json 'harness.channels.telegram={"enabled":true,"label":"Telegram","settle":"reject","secretKey":"GATEWAY_TELEGRAM_SECRET","gateway":{"uid":1003,"env":{"TELEGRAM_CHAT":"-100123"},"secretEnv":{"TELEGRAM_TOKEN":"TELEGRAM_TOKEN"}}}' > "$tmp/two.yaml"
# The harness checksum follows what harness-start.sh takes from the RC ConfigMap: settings.json, direct-lines, finance-test-note.
cp -a helm/assistant "$tmp/s" && sed -i 's/"mcp__claude_ai_Gmail"/"mcp__claude_ai_GmailX"/' "$tmp/s/templates/claude.yaml"
cp -a helm/assistant "$tmp/d" && sed -i 's/^    {{ .name }} {{ .model }}$/    {{ .name }}  {{ .model }}/' "$tmp/d/templates/claude.yaml"
cp -a helm/assistant "$tmp/n" && sed -i 's/made for this\./made for this, really./' "$tmp/n/templates/claude.yaml"
for v in s d n; do helm template "$tmp/$v" -f "$tmp/$v/values.yaml" -f "$tmp/$v/values.prod.yaml" --set harness.phase=test --set claude.rcLines=true > "$tmp/$v.yaml"; done

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

python3 - "$tmp/old.yaml" "$tmp/off.yaml" "$tmp/new.yaml" "$tmp/real.yaml" "$tmp/staging.yaml" "$tmp/cloudflared.yaml" "$tmp/s.yaml" "$tmp/d.yaml" "$tmp/n.yaml" <<'PY'
import sys, yaml, re
def load(p): return {(d["kind"], d["metadata"]["name"]): d for d in yaml.safe_load_all(open(p)) if d}
old, off, test, real, staging = (load(p) for p in sys.argv[1:6])
bad = []
H = ("Deployment", "assistant-harness")

# harness pod renders only when enabled
for kind, name in [H, ("PersistentVolumeClaim", "assistant-harness-home"), ("Service", "assistant-harness-login"), ("NetworkPolicy", "assistant-harness"),
                   ("ServiceMonitor", "assistant-harness-login"), ("PrometheusRule", "assistant-harness-login"), ("ConfigMap", "assistant-harness")]:
    if (kind, name) not in test: bad.append(f"harness pod renders only when enabled: {kind}/{name} missing with harness.enabled")
for label, r in (("harness.enabled=false", off), ("staging values", staging)):
    for k in r:
        if k[1].startswith("assistant-harness"): bad.append(f"harness pod renders only when enabled: {k[0]}/{k[1]} renders with {label}")

def pod(r): return r[H]["spec"]["template"]["spec"] if H in r else {"containers": [], "initContainers": [], "volumes": []}
def ctr(r, n): return next((c for c in pod(r)["containers"] if c["name"] == n), {"env": [], "volumeMounts": []})
def env(c): return {e["name"]: e for e in c.get("env", [])}
def val(c, k): return env(c).get(k, {}).get("value")
def key(c, k): return ((env(c).get(k, {}).get("valueFrom") or {}).get("secretKeyRef") or {}).get("key")
def allenv(r): return [(c["name"], e) for c in pod(r)["containers"] + pod(r).get("initContainers", []) for e in c.get("env", [])]
def admits(np, app): return any(f.get("podSelector", {}).get("matchLabels", {}).get("app") == app for rule in np["spec"].get("ingress", []) for f in rule.get("from", []))
def egress_apps(np): return {f["podSelector"]["matchLabels"]["app"] for rule in np["spec"].get("egress", []) for f in rule.get("to", []) if "podSelector" in f}

phases = {"test": dict(r=test, url="http://assistant-finance-test:8080/mcp", root="/vault/Harness-test", notes="/vault/Harness-test/Finance",
                       view="/vault/Harness-test/Naila/Decisions.md", write="MCP_FINANCE_TEST_TOKEN", read="MCP_FINANCE_TEST_READ_TOKEN",
                       server="assistant-finance-test", other="assistant-finance"),
          "real": dict(r=real, url="http://assistant-finance:8080/mcp", root="/vault", notes="/vault/Finance",
                       view="/vault/Naila/Decisions.md", write="MCP_FINANCE_TOKEN", read="MCP_FINANCE_READ_TOKEN",
                       server="assistant-finance", other="assistant-finance-test")}
for ph, x in phases.items():
    r, h = x["r"], ctr(x["r"], "harness")
    tag = f"{ph} phase points at {x['server']} and {x['root']}"
    for k, want in (("HARNESS_PHASE", ph), ("MCP_FINANCE_URL", x["url"]), ("VAULT_ROOT", x["root"]), ("FINANCE_NOTES_ROOT", x["notes"]),
                    ("VIEW_FILE", x["view"]), ("HARNESS_HOME", "/home/claude/.claude/harness"), ("MAX_CONCURRENT_RUNS", "2")):
        if val(h, k) != want: bad.append(f"{tag}: harness {k} is {val(h, k)!r}, want {want!r}")
    if key(h, "MCP_FINANCE_TOKEN") != x["write"]: bad.append(f"{tag}: core MCP_FINANCE_TOKEN comes from {key(h, 'MCP_FINANCE_TOKEN')!r}, want {x['write']!r}")
    if key(h, "MCP_FINANCE_READ_TOKEN") != x["read"]: bad.append(f"{tag}: MCP_FINANCE_READ_TOKEN comes from {key(h, 'MCP_FINANCE_READ_TOKEN')!r}, want {x['read']!r}")
    if val(ctr(r, "docs"), "DOCS_ROOTS") != f"/home/claude/.claude/uploads:{x['root']}": bad.append(f"{tag}: docs DOCS_ROOTS is {val(ctr(r, 'docs'), 'DOCS_ROOTS')!r}")
    for c in pod(r)["containers"]:
        for m in c.get("volumeMounts", []):
            if m["name"] == "vault" and (m["mountPath"] != x["root"] or (ph == "test" and not m.get("subPath", "").endswith("Harness-test"))):
                bad.append(f"{tag}: {c['name']} mounts the vault at {m['mountPath']} (subPath {m.get('subPath')!r})")
    other_keys = {"test": {"MCP_FINANCE_TOKEN", "MCP_FINANCE_READ_TOKEN"}, "real": {"MCP_FINANCE_TEST_TOKEN", "MCP_FINANCE_TEST_READ_TOKEN"}}[ph]
    for cn, e in allenv(r):
        if ph == "test" and "assistant-finance:" in str(e.get("value", "")): bad.append(f"{tag}: {cn} env {e['name']} names assistant-finance:")
        k = ((e.get("valueFrom") or {}).get("secretKeyRef") or {}).get("key")
        if k in other_keys: bad.append(f"{tag}: {cn} env {e['name']} holds {k}, the other phase's bearer")
    np = r.get(("NetworkPolicy", "assistant-harness"))
    if np:
        if egress_apps(np) != {x["server"], "assistant-ops"}: bad.append(f"{tag}: harness egress reaches {sorted(egress_apps(np))}")
        for s in (x["server"], "assistant-ops"):
            if not admits(r[("NetworkPolicy", s)], "assistant-harness"): bad.append(f"{tag}: NetworkPolicy {s} does not admit assistant-harness")
        if admits(r[("NetworkPolicy", x["other"])], "assistant-harness"): bad.append(f"{tag}: NetworkPolicy {x['other']} admits assistant-harness")
    reps = r[("Deployment", "assistant-finance-test")]["spec"].get("replicas")
    if reps != (1 if ph == "test" else None): bad.append(f"{tag}: assistant-finance-test replicas {reps!r}")

    # the harness pod never holds a worker write bearer outside the core env
    tag = f"the harness pod never holds a worker write bearer outside the core env ({ph})"
    for c in pod(r)["containers"] + pod(r).get("initContainers", []):
        if c.get("envFrom"): bad.append(f"{tag}: {c['name']} has envFrom")
        for e in c.get("env", []):
            ref = (e.get("valueFrom") or {}).get("secretKeyRef") or {}
            k, sec = ref.get("key", ""), ref.get("name")
            if not ref: continue
            if c["name"] != "harness" and (k.startswith("MCP_") or k == "CORE_TOOLS_SECRET"): bad.append(f"{tag}: {c['name']} env {e['name']} holds {k}")
            if c["name"] == "harness" and k == x["write"] and e["name"] != "MCP_FINANCE_TOKEN": bad.append(f"{tag}: the write bearer also as {e['name']}")
    if "discord:$(GATEWAY_DISCORD_SECRET)" not in (val(h, "GATEWAY_SECRETS") or "").split(","): bad.append(f"{tag}: GATEWAY_SECRETS is {val(h, 'GATEWAY_SECRETS')!r}")
    if key(ctr(r, "discord"), "GATEWAY_SECRET") != "GATEWAY_DISCORD_SECRET": bad.append(f"{tag}: discord GATEWAY_SECRET from {key(ctr(r, 'discord'), 'GATEWAY_SECRET')!r}")
    # uids: the shared process namespace opens /proc/<pid>/{environ,root} to the same uid, so only harness and login run as 1000
    # (init containers finish before any of them start); the gateway is 1002 in group 1000, writing into a setgid 2770 folder.
    psc = pod(r).get("securityContext", {})
    uid = lambda c: c.get("securityContext", {}).get("runAsUser", psc.get("runAsUser"))
    dsc = ctr(r, "discord").get("securityContext", {})
    if (dsc.get("runAsUser"), dsc.get("runAsGroup")) != (1002, 1000): bad.append(f"discord container runs as {dsc.get('runAsUser')}:{dsc.get('runAsGroup')}, want 1002:1000 ({ph})")
    for c in pod(r)["containers"]:
        if c["name"] not in ("harness", "login") and uid(c) == 1000: bad.append(f"{c['name']} runs as uid 1000, the core's uid ({ph})")
    init = " ".join(" ".join(c.get("command", [])) for c in pod(r).get("initContainers", []))
    if "chmod 2770 /home/claude/.claude/uploads/discord" not in init or "chmod 750 /home/claude/.claude/uploads " not in init:
        bad.append(f"uploads/discord is not created setgid group-writable (2770) under a group-traversable uploads/ (750) ({ph})")
    lg = ctr(r, "login")
    for k, want in (("BASE_PATH", "/harness"), ("POD_ROLE", "harness"), ("RESTART_MATCH", "harness/dist/main.js")):
        if val(lg, k) != want: bad.append(f"login sidecar {k} is {val(lg, k)!r}, want {want!r} ({ph})")
    req = 0
    for c in pod(r)["containers"]:
        m = c.get("resources", {}).get("requests", {}).get("memory", "0Mi"); req += int(m.rstrip("Mi"))
    if not pod(r)["containers"] or req > 512: bad.append(f"harness pod memory requests {req}Mi (want <= 512Mi) ({ph})")
    if h.get("resources", {}).get("limits", {}).get("memory") != "1536Mi": bad.append(f"harness container memory limit {h.get('resources', {}).get('limits', {}).get('memory')!r} ({ph})")
start = (test.get(("ConfigMap", "assistant-harness")) or {}).get("data", {}).get("harness-start.sh", "")
# The real phase's runs can't see the test folder (Ruling 29): harness-start.sh's settings patch, run as rendered for each
# phase, denies //vault/Harness-test/** in the real phase only, and the vault servers get VAULT_EXCLUDE=Harness-test there.
import os, shlex, subprocess, tempfile
def patched_settings(r, ph):
    data = {**r[("ConfigMap", "assistant-claude")]["data"], **r[("ConfigMap", "assistant-harness")]["data"]}
    m = re.search(r"^# Settings:.*?^node -e '(.*?)' (/config/settings\.json[^\n]*)$", data["harness-start.sh"], re.M | re.S)
    if not m: return None, "harness-start.sh: settings patch not found"
    d = tempfile.mkdtemp()
    vars_ = {k: (e.get("value") or "") for k, e in env(ctr(r, "harness")).items()}
    vars_.update(C=d, HARNESS_PHASE=ph, HOME=d)
    def expand(a):
        a = re.sub(r"\$\{(\w+)(?::-[^}]*)?\}|\$(\w+)", lambda x: vars_.get(x.group(1) or x.group(2), ""), a)
        if a.startswith("/config/"):
            f = os.path.join(d, a[len("/config/"):]); open(f, "w").write(data[a[len("/config/"):]]); return f
        return a
    args = [expand(a) for a in shlex.split(m.group(2))]
    out = os.path.join(d, "settings.json")
    p = subprocess.run(["node", "-e", m.group(1), *args], capture_output=True, text=True)
    if p.returncode != 0: return None, f"settings patch failed ({ph}): {p.stderr.strip()}"
    return json.loads(open(out).read()), None
import json
for ph, r in (("test", test), ("real", real)):
    s, err = patched_settings(r, ph)
    if err: bad.append(err); continue
    denied = "Read(//vault/Harness-test/**)" in s["permissions"]["deny"]
    if ph == "real" and not denied: bad.append("real phase: the runs' settings do not deny Read(//vault/Harness-test/**)")
    if ph == "test" and denied: bad.append("test phase: the runs' settings deny Read(//vault/Harness-test/**), their own vault")
    hook = " ".join(h["command"] for e in s.get("hooks", {}).get("PreToolUse", []) if "docs" in e.get("matcher", "") for h in e["hooks"])
    if ph == "real" and "--exclude /vault/Harness-test" not in hook: bad.append(f"real phase: the docs hook does not exclude /vault/Harness-test: {hook}")
    if ph == "test" and "--exclude" in hook: bad.append(f"test phase: the docs hook excludes a folder: {hook}")
    want = "Harness-test" if ph == "real" else None
    if val(ctr(r, "harness"), "VAULT_EXCLUDE") != want: bad.append(f"{ph} phase: harness VAULT_EXCLUDE is {val(ctr(r, 'harness'), 'VAULT_EXCLUDE')!r}, want {want!r}")
chk = re.search(r'^if \[ -n "\$\{VAULT_EXCLUDE:-\}" \] && ! grep -qF .*$', start, re.M)
if not chk: bad.append("harness-start.sh: no check that the vault server honours VAULT_EXCLUDE")
else:
    d = tempfile.mkdtemp(); srv = os.path.join(d, "server.js")
    def check(body, exclude):
        open(srv, "w").write(body)
        return subprocess.run(["bash", "-c", 'die() { echo "$*" >&2; exit 2; }; VAULT_SERVER=$1; VAULT_EXCLUDE=$2; ' + chk.group(0), "x", srv, exclude], capture_output=True, text=True).returncode
    if check("old image", "Harness-test") == 0: bad.append("harness-start.sh: starts with VAULT_EXCLUDE set although the vault server lacks support")
    if check("console.error(`vault-mcp: VAULT_EXCLUDE supported; leaving out ${x}`)", "Harness-test") != 0: bad.append("harness-start.sh: refuses a vault server that supports VAULT_EXCLUDE")
    if check("old image", "") != 0: bad.append("harness-start.sh: the test phase (no VAULT_EXCLUDE) needs the support marker")
if not (re.search(r'^\[ -z "\$\{VAULT_EXCLUDE:-\}" \] \|\| vault_env\+=\(-e VAULT_EXCLUDE="\$VAULT_EXCLUDE"\)', start, re.M) and re.search(r'^claude mcp add vault [^\n]*"\$\{vault_env\[@\]\}"', start, re.M)): bad.append("harness-start.sh: the runs' vault server does not get VAULT_EXCLUDE")

if not re.search(r"^unset .*MCP_FINANCE_READ_TOKEN", start, re.M):   # the gateway secrets: see the channel checks below
    bad.append("the harness pod never holds a worker write bearer outside the core env: harness-start.sh does not unset the read bearer before the core starts")

# RC render identical: with the harness off, everything equals the ref render, except the RC ConfigMap (its RC keys are checked
# above) and checksum, and the RC login alerts (scoped per pod); enabling the harness changes only the finance/ops policies and finance-test's replicas.
def strip(d):
    d = yaml.safe_load(yaml.safe_dump(d))
    if d["kind"] == "Deployment" and d["metadata"]["name"] == "assistant-claude": d["spec"]["template"]["metadata"]["annotations"].pop("checksum/config", None)
    return d
for k in sorted(set(old) | set(off)):
    if k in (("ConfigMap", "assistant-claude"), ("PrometheusRule", "assistant-login")) or k[1].startswith("assistant-harness"): continue   # a ref with the harness on
    if k not in old or k not in off or strip(old[k]) != strip(off[k]): bad.append(f"RC render identical: {k[0]}/{k[1]} differs from the ref render with the harness off")
changes = {("Deployment", "assistant-finance-test"), ("NetworkPolicy", "assistant-finance"), ("NetworkPolicy", "assistant-finance-test"), ("NetworkPolicy", "assistant-ops")}
for label, r in (("test", test), ("real", real)):
    for k in off:
        if k not in changes and off[k] != r.get(k): bad.append(f"RC render identical: {k[0]}/{k[1]} changes when the harness is on ({label})")

# the RC ConfigMap keys harness-start.sh reads are unchanged from the ref, and the harness checksum follows each of them
for k in ("settings.json", "direct-lines", "finance-test-note"):
    if old[("ConfigMap", "assistant-claude")]["data"].get(k) != off[("ConfigMap", "assistant-claude")]["data"].get(k): bad.append(f"RC render identical: ConfigMap key {k} differs from the ref render")
hsum = lambda r: r[H]["spec"]["template"]["metadata"]["annotations"]["checksum/config"] if H in r else None
csum = lambda r: r[("Deployment", "assistant-claude")]["spec"]["template"]["metadata"]["annotations"]["checksum/config"]
for path, what in zip(sys.argv[7:10], ("settings.json", "direct-lines", "finance-test-note")):
    e = load(path)
    if e[("ConfigMap", "assistant-claude")]["data"].get(what) == test[("ConfigMap", "assistant-claude")]["data"].get(what): bad.append(f"checksum test: the {what} edit did not change the key")
    if hsum(e) == hsum(test): bad.append(f"the harness checksum ignores a {what} edit (the core would keep the old config)")
# the harness pod's 443 egress skips private, tailnet (CGNAT) and link-local ranges
np = test.get(("NetworkPolicy", "assistant-harness"))
exc = {x for rule in (np or {"spec": {}})["spec"].get("egress", []) for t in rule.get("to", []) for x in t.get("ipBlock", {}).get("except", [])}
for c in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16"):
    if c not in exc: bad.append(f"harness 443 egress does not exclude {c}")
# login alerts per pod
def rules(r, n): return {x["alert"]: x["expr"] for g in (r.get(("PrometheusRule", n)) or {"spec": {"groups": []}})["spec"]["groups"] for x in g["rules"]}
rc, hr = rules(test, "assistant-login"), rules(test, "assistant-harness-login")
for a, e in rc.items():
    if 'job="assistant-login"' not in e: bad.append(f"login alerts per pod: RC alert {a} is not scoped to job=\"assistant-login\": {e}")
if not any(e.startswith("absent(") for e in rc.values()): bad.append("login alerts per pod: no absent() rule for the RC login metrics")
if any("token_expiry" in e for e in hr.values()): bad.append("login alerts per pod: the harness pod has a token-expiry rule (nothing long-running renews its token: Ruling 16)")
for want in ("naila_claude_logged_in", "naila_remote_control_up", "absent("):
    if not any(want in e and 'job="assistant-harness-login"' in e for e in hr.values()): bad.append(f"login alerts per pod: no harness rule on {want}")

# cloudflared: /harness on naila.nopsqi.dev goes to the harness login page, before the host's catch-all rule
cf = next(d for d in yaml.safe_load_all(open(sys.argv[6])) if d and d["kind"] == "ConfigMap")
ing = yaml.safe_load(next(iter(cf["data"].values())))["ingress"]
naila = [(i, x) for i, x in enumerate(ing) if x.get("hostname") == "naila.nopsqi.dev"]
hp = [(i, x) for i, x in naila if "harness" in x.get("path", "")]
if not hp or hp[0][1]["service"] != "http://assistant-harness-login.assistant.svc.cluster.local:8080" or not hp[0][1].get("originRequest", {}).get("access", {}).get("required"):
    bad.append("cloudflared: no Access-enforced naila.nopsqi.dev /harness rule to assistant-harness-login")
elif min(i for i, x in naila if "path" not in x) < hp[0][0]: bad.append("cloudflared: the /harness rule comes after the naila.nopsqi.dev catch-all")
if bad:
    print("FAIL:\n  " + "\n  ".join(bad)); sys.exit(1)
print("harness pod: renders only when enabled; phases wired; write bearer only in the core env; RC render identical")
PY

python3 - "$tmp/new.yaml" "$tmp/test-rcoff.yaml" "$tmp/real.yaml" "$tmp/real-rcoff.yaml" <<'PY'
import sys, yaml, copy
def load(p): return {(d["kind"], d["metadata"]["name"]): d for d in yaml.safe_load_all(open(p)) if d}
bad = []
RC, RULE = ("Deployment", "assistant-claude"), ("PrometheusRule", "assistant-login")
for ph, on, off in (("test", load(sys.argv[1]), load(sys.argv[2])), ("real", load(sys.argv[3]), load(sys.argv[4]))):
    tag = f"RC off switch ({ph} phase)"
    if on[RC]["spec"].get("replicas") != 1: bad.append(f"{tag}: rcLines true renders assistant-claude with replicas {on[RC]['spec'].get('replicas')!r}, want 1")
    if RC not in off: bad.append(f"{tag}: rcLines false drops the assistant-claude Deployment (keep it at replicas 0)"); continue
    if off[RC]["spec"].get("replicas") != 0: bad.append(f"{tag}: rcLines false renders assistant-claude with replicas {off[RC]['spec'].get('replicas')!r}, want 0")
    if RULE not in on: bad.append(f"{tag}: rcLines true has no RC login alerts")
    if RULE in off: bad.append(f"{tag}: rcLines false still renders the RC login alerts (a stopped RC pod would page)")
    a, b = copy.deepcopy(on[RC]), copy.deepcopy(off[RC])
    a["spec"].pop("replicas", None); b["spec"].pop("replicas", None)
    if a != b: bad.append(f"{tag}: the assistant-claude Deployment differs beyond replicas")
    for k in sorted(set(on) | set(off)):
        if k in (RC, RULE): continue
        if k not in off: bad.append(f"{tag}: rcLines false drops {k[0]}/{k[1]}")
        elif k not in on: bad.append(f"{tag}: rcLines false adds {k[0]}/{k[1]}")
        elif on[k] != off[k]: bad.append(f"{tag}: {k[0]}/{k[1]} changes with rcLines")
    H = ("Deployment", "assistant-harness")
    if H not in off or on[H]["spec"]["template"]["metadata"]["annotations"]["checksum/config"] != off[H]["spec"]["template"]["metadata"]["annotations"]["checksum/config"]:
        bad.append(f"{tag}: the harness checksum changes with rcLines (an RC stop would restart the harness)")
if bad:
    print("FAIL:\n  " + "\n  ".join(bad)); sys.exit(1)
print("RC off switch: replicas 0 and no RC login alerts; everything else identical, harness checksum unchanged")
PY

python3 - "$ref" "$tmp/old-harness.yaml" "$tmp/new.yaml" "$tmp/real.yaml" "$tmp/two.yaml" <<'PY'
import sys, yaml, re, json, subprocess
ref = sys.argv[1]
def load(p): return {(d["kind"], d["metadata"]["name"]): d for d in yaml.safe_load_all(open(p)) if d}
oldh, test, real, two = (load(p) for p in sys.argv[2:6])
H = ("Deployment", "assistant-harness")
bad = []
def pod(r): return r[H]["spec"]["template"]["spec"] if H in r else {"containers": [], "initContainers": []}
def ctr(r, n): return next((c for c in pod(r)["containers"] if c["name"] == n), None)
def envmap(c): return {e["name"]: e for e in (c or {}).get("env", [])}
def envset(c): return {(e["name"], json.dumps(e.get("value")), json.dumps(e.get("valueFrom"), sort_keys=True)) for e in (c or {}).get("env", [])}
def val(c, k): return (envmap(c).get(k) or {}).get("value")
def key(c, k): return (((envmap(c).get(k) or {}).get("valueFrom") or {}).get("secretKeyRef") or {}).get("key")
def entries(c): return (val(c, "GATEWAY_SECRETS") or "").split(",")
def channels(c):
    try: v = json.loads(val(c, "HARNESS_CHANNELS") or "")
    except ValueError: return None
    return v if isinstance(v, list) else None
def compact(d): return json.dumps(d, separators=(",", ":"))

tag = f"channel loop: the discord container renders as at {ref}"
o, n = ctr(oldh, "discord"), ctr(test, "discord")
if o is None or n is None: bad.append(f"{tag}: no discord container ({'at the ref' if o is None else 'now'})")
else:
    if envset(o) != envset(n): bad.append(f"{tag}: env differs: only at the ref {sorted(envset(o) - envset(n))}, only now {sorted(envset(n) - envset(o))}")
    for k in ("volumeMounts", "securityContext", "command"):
        if o.get(k) != n.get(k): bad.append(f"{tag}: {k} is {n.get(k)!r}, was {o.get(k)!r}")

tag = f"channel loop: the core env holds every variable it held at {ref} with the same value, except GATEWAY_SECRETS, which contains the entry discord:$(GATEWAY_DISCORD_SECRET)"
oe, ne = envmap(ctr(oldh, "harness")), envmap(ctr(test, "harness"))
for k, e in oe.items():
    if k in ("GATEWAY_SECRETS", "HARNESS_CHANNELS"): continue   # HARNESS_CHANNELS: checked by containment below (R9)
    if ne.get(k) != e: bad.append(f"{tag}: {k} is {ne.get(k)!r}, was {e!r}")
if "discord:$(GATEWAY_DISCORD_SECRET)" not in entries(ctr(test, "harness")): bad.append(f"{tag}: GATEWAY_SECRETS is {val(ctr(test, 'harness'), 'GATEWAY_SECRETS')!r}")
for label, r in (("test", test), ("real", real), ("two channels", two)):   # $(VAR) expands only from a variable defined earlier
    names = [e["name"] for e in (ctr(r, "harness") or {}).get("env", [])]
    before = names[:names.index("GATEWAY_SECRETS")] if "GATEWAY_SECRETS" in names else []
    for v in re.findall(r"\$\((\w+)\)", val(ctr(r, "harness"), "GATEWAY_SECRETS") or ""):
        if v not in before: bad.append(f"channel loop: GATEWAY_SECRETS names $({v}) before it is defined ({label})")

want = {"label": "Discord", "name": "discord", "settle": "approve"}
for label, r in (("test", test), ("real", real), ("two channels", two)):
    if want not in (channels(ctr(r, "harness")) or []): bad.append(f"HARNESS_CHANNELS contains {compact(want)}: it is {val(ctr(r, 'harness'), 'HARNESS_CHANNELS')!r} ({label})")

tag = "a second channel gets its own container, secret env and GATEWAY_SECRETS entry and no Discord env"
t, th = ctr(two, "telegram"), ctr(two, "harness")
if t is None: bad.append(f"{tag}: no telegram container")
else:
    if t.get("command") != ["node", "packages/channels/telegram/dist/main.js"]: bad.append(f"{tag}: telegram command is {t.get('command')!r}")
    for k, w in (("GATEWAY_SECRET", "GATEWAY_TELEGRAM_SECRET"), ("TELEGRAM_TOKEN", "TELEGRAM_TOKEN")):
        if key(t, k) != w: bad.append(f"{tag}: telegram {k} comes from {key(t, k)!r}, want {w!r}")
    for k, w in (("CORE_URL", "http://127.0.0.1:3100"), ("TELEGRAM_CHAT", "-100123")):
        if val(t, k) != w: bad.append(f"{tag}: telegram {k} is {val(t, k)!r}, want {w!r}")
    if [k for k in envmap(t) if "DISCORD" in k]: bad.append(f"{tag}: telegram env has {[k for k in envmap(t) if 'DISCORD' in k]}")
    if "HARNESS_UPLOADS" in envmap(t) or t.get("volumeMounts"): bad.append(f"{tag}: telegram (no uploads) gets HARNESS_UPLOADS or a mount")
    sc = t.get("securityContext", {})
    if (sc.get("runAsUser"), sc.get("runAsGroup"), sc.get("readOnlyRootFilesystem"), sc.get("allowPrivilegeEscalation")) != (1003, 1000, True, False):
        bad.append(f"{tag}: telegram securityContext is {sc!r}")
if key(th, "GATEWAY_TELEGRAM_SECRET") != "GATEWAY_TELEGRAM_SECRET": bad.append(f"{tag}: the core's GATEWAY_TELEGRAM_SECRET comes from {key(th, 'GATEWAY_TELEGRAM_SECRET')!r}")
for e in ("discord:$(GATEWAY_DISCORD_SECRET)", "telegram:$(GATEWAY_TELEGRAM_SECRET)"):
    if e not in entries(th): bad.append(f"{tag}: GATEWAY_SECRETS lacks {e}: {val(th, 'GATEWAY_SECRETS')!r}")
tw = {"label": "Telegram", "name": "telegram", "settle": "reject"}
if tw not in (channels(th) or []): bad.append(f"{tag}: HARNESS_CHANNELS lacks {compact(tw)}: {val(th, 'HARNESS_CHANNELS')!r}")
if ctr(two, "discord") != ctr(test, "discord"): bad.append(f"{tag}: the discord container changes when telegram is added")

tag = "a missing secretKey, an unknown settle, a failing check and test with approve in the real phase each fail the render"
P = ["helm", "template", "helm/assistant", "-f", "helm/assistant/values.yaml", "-f", "helm/assistant/values.prod.yaml", "--set", "claude.rcLines=true"]
def render(*a): return subprocess.run(P + list(a), capture_output=True, text=True)
T = lambda settle: ["--set-json", 'harness.channels.test={"enabled":true,"label":"test","settle":"%s","secretKey":"GATEWAY_TEST_SECRET"}' % settle]
for what, args, msg in (("a missing secretKey", ["--set", "harness.channels.discord.secretKey=null"], "harness.channels.discord.secretKey"),
                        ("an unknown settle", ["--set", "harness.channels.discord.settle=maybe"], "harness.channels.discord.settle"),
                        ("a failing check", ["--set", "harness.channels.discord.gateway.env.DISCORD_GUILD_ID=123"], "DISCORD_GUILD_ID"),
                        ("test with approve in the real phase", ["--set", "harness.phase=real", *T("approve")], "may not approve"),
                        ("no channel enabled", ["--set", "harness.channels.discord.enabled=false"], "no channel"),
                        ("a bad name", ["--set-json", 'harness.channels.Ops_x={"enabled":true,"label":"x","settle":"none","secretKey":"K"}'], "Ops_x")):
    p = render("--set", "harness.phase=test", *args)
    if p.returncode == 0: bad.append(f"{tag}: {what} renders")
    elif msg not in p.stderr: bad.append(f"{tag}: {what} fails for another reason: {p.stderr.strip()[-300:]}")
for what, args in (("test with reject in the real phase", ["--set", "harness.phase=real", *T("reject")]),
                   ("test with approve in the test phase", ["--set", "harness.phase=test", *T("approve")])):
    p = render(*args)
    if p.returncode != 0: bad.append(f"{tag}: {what} does not render: {p.stderr.strip()[-300:]}")

tag = "one NailaGatewayRestarting rule covers every gateway container; no alert text names Discord"
for label, r, gws in (("prod", test, {"discord"}), ("two channels", two, {"discord", "telegram"})):
    rs = [x for g in (r.get(("PrometheusRule", "assistant-harness-login")) or {"spec": {"groups": []}})["spec"]["groups"] for x in g["rules"]]
    gr = [x for x in rs if x["alert"] == "NailaGatewayRestarting"]
    if len(gr) != 1: bad.append(f"{tag}: {len(gr)} NailaGatewayRestarting rules ({label})")
    else:
        m = re.search(r'container=~"([^"]*)"', gr[0]["expr"])
        if not m or set(m.group(1).split("|")) != gws or "restarts" not in gr[0]["expr"]: bad.append(f"{tag}: expr {gr[0]['expr']!r} ({label})")
        if "{{ $labels.container }}" not in gr[0]["annotations"].get("summary", ""): bad.append(f"{tag}: the summary does not name {{{{ $labels.container }}}} ({label})")
    for x in rs:
        if x["alert"] != "NailaGatewayRestarting" and "restarts" in x["expr"]: bad.append(f"{tag}: {x['alert']} also counts restarts ({label})")
        for k, v in x.get("annotations", {}).items():
            if "discord" in v.lower(): bad.append(f"{tag}: {x['alert']} {k} names Discord ({label})")
    lo = next((x for x in rs if x["alert"] == "NailaHarnessLoggedOut"), {})
    if not lo.get("annotations", {}).get("description", "").startswith("The workers can't answer."): bad.append(f"{tag}: NailaHarnessLoggedOut says {lo.get('annotations', {}).get('description')!r}")

tag = "harness prompts name no channel"
for f in ("naila.md", "naila.channel.md", "finance-advisor.md", "finance-advisor.notes.md", "finance-bookkeeper.md"):
    s = open(f"helm/assistant/files/modes/harness/{f}").read()
    for pat in (r"#decisions", r"discord", r"\btap\b", r"\bbutton"):
        if re.search(pat, s, re.I): bad.append(f"{tag}: {f} matches {pat}")

tag = "harness-start.sh unsets GATEWAY_*_SECRET by pattern and keeps GATEWAY_SECRETS"
start = test[("ConfigMap", "assistant-harness")]["data"]["harness-start.sh"]
lines = start.splitlines()
loop = [i for i, l in enumerate(lines) if l.startswith("for v in $(compgen -v")]
if len(loop) != 1: bad.append(f"{tag}: {len(loop)} unset loops")
else:
    sh = "set -euo pipefail; " + lines[loop[0]] + '; echo "${GATEWAY_DISCORD_SECRET-unset} ${GATEWAY_TEST_SECRET-unset} ${GATEWAY_SECRETS-unset}"'
    p = subprocess.run(["bash", "-c", sh], env={"PATH": "/usr/bin:/bin", "GATEWAY_DISCORD_SECRET": "a", "GATEWAY_TEST_SECRET": "b", "GATEWAY_SECRETS": "discord:a"}, capture_output=True, text=True)
    if p.returncode != 0 or p.stdout.strip() != "unset unset discord:a": bad.append(f"{tag}: the loop leaves {p.stdout.strip()!r} (exit {p.returncode})")
    p = subprocess.run(["bash", "-c", sh], env={"PATH": "/usr/bin:/bin"}, capture_output=True, text=True)
    if p.returncode != 0: bad.append(f"{tag}: the loop fails when no gateway secret is set: {p.stderr.strip()}")
    ex = [i for i, l in enumerate(lines) if l.startswith('exec node "$MAIN"')]
    un = [i for i, l in enumerate(lines) if l == "unset MCP_FINANCE_READ_TOKEN MCP_OPS_TOKEN"]
    if not ex or not un or not (un[0] < loop[0] < ex[0]): bad.append(f"{tag}: the unset line and the loop do not both come before the core starts")
if "GATEWAY_DISCORD_SECRET" in start: bad.append(f"{tag}: harness-start.sh still names GATEWAY_DISCORD_SECRET")

if bad:
    print("FAIL:\n  " + "\n  ".join(bad)); sys.exit(1)
print("channels: discord renders as at the ref; a second channel is its own; bad config fails; one gateway alert; prompts and start script channel-free")
PY
