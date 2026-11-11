# assistant-harness pod, `harness` container: prepares the runs' Claude Code config from /config, then runs the harness
# core (packages/harness) as the container's main process. Everything it writes is rebuilt on every start.
#   HARNESS_PHASE=test: the test budget (assistant-finance-test, its bearers) and /vault/Harness-test, the only vault folder
#                       this pod mounts in the test phase.
#   HARNESS_PHASE=real: the real budget (assistant-finance) and the whole vault at /vault, except /vault/Harness-test
#                       (VAULT_EXCLUDE: denied to the file tools, left out by the vault servers).
# The runs' CLAUDE_CONFIG_DIR is ~/.claude itself: the login page (the login sidecar, naila.nopsqi.dev/harness) logs in
# there, and a run that renews the token writes it back to the same file, so the pod has one login. Under ~/.claude only
# uploads/<the run's origin channel>/ and tool-results/ are open to the runs (read-guard.mjs --by-origin, Ruling 16): the
# login, the agent files with the bearers, harness.db (HARNESS_HOME) and other channels' uploads are not. Only the core keeps the finance write bearer; the workers get the read-only one.
set -eu
export NPM_CONFIG_PREFIX=$HOME/.npm-global PATH=$HOME/.npm-global/bin:$PATH
C=$HOME/.claude
MAIN=/naila/packages/harness/dist/main.js
PREPARE=/naila/packages/harness/dist/providers/claude-code/prepare.js
die() { echo "harness-start: $*" >&2; exit 2; }
case "${HARNESS_PHASE:-}" in test|real) ;; *) die "HARNESS_PHASE must be test or real, got '${HARNESS_PHASE:-}'" ;; esac
if [ "$HARNESS_PHASE" = real ]; then
  case ",${VAULT_EXCLUDE:-}," in *,Harness-test,*) ;; *) die "the real phase needs VAULT_EXCLUDE to name Harness-test, got '${VAULT_EXCLUDE:-}'" ;; esac
fi
[ -f "$MAIN" ] || die "$MAIN is missing: this naila image predates harness mode"
# The worker spec (chart) and the claude-code adapter that writes the agent files from it (image) come together: roll back both.
[ -f "$PREPARE" ] || die "$PREPARE is missing: this naila image predates the worker spec"
[ -f /config/harness-workers.json ] || die "/config/harness-workers.json is missing: this chart predates the worker spec"
# The vault server must honour VAULT_EXCLUDE, or the real phase's runs would see the test folder (an image older than the
# chart): fail closed. The phrase is the one the server logs at startup when VAULT_EXCLUDE is set.
VAULT_SERVER=/naila/packages/vault-mcp/dist/server.js
if [ -n "${VAULT_EXCLUDE:-}" ] && ! grep -qF 'vault-mcp: VAULT_EXCLUDE supported' "$VAULT_SERVER"; then die "VAULT_EXCLUDE is set but $VAULT_SERVER doesn't support it: this naila image is older than the chart"; fi
for k in harness-CLAUDE.md harness-agent-finance-bookkeeper.md harness-settings.json harness-write-guard.mjs settings.json docs-grant.mjs; do
  [ -f "/config/$k" ] || die "/config/$k is missing: this chart predates harness mode"
done
[ -n "${MCP_FINANCE_TOKEN:-}" ] && [ -n "${MCP_FINANCE_READ_TOKEN:-}" ] && [ -n "${MCP_OPS_TOKEN:-}" ] || die "a bearer is missing (MCP_FINANCE_TOKEN, MCP_FINANCE_READ_TOKEN, MCP_OPS_TOKEN)"

