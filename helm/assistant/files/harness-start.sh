# assistant-harness pod, `harness` container: prepares the runs' Claude Code config from /config, then runs the harness
# core (packages/harness) as the container's main process. Everything it writes is rebuilt on every start.
#   HARNESS_PHASE=test: the test budget (assistant-finance-test, its bearers) and /vault/Harness-test, the only vault folder
#                       this pod mounts in the test phase.
#   HARNESS_PHASE=real: the real budget (assistant-finance) and the whole vault at /vault, except /vault/Harness-test
#                       (VAULT_EXCLUDE: denied to the file tools, left out by the vault servers).
# The runs' CLAUDE_CONFIG_DIR is ~/.claude itself: the login page (the login sidecar, naila.nopsqi.dev/harness) logs in
# there, and a run that renews the token writes it back to the same file, so the pod has one login. Under ~/.claude only
# uploads/ and tool-results/ are open to the runs (read-guard.mjs): the login, the agent files with the bearers and
# harness.db (HARNESS_HOME) are not. Only the core keeps the finance write bearer; the workers get the read-only one.
set -eu
export NPM_CONFIG_PREFIX=$HOME/.npm-global PATH=$HOME/.npm-global/bin:$PATH
C=$HOME/.claude
MAIN=/naila/packages/harness/dist/main.js
die() { echo "harness-start: $*" >&2; exit 2; }
case "${HARNESS_PHASE:-}" in test|real) ;; *) die "HARNESS_PHASE must be test or real, got '${HARNESS_PHASE:-}'" ;; esac
if [ "$HARNESS_PHASE" = real ]; then
  case ",${VAULT_EXCLUDE:-}," in *,Harness-test,*) ;; *) die "the real phase needs VAULT_EXCLUDE to name Harness-test, got '${VAULT_EXCLUDE:-}'" ;; esac
fi
[ -f "$MAIN" ] || die "$MAIN is missing: this naila image predates harness mode"
# The vault server must honour VAULT_EXCLUDE, or the real phase's runs would see the test folder (an image older than the
# chart): fail closed. The phrase is the one the server logs at startup when VAULT_EXCLUDE is set.
VAULT_SERVER=/naila/packages/vault-mcp/dist/server.js
if [ -n "${VAULT_EXCLUDE:-}" ] && ! grep -qF 'vault-mcp: VAULT_EXCLUDE supported' "$VAULT_SERVER"; then die "VAULT_EXCLUDE is set but $VAULT_SERVER doesn't support it: this naila image is older than the chart"; fi
for k in harness-CLAUDE.md harness-agent-finance-bookkeeper.md harness-settings.json settings.json docs-grant.mjs direct-lines; do
  [ -f "/config/$k" ] || die "/config/$k is missing: this chart predates harness mode"
done
[ -n "${MCP_FINANCE_TOKEN:-}" ] && [ -n "${MCP_FINANCE_READ_TOKEN:-}" ] && [ -n "${MCP_OPS_TOKEN:-}" ] || die "a bearer is missing (MCP_FINANCE_TOKEN, MCP_FINANCE_READ_TOKEN, MCP_OPS_TOKEN)"

[ "$(claude --version 2>/dev/null | cut -d' ' -f1)" = "$CLAUDE_VERSION" ] || npm i -g @anthropic-ai/claude-code@$CLAUDE_VERSION
# The Runner relies on these; an older CLI would fail every run in a less obvious way.
help=$(claude --help 2>&1 </dev/null) || true
for f in --tools --permission-mode --strict-mcp-config --mcp-config; do
  printf '%s\n' "$help" | grep -qE -- "(^|[[:space:],])$f([[:space:],=]|\$)" || die "claude $CLAUDE_VERSION has no $f flag"
done

# No login yet: wait for the login page (it doesn't restart this script, it only restarts the running core).
mkdir -p "$C"
if [ ! -f "$C/.credentials.json" ]; then
  echo "harness-start: not logged in; log in at https://naila.nopsqi.dev/harness"
  until [ -f "$C/.credentials.json" ]; do sleep 15; done
  sleep 10   # let `claude auth login` finish writing ~/.claude.json
fi

