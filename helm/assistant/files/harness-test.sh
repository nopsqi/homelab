# Unattended test of harness mode (packages/harness from the naila image) in Naila's pod, against the TEST budget:
#   kubectl -n assistant exec deploy/assistant-claude -c claude -- bash /config/harness-test.sh STEP...
# The steps run in order, one conversation per worker (the harness keeps them in harness.db):
#   --worker W "text"   a user turn to W (naila, finance-bookkeeper, finance-advisor, ops-oncall); waits for W's answer
#   --approve           approve the latest pending decision (the newest "Decision #N from …" in #decisions)
#   --reject [REASON]   reject it, with the reason the user gives
#   --between "cmd"     sh -c cmd before every later step, like NAILA_TEST_BETWEEN; it sees $HARNESS_TEST_CLAUDE_DIR (the
#                       runs' config: agents/<worker>.md, settings.json) and $HARNESS_TEST_HOME (the harness home)
# Prints every message the harness posts ([chat] text; #decisions is the decision pool), then TRACE (the tools each run
# called, from its stream-json; ! = refused), ASKS and DECISIONS from harness.db. Exit 1 if a step failed or timed out.
# The core and every worker use the test server (assistant-finance-test) and its bearers, never the real budget. The
# five write tools are denied to every run: a change happens only when a decision is approved and the core carries it
# out. Vault: /vault/Harness-test; finance notes: $HARNESS_TEST_NOTES (default /vault/Harness-test/Finance;
# tests/live/run.sh points it at its fixture cabinet). Everything (harness.db, the runs' config with the login and the
# test bearers, per-run MCP configs, traces) is one throwaway folder under ~/.claude, which the read guard closes to
# every run; it is deleted on exit. NAILA_TEST_AGENTS / NAILA_TEST_HANDBOOKS: rendered files instead of /config and
# /handbooks (tests/live/run.sh PREVIEW=…). Naila can't run this (Bash is denied).
set -eu
export PATH=$HOME/.npm-global/bin:$PATH
CLAUDE_BIN=$HOME/.npm-global/bin/claude
MAIN=/naila/packages/harness/dist/main.js
A=${NAILA_TEST_AGENTS:-/config}
H=${NAILA_TEST_HANDBOOKS:-/handbooks}
NOTES=${HARNESS_TEST_NOTES:-/vault/Harness-test/Finance}; NOTES=${NOTES%/}
die() { echo "harness-test: $*" >&2; exit 2; }
[ $# -gt 0 ] || die "no steps given (see the top of this script)"
[ -f "$MAIN" ] || die "$MAIN is missing: this naila image predates harness mode"
[ -x "$CLAUDE_BIN" ] || die "no claude at $CLAUDE_BIN"
# The Runner relies on these; an older CLI would fail every run in a less obvious way.
help=$("$CLAUDE_BIN" --help 2>&1 </dev/null) || true
for f in --tools --permission-mode --strict-mcp-config --mcp-config; do
  printf '%s\n' "$help" | grep -qE -- "(^|[[:space:],])$f([[:space:],=]|\$)" \
    || die "claude $("$CLAUDE_BIN" --version 2>/dev/null </dev/null | head -n1) has no $f flag"
done
[ -n "${MCP_FINANCE_TEST_TOKEN:-}" ] && [ -n "${MCP_FINANCE_TEST_READ_TOKEN:-}" ] \
  || die "no test server bearers (MCP_FINANCE_TEST_TOKEN, MCP_FINANCE_TEST_READ_TOKEN): harness mode is tested only on the test copy"
# Every run is one more claude process (a few hundred MiB) in this pod, next to the RC lines: leave them room.
cg=/sys/fs/cgroup
if [ -r "$cg/memory.max" ] && [ -r "$cg/memory.current" ]; then
  max=$(cat "$cg/memory.max"); cur=$(cat "$cg/memory.current")
  if [ "$max" = max ]; then echo "harness-test: note: this pod has no memory limit, headroom not checked" >&2
  else
    free=$(( (max - cur) / 1048576 ))
    [ "$free" -ge 800 ] || die "only $free MiB of memory headroom (limit $(( max / 1048576 )) MiB, in use $(( cur / 1048576 )) MiB); need 800 MiB so the runs can't push the RC lines into an OOM kill"
  fi
else echo "harness-test: note: no cgroup v2 memory files, headroom not checked" >&2; fi
for k in harness-CLAUDE.md harness-agent-finance-bookkeeper.md harness-agent-finance-advisor.md; do
  [ -f "$A/$k" ] || die "$A/$k is missing: this chart predates harness mode"
done

HH=$(mktemp -d -p "$HOME/.claude" harness-test.XXXXXX)
# On exit: stop the harness (its process group) and any run it started (they name $HH in their arguments), then delete it all.
# set +e first: a kill that finds nothing must not end the trap before the rm.
trap 'set +e; p=$(cat "$HH/main.pid" 2>/dev/null); [ -z "$p" ] || kill -TERM -- "-$p" 2>/dev/null; pkill -TERM -f -- "$HH/" 2>/dev/null; rm -rf "$HH"' EXIT
trap 'set +e; [ -z "${DP:-}" ] || kill -TERM "$DP" 2>/dev/null; sleep 1; exit 130' INT TERM HUP
T=$HH/config   # the runs' CLAUDE_CONFIG_DIR; not named .claude, so no run's folder has it as a parent project config
mkdir -p "$T/agents" "$HH/work/naila" "$HH/work/_summary" /vault/Harness-test "$NOTES"
cp -a "$HOME/.claude/.credentials.json" "$T/"
cp "$HOME/.claude.json" "$T/.claude.json"

# Workers from the harness-agent-* keys, pointed at the test server with its bearers (as naila-test.sh does).
for f in "$A"/harness-agent-*.md; do
  sed -e "s/__MCP_FINANCE_TOKEN__/$MCP_FINANCE_TEST_TOKEN/" -e "s/__MCP_FINANCE_READ_TOKEN__/$MCP_FINANCE_TEST_READ_TOKEN/" \
      -e "s/__MCP_OPS_TOKEN__/${MCP_OPS_TOKEN:-}/" -e "s#/handbooks/#$H/#g" -e 's#//assistant-finance:#//assistant-finance-test:#' \
      -e "s#/vault/Finance/#$NOTES/#g" "$f" > "$T/agents/${f##*/harness-agent-}"
done
grep -q 'TEST COPY' "$T/agents/finance-bookkeeper.md" || { echo; cat /config/finance-test-note; } >> "$T/agents/finance-bookkeeper.md"
! grep -l '__MCP_' "$T"/agents/*.md >/dev/null || die "unfilled bearer placeholder in $(grep -l '__MCP_' "$T"/agents/*.md | xargs -n1 basename)"
if grep -q '//assistant-finance:' "$T"/agents/*.md; then die "a worker still points at the real finance server"; fi

# Naila's settings: no "ask" (no phone here), every write tool and cross-session messaging denied, the core tools allowed.
# The file tools never reach the real vault: no allow rule under //vault/ survives, and every entry of /vault except the
# test folder (Finance always) is denied. The test notes root stays readable.
node -e '
const fs = require("fs"), [src, dst, notes, hb] = process.argv.slice(1), s = JSON.parse(fs.readFileSync(src, "utf8")), p = s.permissions
delete p.ask
p.defaultMode = "dontAsk"
p.allow = p.allow.filter((r) => !r.includes("//vault/"))
p.deny.push("mcp__finance__add_transaction", "mcp__finance__transfer", "mcp__finance__update_transaction", "mcp__finance__actual_write",
  "mcp__finance-notes__write_note", "SendMessage", "ListAgents", "Agent", "Read(//home/claude/.claude/harness-test.*/**)", "Read(//vault/Finance/**)")
let real = []
try { real = fs.readdirSync("/vault", { withFileTypes: true }).filter((e) => e.name !== "Harness-test" && e.name !== "Finance") } catch {}
for (const e of real) p.deny.push(e.isDirectory() ? `Read(//vault/${e.name}/**)` : `Read(//vault/${e.name})`)
p.allow.push("mcp__core__propose_plan", "mcp__core__ask_worker", "mcp__vault__write_inbox", "mcp__vault__append_daily", `Read(/${notes}/**)`, `Read(/${hb}/**)`)
fs.writeFileSync(dst, JSON.stringify(s, null, 2))' "$HOME/.claude/settings.json" "$T/settings.json" "$NOTES" "$H"
# Self-check on the written file: no file-tool allow rule may cover any of /vault outside /vault/Harness-test/.
node -e '
const allow = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).permissions.allow
const bad = allow.filter((r) => {
  if (/^(Read|Glob|Grep|Edit|Write)$/.test(r)) return true
  const m = /^(?:Read|Glob|Grep|Edit|Write)\((.*)\)$/.exec(r); if (!m) return false
  const path = m[1], lit = path.split(/[*?[{]/)[0]
  return (path.startsWith("//vault/") || path === "//vault") ? !path.startsWith("//vault/Harness-test/") : "//vault/".startsWith(lit)
})
if (bad.length) { console.error(`harness-test: the runs would be allowed into the real vault: ${bad.join(", ")}`); process.exit(2) }' "$T/settings.json"

# Work dirs: naila's holds her harness CLAUDE.md; each direct-line worker's names its agent and model (as start.sh does).
cp "$A/harness-CLAUDE.md" "$HH/work/naila/CLAUDE.md"
dirs=("$HH/work/naila" "$HH/work/_summary")
while read -r n m; do
  [ -n "$n" ] || continue
  [ -f "$T/agents/$n.md" ] || die "no harness-agent-$n.md for direct line $n"
  mkdir -p "$HH/work/$n/.claude"
  printf '{"agent": "%s", "model": "%s"}\n' "$n" "$m" > "$HH/work/$n/.claude/settings.json"
  dirs+=("$HH/work/$n")
done < /config/direct-lines
# User-scope MCP: only vault (on the test folder) and docs, nothing else inherited; projects: only the trusted work dirs.
node -e '
const fs = require("fs"), [f, root, ...dirs] = process.argv.slice(1), c = JSON.parse(fs.readFileSync(f, "utf8"))
const v = c.mcpServers && c.mcpServers.vault
if (!v) { console.error("harness-test: no user-scope vault server in ~/.claude.json (start.sh adds it)"); process.exit(2) }
v.env = { ...v.env, VAULT_ROOT: root }
c.mcpServers = { vault: v, ...(c.mcpServers.docs ? { docs: c.mcpServers.docs } : {}) }
c.projects = Object.fromEntries(dirs.map((d) => [d, { hasTrustDialogAccepted: true }]))
fs.writeFileSync(f, JSON.stringify(c, null, 2))' "$T/.claude.json" /vault/Harness-test "${dirs[@]}"

cat > "$HH/drive.mjs" <<'EOF'
// Starts the harness, posts the steps through its channel API as the test gateway, prints what it posts, then stops it.
import { spawn, spawnSync } from 'node:child_process'
import { createServer } from 'node:net'
import { randomBytes } from 'node:crypto'
import { existsSync, openSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { DatabaseSync } from 'node:sqlite'

const E = process.env, HH = E.HARNESS_TEST_HOME
const WORKERS = ['naila', 'finance-bookkeeper', 'finance-advisor', 'ops-oncall']
const TURN_S = Number(E.HARNESS_TEST_TURN_TIMEOUT || 900)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const usage = (why) => { console.error(`harness-test: ${why}\nsteps: --worker W "text" | --approve | --reject [REASON] | --between "cmd"`); process.exit(2) }

const steps = []
let between
const a = process.argv.slice(2)
for (let i = 0; i < a.length; i++) {
  const x = a[i]
  if (x === '--worker') {
    const w = a[++i], text = a[++i]
    if (!WORKERS.includes(w)) usage(`unknown worker ${JSON.stringify(w)} (${WORKERS.join(', ')})`)
    if (!text) usage(`--worker ${w} needs a text`)
    steps.push({ kind: 'turn', w, text })
  } else if (x === '--approve') steps.push({ kind: 'confirm', approve: true })
  else if (x === '--reject') steps.push({ kind: 'confirm', approve: false, reason: a[i + 1] !== undefined && !a[i + 1].startsWith('--') ? a[++i] : undefined })
  else if (x === '--between') { between = a[++i]; if (!between) usage('--between needs a command') }
  else usage(`unknown argument ${JSON.stringify(x)}`)
}
if (!steps.length) usage('no steps')

const freePort = () => new Promise((ok, no) => {
  const s = createServer(); s.once('error', no)
  s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => ok(p)) })
})
const port = await freePort()
let corePort = await freePort()
while (corePort === port) corePort = await freePort()
const gw = randomBytes(32).toString('hex'), coreSecret = randomBytes(32).toString('hex')
const secrets = [gw, coreSecret, E.MCP_FINANCE_TEST_TOKEN, E.MCP_FINANCE_TEST_READ_TOKEN].filter(Boolean)
const redact = (s) => secrets.reduce((t, x) => t.split(x).join('[REDACTED]'), s).replace(/sk-ant-[A-Za-z0-9_-]+/g, '[REDACTED]')