[ "$(claude --version 2>/dev/null | cut -d' ' -f1)" = "$CLAUDE_VERSION" ] || npm i -g @anthropic-ai/claude-code@$CLAUDE_VERSION
# The Runner relies on these; an older CLI would fail every run in a less obvious way. --disallowedTools takes the write tools
# from a run another worker asked (P25), and --settings carries each run's capability settings: without either a run would
# keep tools it must not have, so fail closed.
help=$(claude --help 2>&1 </dev/null) || true
for f in --tools --permission-mode --strict-mcp-config --mcp-config --disallowedTools --settings; do
  printf '%s\n' "$help" | grep -qE -- "(^|[[:space:],])$f([[:space:],=]|\$)" || die "claude $CLAUDE_VERSION has no $f flag"
done

# No login yet: wait for the login page (it doesn't restart this script, it only restarts the running core).
mkdir -p "$C"
if [ ! -f "$C/.credentials.json" ]; then
  echo "harness-start: not logged in; log in at https://naila.nopsqi.dev/harness"
  until [ -f "$C/.credentials.json" ]; do sleep 15; done
  sleep 10   # let `claude auth login` finish writing ~/.claude.json
fi

# Workers from the worker spec (/config/harness-workers.json, already resolved for this phase by the chart): the claude-code
# adapter replaces ~/.claude/agents/ with one agent file per worker (its frontmatter from the spec, the read-only bearer of this
# phase's finance server and the ops one filled in from the env; its instructions file verbatim), writes each worker's work dir
# (HARNESS_HOME/work/<worker>: the core runs it there) with its agent and model, naila's with her harness CLAUDE.md, and
# _summary's, and prints the dirs to trust. It refuses (exit 2, nothing written) an unset bearer or an agent file that would
# hold the finance write bearer. In the test phase the bookkeeper is also told its budget is a test copy.
W=$HARNESS_HOME/work
out=$(node "$PREPARE" --spec /config/harness-workers.json --claude-dir "$C" --work-dir "$W") || die "prepare.js refused the worker spec (its reason is above)"
[ -n "$out" ] || die "prepare.js printed no work dirs"
mapfile -t dirs <<< "$out"
if [ "$HARNESS_PHASE" = test ] && ! grep -q 'TEST COPY' "$C/agents/finance-bookkeeper.md"; then
  { echo; cat /config/finance-test-note; } >> "$C/agents/finance-bookkeeper.md"