# Workers from the harness-agent-* keys, with the read-only bearer of this phase's finance server. In the test phase they
# point at the test server and the test notes cabinet, and the bookkeeper is told its budget is a test copy.
rm -rf "$C/agents" && mkdir -p "$C/agents"
for f in /config/harness-agent-*.md; do
  if [ "$HARNESS_PHASE" = test ]; then
    sed -e "s/__MCP_FINANCE_READ_TOKEN__/$MCP_FINANCE_READ_TOKEN/" -e "s/__MCP_OPS_TOKEN__/$MCP_OPS_TOKEN/" \
        -e 's#//assistant-finance:#//assistant-finance-test:#' -e "s#/vault/Finance/#$FINANCE_NOTES_ROOT/#g" "$f"
  else
    sed -e "s/__MCP_FINANCE_READ_TOKEN__/$MCP_FINANCE_READ_TOKEN/" -e "s/__MCP_OPS_TOKEN__/$MCP_OPS_TOKEN/" "$f"
  fi > "$C/agents/${f#/config/harness-agent-}"
done
if [ "$HARNESS_PHASE" = test ] && ! grep -q 'TEST COPY' "$C/agents/finance-bookkeeper.md"; then
  { echo; cat /config/finance-test-note; } >> "$C/agents/finance-bookkeeper.md"