// main.js gets only what it reads; its runs get even less (the Runner's own allowlist).
const env = Object.fromEntries(['PATH', 'HOME', 'TZ', 'LANG', 'DISABLE_AUTOUPDATER', 'CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH'].filter((k) => E[k] !== undefined).map((k) => [k, E[k]]))
Object.assign(env, {
  HARNESS_HOME: HH, HARNESS_TEST: '1', GATEWAY_SECRETS: `test:${gw}`, CORE_TOOLS_SECRET: coreSecret,
  MCP_FINANCE_URL: 'http://assistant-finance-test:8080/mcp', MCP_FINANCE_TOKEN: E.MCP_FINANCE_TEST_TOKEN,
  VAULT_ROOT: '/vault/Harness-test', FINANCE_NOTES_ROOT: E.HARNESS_TEST_NOTES_ROOT,
  HOST: '127.0.0.1', PORT: String(port), CORE_TOOLS_PORT: String(corePort),
  CLAUDE_BIN: E.CLAUDE_BIN, CLAUDE_CONFIG_DIR: E.HARNESS_TEST_CLAUDE_DIR, HARNESS_TRACE_DIR: join(HH, 'trace'), NODE_NO_WARNINGS: '1',
  ...(E.HARNESS_TEST_RUN_TIMEOUT_MS ? { RUN_TIMEOUT_MS: E.HARNESS_TEST_RUN_TIMEOUT_MS } : {}),
})
const logFile = join(HH, 'harness.log')
const main = spawn(process.execPath, [E.MAIN], { env, cwd: HH, stdio: ['ignore', openSync(logFile, 'a'), openSync(logFile, 'a')], detached: true })
writeFileSync(join(HH, 'main.pid'), String(main.pid))
let exited = null
main.on('exit', (code, sig) => { exited = sig ?? code })
const stop = async () => {
  const kill = (sig) => { try { process.kill(-main.pid, sig) } catch {} }
  if (exited === null) { kill('SIGTERM'); for (let i = 0; i < 50 && exited === null; i++) await sleep(100); kill('SIGKILL') }
  rmSync(join(HH, 'main.pid'), { force: true })
}
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sig, async () => { await stop(); process.exit(130) })
const logTail = () => existsSync(logFile) ? redact(readFileSync(logFile, 'utf8')).trim().split('\n').slice(-30).map((l) => `  log: ${l}`).join('\n') : ''