fi
! grep -l '__MCP_' "$C"/agents/*.md >/dev/null || die "unfilled bearer placeholder in $(grep -l '__MCP_' "$C"/agents/*.md | xargs -n1 basename)"
if [ "$HARNESS_PHASE" = test ] && grep -q '//assistant-finance:' "$C"/agents/*.md; then die "a worker still points at the real finance server"; fi
if grep -qF -- "$MCP_FINANCE_TOKEN" "$C"/agents/*.md; then die "a worker holds the finance write bearer"; fi

# Settings: Naila's (/config/settings.json) plus harness mode's (harness-settings.json: no "ask", since nobody is there to
# answer). The static deny is the floor (whatever a run's switches say) plus Naila's; the static allow is only the core tools
# no switch governs plus ask_worker and propose_plan (P24). Every other allow comes from each run's own settings (--settings),
# which the core generates from the worker's capability switches (P22): Naila's blanket allows (mcp__ops, mcp__finance-read,
# the finance reads, Finance/, every session's tool-results/) are dropped here, since a static allow would reach every run
# (P28). Bare Write and Edit are not denied (a static bare deny beats a run's allow, so files.write could never work): they
# stay closed unless the run's settings allow its own workspace, and the write guard holds them to
# <VAULT_ROOT>/Naila/Workspace/<worker>/, rooted on its command line (P18); it also takes NotebookEdit (floor-denied), which
# it always refuses. Roll back the chart together with the image: this chart on an image older than naila 82db432 leaves runs
# without vault, finance or ops reads (safe, degraded), since only the per-run settings allow them; it also converts no documents
# at all (an older image sets no HARNESS_CAPS, and docs-grant --by-caps then denies every path). Docs conversion follows each
# run's switches (docs-grant.mjs --by-caps, failing closed): its own channel's uploads (uploads/<HARNESS_ORIGIN>/, Ruling 16;
# none for a run without an origin, or on an image older than naila 95dd7a2, which sets none), this phase's vault only with vault.read, its
# Finance/ for a finance worker with files.read, the worker's own workspace with files.read; minus VAULT_EXCLUDE in the real
# phase. Read, Glob and Grep go through read-guard.mjs --by-origin (Ruling 16): of the uploads only the run's own channel's
# folder, none without HARNESS_ORIGIN, as the core narrows each run's Read allow; `|| exit 2` makes a crash a block. Test
# phase: no file-tool rule reaches the vault outside /vault/Harness-test. Real phase: no file tool reads a VAULT_EXCLUDE folder.
case "$VAULT_ROOT" in /*) ;; *) die "VAULT_ROOT must be an absolute path, got '$VAULT_ROOT'" ;; esac
printf '%s' "$VAULT_ROOT" | grep -qE '^/[A-Za-z0-9._/-]+$' || die "VAULT_ROOT may hold only letters, digits and ._/- (it goes into a hook command), got '$VAULT_ROOT'"
node -e '
const fs = require("fs"), [src, patch, dst, phase, root, grant, uploads, exclude] = process.argv.slice(1)
const s = JSON.parse(fs.readFileSync(src, "utf8")), p = s.permissions, h = JSON.parse(fs.readFileSync(patch, "utf8")).permissions
delete p.ask
p.defaultMode = h.defaultMode
p.allow = [...h.allow]
p.deny = p.deny.filter((r) => r !== "Write" && r !== "Edit")
p.deny.push(...h.deny, "Read(//home/claude/.claude/harness/**)")
if (phase === "test") {
  p.deny.push("Read(//vault/Finance/**)")
  let other = []
  try { other = fs.readdirSync("/vault", { withFileTypes: true }).filter((e) => e.name !== "Harness-test" && e.name !== "Finance") } catch {}
  for (const e of other) p.deny.push(e.isDirectory() ? `Read(//vault/${e.name}/**)` : `Read(//vault/${e.name})`)
}
const excluded = phase === "real" ? (exclude ?? "").split(",").map((e) => e.trim()).filter(Boolean) : []
for (const x of excluded) p.deny.push(`Read(/${root}/${x}/**)`)
const docsExclude = excluded.length ? ` --exclude ${excluded.map((x) => `${root}/${x}`).join(",")}` : ""
const pre = (s.hooks ??= {}).PreToolUse ??= []
// Claude Code runs an entry with no matcher, "" or "*" for every tool: it would hook the guarded tools beside their guard, and
// dropping it would drop it for every other tool too, so it fails the start (the check below counts such an entry as well).
const every = (e) => e.matcher === undefined || e.matcher === null || e.matcher === "" || e.matcher === "*"
if (pre.some(every)) { console.error("harness-start: settings.json has a PreToolUse entry with no matcher, \"\" or \"*\" (every tool): give it a matcher"); process.exit(2) }
s.hooks.PreToolUse = pre.filter((e) => !/docs|Write|Edit|Read|Glob|Grep/.test(e.matcher))
s.hooks.PreToolUse.push({ matcher: "Read|Glob|Grep", hooks: [{ type: "command", command: "node /config/read-guard.mjs --by-origin || exit 2" }] })
s.hooks.PreToolUse.push({ matcher: "mcp__docs__convert", hooks: [{ type: "command", command: `node ${grant} --by-caps --uploads ${uploads} --root ${root}${docsExclude} || exit 2` }] })
s.hooks.PreToolUse.push({ matcher: "Write|Edit|NotebookEdit", hooks: [{ type: "command", command: `node /config/harness-write-guard.mjs --root ${root}/Naila/Workspace || exit 2` }] })
fs.writeFileSync(dst, JSON.stringify(s, null, 2))' /config/settings.json /config/harness-settings.json "$C/settings.json" "$HARNESS_PHASE" "$VAULT_ROOT" /config/docs-grant.mjs "$C/uploads" "${VAULT_EXCLUDE:-}"
# The check, failing startup: no test-phase rule reaches the real vault; docs conversion follows the run's switches under this
# phase's roots (docs-grant.mjs --by-caps --root VAULT_ROOT); the deny holds the whole static floor (harness-settings.json, Agent and Bash among it) and, when the image has the capability
# registry, the image's own FLOOR_DENY (a chart older than the image's floor fails closed); the allow holds nothing beyond the
# static core tools (harness-settings.json's allow, mcp__core__ tools only: propose_plan, ask_worker, decision_status,
# propose_capability_change and the self_note tools; engine_info and undo_vault_change come per run, naila only); Write and Edit go through the write guard rooted at this phase's workspace root;
# Read, Glob and Grep through the read guard narrowed to the run's origin channel (--by-origin, Ruling 16).
node -e '
const fs = require("fs"), [f, phase, root, patch, capsjs] = process.argv.slice(1)
const fail = (m) => { console.error(`harness-start: ${m}`); process.exit(2) }
;(async () => {
const s = JSON.parse(fs.readFileSync(f, "utf8")), allow = s.permissions.allow, deny = s.permissions.deny
const bad = phase !== "test" ? [] : allow.filter((r) => {
  if (/^(Read|Glob|Grep|Edit|Write)$/.test(r)) return true
  const m = /^(?:Read|Glob|Grep|Edit|Write)\((.*)\)$/.exec(r); if (!m) return false
  const path = m[1], lit = path.split(/[*?[{]/)[0]
  return (path.startsWith("//vault/") || path === "//vault") ? !path.startsWith("//vault/Harness-test/") : "//vault/".startsWith(lit)
})
if (bad.length) fail(`test-phase runs would be allowed into the real vault: ${bad.join(", ")}`)
// an entry with no matcher, "" or "*" hooks every tool (Claude Code), so it counts for each
const every = (e) => e.matcher === undefined || e.matcher === null || e.matcher === "" || e.matcher === "*"
const hooked = (tool) => s.hooks.PreToolUse.filter((e) => every(e) || new RegExp(`^(${e.matcher})$`).test(tool)).flatMap((e) => e.hooks.map((x) => x.command))
const docs = hooked("mcp__docs__convert")
const esc = (x) => x.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
if (docs.length !== 1 || !new RegExp(`^node \\S+/docs-grant\\.mjs --by-caps --uploads /\\S+ --root ${esc(root)}( --exclude \\S+)? \\|\\| exit 2$`).test(docs[0]))
  fail("mcp__docs__convert does not follow the run\x27s switches under the phase roots (docs-grant.mjs --by-caps --root VAULT_ROOT)")
if (phase === "real" && !/ --exclude \S+ \|\| exit 2$/.test(docs[0])) fail("mcp__docs__convert does not exclude VAULT_EXCLUDE in the real phase")
const h = JSON.parse(fs.readFileSync(patch, "utf8")).permissions
const floor = [...h.deny, "Agent", "Bash"]
if (fs.existsSync(capsjs)) {
  const m = await import(capsjs)
  if (!Array.isArray(m.FLOOR_DENY) || !m.FLOOR_DENY.length) fail(`${capsjs} has no FLOOR_DENY`)
  floor.push(...m.FLOOR_DENY)
}
const missing = [...new Set(floor.filter((r) => !deny.includes(r)))]
if (missing.length) fail(`the runs\x27 settings do not deny the floor: ${missing.join(", ")}`)
const extra = allow.filter((r) => !h.allow.includes(r) || !/^mcp__core__[a-z_]+$/.test(r))
if (extra.length) fail(`the static allow holds more than the core tools: ${extra.join(", ")}`)
const guard = `node /config/harness-write-guard.mjs --root ${root}/Naila/Workspace || exit 2`
for (const t of ["Write", "Edit", "NotebookEdit"]) { const c = hooked(t); if (c.length !== 1 || c[0] !== guard) fail(`${t} does not go through the write guard rooted at ${root}/Naila/Workspace`) }
const rguard = "node /config/read-guard.mjs --by-origin || exit 2"
for (const t of ["Read", "Glob", "Grep"]) { const c = hooked(t); if (c.length !== 1 || c[0] !== rguard) fail(`${t} does not go through the read guard narrowed to the run\x27s origin (read-guard.mjs --by-origin)`) }
})().catch((e) => fail(e.message))' "$C/settings.json" "$HARNESS_PHASE" "$VAULT_ROOT" /config/harness-settings.json /naila/packages/harness/dist/capabilities.js

# The work dirs are prepare.js's (above); the test notes cabinet may not exist yet.
mkdir -p "$W/naila" "$W/_summary" "$FINANCE_NOTES_ROOT"
# The core reads the same spec: its workers, their models (engine_info) and servers.
export HARNESS_WORKER_SPEC=/config/harness-workers.json

# User-scope MCP: only vault (rooted at this phase's vault); projects: only the trusted work dirs. Written to ~/.claude.json
# and copied to ~/.claude/.claude.json, where Claude Code looks once CLAUDE_CONFIG_DIR is set.
# Docs (Rulings 19, 21): the sidecar listens only on its socket in /run/docs-sock and answers only the bearer in /run/docs-token; the core
# alone gives each run docs, as the stdio relay (docs-relay.js) in the run's own MCP config, which reads the bearer itself. So
# docs has no user-scope entry, and the bearer never lands on the home volume, in a config, an env or a command line. An image
# older than that core (no dist/docs-relay.js, P24) runs the old docs server too, on 127.0.0.1 with no bearer: it keeps the
# user-scope entry with none, as before this chart.
claude mcp remove vault --scope user >/dev/null 2>&1 || true
vault_env=(-e VAULT_ROOT="$VAULT_ROOT" -e TZ="$TZ")
[ -z "${VAULT_EXCLUDE:-}" ] || vault_env+=(-e VAULT_EXCLUDE="$VAULT_EXCLUDE")   # real phase: the test folder stays out
claude mcp add vault --scope user "${vault_env[@]}" -- node "$VAULT_SERVER" >/dev/null
claude mcp remove docs --scope user >/dev/null 2>&1 || true
DOCS_BY_CORE=1; [ -f /naila/packages/harness/dist/docs-relay.js ] || DOCS_BY_CORE=0
if [ "$DOCS_BY_CORE" = 0 ]; then
  echo "harness-start: this naila image predates the docs bearer (Ruling 19): the runs keep the user-scope docs entry, with no bearer"
  claude mcp add --transport http docs --scope user http://127.0.0.1:3002/mcp >/dev/null
fi
node -e '
const fs = require("fs"), [f, byCore, ...dirs] = process.argv.slice(1), c = JSON.parse(fs.readFileSync(f, "utf8"))
const want = byCore === "1" ? ["vault"] : ["vault", "docs"]
if (want.some((s) => !c.mcpServers?.[s])) { console.error(`harness-start: claude mcp add did not write the ${want.join(" and ")} server(s)`); process.exit(2) }
c.mcpServers = Object.fromEntries(want.map((s) => [s, c.mcpServers[s]]))
c.projects = Object.fromEntries(dirs.map((d) => [d, { hasTrustDialogAccepted: true }]))
fs.writeFileSync(f, JSON.stringify(c, null, 2))' "$HOME/.claude.json" "$DOCS_BY_CORE" "${dirs[@]}"
cp "$HOME/.claude.json" "$C/.claude.json"

# The core reads only its own env; the workers' bearers live in the agent files now, and each channel's secret is in
# GATEWAY_SECRETS (which the core reads, so the pattern leaves it set).
unset MCP_FINANCE_READ_TOKEN MCP_OPS_TOKEN
for v in $(compgen -v | grep -E '^GATEWAY_[A-Z0-9_]+_SECRET$'); do unset "$v"; done
export CLAUDE_CONFIG_DIR=$C CLAUDE_BIN=$HOME/.npm-global/bin/claude
cd "$HARNESS_HOME"
exec node "$MAIN"