fi
! grep -l '__MCP_' "$C"/agents/*.md >/dev/null || die "unfilled bearer placeholder in $(grep -l '__MCP_' "$C"/agents/*.md | xargs -n1 basename)"
if [ "$HARNESS_PHASE" = test ] && grep -q '//assistant-finance:' "$C"/agents/*.md; then die "a worker still points at the real finance server"; fi
if grep -qF -- "$MCP_FINANCE_TOKEN" "$C"/agents/*.md; then die "a worker holds the finance write bearer"; fi

# Settings: Naila's (/config/settings.json) plus harness mode's (harness-settings.json: no "ask", since nobody is there to
# answer; the write tools and cross-session messaging denied; the core tools allowed). Docs conversion is limited to
# uploads and this phase's vault (docs-grant.mjs --only, failing closed), minus VAULT_EXCLUDE in the real phase. Test phase: no file-tool rule reaches the vault
# outside /vault/Harness-test, and the test notes cabinet is readable. Real phase: no file tool reads a VAULT_EXCLUDE folder.
node -e '
const fs = require("fs"), [src, patch, dst, phase, root, notes, grant, uploads, exclude] = process.argv.slice(1)
const s = JSON.parse(fs.readFileSync(src, "utf8")), p = s.permissions, h = JSON.parse(fs.readFileSync(patch, "utf8")).permissions
delete p.ask
p.defaultMode = h.defaultMode
p.allow = p.allow.filter((r) => !h.deny.includes(r) && (phase === "real" || !r.includes("//vault/")))
p.deny.push(...h.deny, "Read(//home/claude/.claude/harness/**)")
if (phase === "test") {
  p.deny.push("Read(//vault/Finance/**)")
  let other = []
  try { other = fs.readdirSync("/vault", { withFileTypes: true }).filter((e) => e.name !== "Harness-test" && e.name !== "Finance") } catch {}
  for (const e of other) p.deny.push(e.isDirectory() ? `Read(//vault/${e.name}/**)` : `Read(//vault/${e.name})`)
  p.allow.push(`Read(/${notes}/**)`)
}
const excluded = phase === "real" ? (exclude ?? "").split(",").map((e) => e.trim()).filter(Boolean) : []
for (const x of excluded) p.deny.push(`Read(/${root}/${x}/**)`)
const docsExclude = excluded.length ? ` --exclude ${excluded.map((x) => `${root}/${x}`).join(",")}` : ""
p.allow.push(...h.allow)
const pre = (s.hooks ??= {}).PreToolUse ??= []
s.hooks.PreToolUse = pre.filter((e) => !/docs/.test(e.matcher ?? ""))
s.hooks.PreToolUse.push({ matcher: "mcp__docs__convert", hooks: [{ type: "command", command: `node ${grant} --only ${uploads}:${root}${docsExclude} || exit 2` }] })
fs.writeFileSync(dst, JSON.stringify(s, null, 2))' /config/settings.json /config/harness-settings.json "$C/settings.json" "$HARNESS_PHASE" "$VAULT_ROOT" "$FINANCE_NOTES_ROOT" /config/docs-grant.mjs "$C/uploads" "${VAULT_EXCLUDE:-}"
node -e '
const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")), allow = s.permissions.allow, phase = process.argv[2]
const bad = phase !== "test" ? [] : allow.filter((r) => {
  if (/^(Read|Glob|Grep|Edit|Write)$/.test(r)) return true
  const m = /^(?:Read|Glob|Grep|Edit|Write)\((.*)\)$/.exec(r); if (!m) return false
  const path = m[1], lit = path.split(/[*?[{]/)[0]
  return (path.startsWith("//vault/") || path === "//vault") ? !path.startsWith("//vault/Harness-test/") : "//vault/".startsWith(lit)
})
if (bad.length) { console.error(`harness-start: test-phase runs would be allowed into the real vault: ${bad.join(", ")}`); process.exit(2) }
const docs = s.hooks.PreToolUse.filter((e) => new RegExp(`^(${e.matcher})$`).test("mcp__docs__convert"))
if (docs.length !== 1 || !/ --only \S+( --exclude \S+)? \|\| exit 2$/.test(docs[0].hooks[0].command)) { console.error("harness-start: mcp__docs__convert is not limited to the phase roots"); process.exit(2) }
if (phase === "real" && !/ --exclude \S+ \|\| exit 2$/.test(docs[0].hooks[0].command)) { console.error("harness-start: mcp__docs__convert does not exclude VAULT_EXCLUDE in the real phase"); process.exit(2) }' "$C/settings.json" "$HARNESS_PHASE"

# Work dirs (the core runs each worker in HARNESS_HOME/work/<worker>): naila's holds her harness CLAUDE.md; each direct-line
# worker's names its agent and model, as start.sh does for the RC lines.
W=$HARNESS_HOME/work
mkdir -p "$W/naila" "$W/_summary" "$FINANCE_NOTES_ROOT"   # the test notes cabinet may not exist yet
cp /config/harness-CLAUDE.md "$W/naila/CLAUDE.md"
dirs=("$W/naila" "$W/_summary")
while read -r n m; do
  [ -n "$n" ] || continue
  [ -f "$C/agents/$n.md" ] || die "no harness-agent-$n.md for direct line $n"
  mkdir -p "$W/$n/.claude"
  printf '{"agent": "%s", "model": "%s"}\n' "$n" "$m" > "$W/$n/.claude/settings.json"
  dirs+=("$W/$n")
done < /config/direct-lines

# User-scope MCP: only vault (rooted at this phase's vault) and docs; projects: only the trusted work dirs. Written to
# ~/.claude.json and copied to ~/.claude/.claude.json, where Claude Code looks once CLAUDE_CONFIG_DIR is set.
claude mcp remove vault --scope user >/dev/null 2>&1 || true
vault_env=(-e VAULT_ROOT="$VAULT_ROOT" -e TZ="$TZ")
[ -z "${VAULT_EXCLUDE:-}" ] || vault_env+=(-e VAULT_EXCLUDE="$VAULT_EXCLUDE")   # real phase: the test folder stays out
claude mcp add vault --scope user "${vault_env[@]}" -- node "$VAULT_SERVER" >/dev/null
claude mcp remove docs --scope user >/dev/null 2>&1 || true
claude mcp add --transport http docs --scope user http://127.0.0.1:3002/mcp >/dev/null
node -e '
const fs = require("fs"), [f, ...dirs] = process.argv.slice(1), c = JSON.parse(fs.readFileSync(f, "utf8"))
if (!c.mcpServers?.vault || !c.mcpServers?.docs) { console.error("harness-start: claude mcp add did not write the vault and docs servers"); process.exit(2) }
c.mcpServers = { vault: c.mcpServers.vault, docs: c.mcpServers.docs }
c.projects = Object.fromEntries(dirs.map((d) => [d, { hasTrustDialogAccepted: true }]))
fs.writeFileSync(f, JSON.stringify(c, null, 2))' "$HOME/.claude.json" "${dirs[@]}"
cp "$HOME/.claude.json" "$C/.claude.json"

# The core reads only its own env; the workers' bearers live in the agent files now, and each channel's secret is in
# GATEWAY_SECRETS (which the core reads, so the pattern leaves it set).
unset MCP_FINANCE_READ_TOKEN MCP_OPS_TOKEN
for v in $(compgen -v | grep -E '^GATEWAY_[A-Z0-9_]+_SECRET$'); do unset "$v"; done
export CLAUDE_CONFIG_DIR=$C CLAUDE_BIN=$HOME/.npm-global/bin/claude
cd "$HARNESS_HOME"
exec node "$MAIN"