const base = `http://127.0.0.1:${port}`
const api = async (method, path, body) => {
  const r = await fetch(base + path, { method, headers: { authorization: `Bearer ${gw}`, 'content-type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) })
  const t = await r.text()
  let j; try { j = JSON.parse(t) } catch { j = t }
  return { status: r.status, body: j }
}

const up = Date.now() + 90_000
for (;;) {
  if (exited !== null) { console.log(`--- FAILED: the harness exited (${exited}) before it was ready\n${logTail()}`); await stop(); process.exit(1) }
  try { if ((await fetch(base + '/healthz')).ok) break } catch {}
  if (Date.now() > up) { console.log(`--- FAILED: the harness did not come up in 90s\n${logTail()}`); await stop(); process.exit(1) }
  await sleep(500)
}

const pending = [] // decisions announced in #decisions and not yet settled here, oldest first
/** Prints and acknowledges everything in the test outbox; returns it. */
const drain = async () => {
  const r = await api('GET', '/api/v1/outbox')
  if (r.status !== 200) throw new Error(`outbox: HTTP ${r.status}`)
  for (const m of r.body) {
    const tag = m.chat === 'decisions' ? `#decisions${m.decisionId !== undefined ? ` #${m.decisionId}` : ''}` : m.chat
    console.log(redact(`[${tag}] ${m.text.replace(/\n/g, '\n    ')}`))
    if (m.chat === 'decisions' && m.decisionId !== undefined && /^Decision #\d+ from /.test(m.text)) pending.push(m.decisionId)
    await api('POST', '/api/v1/ack', { id: m.id })
  }
  return r.body
}
/** A turn ends with W's answer: a message in W's chat other than the engine's own "Filed decision" / "↪ … asks" lines. */
const turn = async (w, text) => {
  const r = await api('POST', '/api/v1/turn', { chatId: w, text })
  if (r.status !== 202) return `turn refused: HTTP ${r.status} ${JSON.stringify(r.body)}`
  const end = Date.now() + TURN_S * 1000
  for (;;) {
    for (const m of await drain()) if (m.chat === w && !/^(Filed decision #\d+ |↪ )/.test(m.text)) return undefined
    if (exited !== null) return `the harness exited (${exited})\n${logTail()}`
    if (Date.now() > end) return `no answer from ${w} after ${TURN_S}s`
    await sleep(1000)
  }
}
const confirm = async (approve, reason) => {
  const id = pending.pop()
  if (id === undefined) { console.log(`--- ${approve ? 'approve' : 'reject'}: no pending decision`); return undefined }
  const r = await api('POST', '/api/v1/confirm', { decisionId: id, approve, ...(reason ? { reason } : {}) })
  console.log(`--- ${approve ? 'approve' : 'reject'} decision #${id}${reason ? ` (${reason})` : ''}: ${r.body?.result ?? `HTTP ${r.status}`}`)
  await drain()
  return r.status === 200 ? undefined : `confirm #${id}: HTTP ${r.status} ${JSON.stringify(r.body)}`
}

let failed
for (const [i, s] of steps.entries()) {
  if (i > 0 && between) {
    const r = spawnSync('sh', ['-c', between], { stdio: ['ignore', 'inherit', 'inherit'] })
    if (r.status !== 0) console.log(`--- between: exit ${r.status}`)
  }
  try {
    if (s.kind === 'turn') { console.log(`--- turn [${s.w}]: ${s.text}`); failed = await turn(s.w, s.text) }
    else failed = await confirm(s.approve, s.reason)
  } catch (e) { failed = e.message }
  if (failed) { console.log(`--- FAILED: ${redact(failed)}`); break }
}
await stop()

// TRACE: per run, in start order, the tools it called (! = refused), as naila-trace.mjs prints them.
const label = (c, refused) => {
  const i = c.input ?? {}
  let n = c.name.replace(/^mcp__/, '').replace('__', ':')
  if (c.name === 'WebFetch') { try { n += `(${new URL(i.url).hostname})` } catch { n += '(?)' } }
  if (c.name === 'Read') n += `(${i.file_path ?? ''})`
  if (c.name === 'Glob' || c.name === 'Grep') n += `(${i.path ? `${i.path} ` : ''}${i.pattern ?? ''})`   // where it searched, not only what
  if (c.name === 'mcp__core__ask_worker') n += `(${i.worker})`
  return refused ? n + '!' : n
}
const trace = join(HH, 'trace'), runs = []
for (const f of existsSync(trace) ? readdirSync(trace).sort() : []) {
  const calls = new Map(), refused = new Set()
  for (const line of readFileSync(join(trace, f), 'utf8').split('\n')) {
    let e; try { e = JSON.parse(line) } catch { continue }
    for (const c of e.message?.content ?? []) {
      if (c.type === 'tool_use') calls.set(c.id, c)
      if (c.type === 'tool_result' && c.is_error) refused.add(c.tool_use_id)
    }
  }
  const who = f.replace(/^\d+-/, '').replace(/\.jsonl$/, '')
  runs.push(`${who}: ${[...calls].map(([id, c]) => label(c, refused.has(id))).join(' ') || '-'}`)
}
console.log(redact(`TRACE runs=${runs.length}${runs.length ? ' | ' + runs.join(' | ') : ''}`))
if (existsSync(join(HH, 'harness.db'))) {
  const db = new DatabaseSync(join(HH, 'harness.db'))
  const oneLine = (s, n) => { const t = String(s ?? '').replace(/\s+/g, ' '); return t.length > n ? `${t.slice(0, n)}…` : t }
  const asks = db.prepare("select worker, from_worker, text from turns where role = 'delegation' order by ts").all()
  console.log(redact(`ASKS ${asks.map((x) => `${x.from_worker}->${x.worker}: ${oneLine(x.text, 120)}`).join(' | ') || 'none'}`))
  const ds = db.prepare('select id, worker, status, settle_reason from decisions order by id').all()
  for (const d of ds) {
    const st = db.prepare('select idx, server, tool, args, result, error from decision_steps where decision_id = ? order by idx').all(d.id)
    console.log(redact(`DECISION #${d.id} ${d.worker} ${d.status}${d.settle_reason ? ` (${oneLine(d.settle_reason, 80)})` : ''} | ` +
      st.map((x) => `${x.idx + 1}. ${x.server}:${x.tool} ${oneLine(x.args, 200)} -> ${x.result != null ? `ok ${oneLine(x.result, 120)}` : x.error != null ? `failed ${oneLine(x.error, 120)}` : 'not run'}`).join(' | ')))
  }
  if (!ds.length) console.log('DECISIONS none')
  db.close()
}
process.exit(failed ? 1 : 0)
EOF

# In the background, so a TERM/INT reaches the trap above while a turn is still running.
HARNESS_TEST_HOME=$HH HARNESS_TEST_CLAUDE_DIR=$T HARNESS_TEST_NOTES_ROOT=$NOTES CLAUDE_BIN=$CLAUDE_BIN MAIN=$MAIN \
  node --no-warnings "$HH/drive.mjs" "$@" </dev/null &
DP=$!
wait "$DP"
