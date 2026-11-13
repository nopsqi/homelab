#!/usr/bin/env bash
# Usage: tests/floor-conformance.sh <naila-dir>
# The chart side of naila's floor conformance suite (spec §5.3.6). naila's packages/harness/test/floor/cases.json holds the
# permission cases; its floor-conformance.test.ts decides each one with the core's ports of the chart hooks (decidePath,
# decideWeb, grantDocs). This script runs every case tagged hook:<name> through that hook in helm/assistant/files/, so a
# port and its hook can't drift apart:
#  - it builds the cases' `tree` in a temp folder T, and runs the hook as harness-start.sh (or claude.yaml) renders it:
#    read-guard.mjs --by-origin; harness-write-guard.mjs --root <phase root>/Naila/Workspace; docs-grant.mjs --by-caps
#    --uploads <uploads> --root <phase root> [--exclude <phase root>/<VAULT_EXCLUDE dir>,…] (real phase); web-guard.mjs
#    --by-worker. The rendered /vault and /home/claude/.claude/uploads don't exist here, so --root and --uploads name T's
#    (F14); a path under ~/.claude stays the literal /home/claude/.claude;
#  - it pipes the Claude Code hook input {tool_name, tool_input, cwd} (cwd: T/work/<worker>, also the hook's own) into the hook, with
#    HARNESS_CAPS (the case's capabilities, comma-joined; an asked run's without naila's ASKED_RUN_CAPS, as the core
#    subtracts them), HARNESS_WORKER, HARNESS_ORIGIN (unset for a run from no channel) and HARNESS_WEB_SLOTS (a fresh, empty
#    slots folder per case) in its env, and checks that it prints a deny exactly when the case says so: `hook` where a ruling
#    makes the core stricter than the hook (named in `ruling`), else `expect` (a case's `expectBy`, run.extraRead and
#    run.extraWrite concern the naila runners' policies only: no hook reads them). A hook that exits non-zero fails the case
#    (it would block, but no case expects a crash);
#  - hook:web-guard cases run as `node --import <tmp>/dns-stub.mjs web-guard.mjs --by-worker`: the stub (written below, never
#    part of the chart) replaces dns.promises.lookup with the case's `web.dns` (env STUB_DNS; an unlisted name fails), logs
#    every name looked up (env STUB_DNS_LOG) and makes the callback dns.lookup fail, so no case touches the network; the
#    slots folder holds the case's `web.used` slots. Each web case must also give the refusal text WEB_TEXT[reason] word for
#    word (WEB_TEXT imported from naila's block), look up exactly the names in `web.lookups` (as sets), and take one slot of
#    its kind when allowed, none when refused. The allow cases name .example hosts, which never resolve: a stub that didn't
#    take effect fails them;
#  - homelab-only checks: the web guard without --by-worker or HARNESS_CAPS, a missing slots folder, the researched marker
#    is no slot, a resolver that never answers (refused after the 5 s race), and the hook's own 15 s deadline (stdin never
#    closes: a deny with exit 2, since Claude Code lets a call through when a hook times out); the write guard refuses every
#    write tool (and the vault and finance-notes servers' write tools) in a run marked researched or with no slots folder, and
#    has the same 15 s deadline on its input;
#  - it checks that harness-start.sh and claude.yaml still render those hook commands (the web and write hooks with their
#    30 s timeout and onFailure block), and that web-guard.mjs carries naila's
#    web-rules block byte for byte (the text between the web-rules:begin and web-rules:end lines, each once in both files, read
#    from the source packages/harness/src/floor/web-rules.ts, so no build of naila is needed and a stale dist can't hide a drift).
# Node only: no containers, no network. The two hang cases and the deadline checks wait for real (about 5 s, 5 s and 15 s,
# the two deadlines at once).
set -euo pipefail
naila="${1:?usage: tests/floor-conformance.sh <naila-dir>}"
repo="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cases="$naila/packages/harness/test/floor/cases.json"
[ -f "$cases" ] || { echo "FAIL: no cases at $cases"; exit 2; }
priv="$(mktemp -d)"
trap 'rm -rf "$priv"' EXIT
export TMPDIR="$priv"
cat > "$priv/dns-stub.mjs" <<'EOF'
// Test only (tests/floor-conformance.sh): loaded with node --import before web-guard.mjs, never part of the chart.
import dns from 'node:dns'
import { appendFileSync } from 'node:fs'
import { syncBuiltinESMExports } from 'node:module'
import { isIP } from 'node:net'
const table = JSON.parse(process.env.STUB_DNS ?? '{}')
const fail = (code) => Object.assign(new Error(`stub lookup: ${code}`), { code })
dns.promises.lookup = async (name) => {
  if (process.env.STUB_DNS_LOG) appendFileSync(process.env.STUB_DNS_LOG, `${name}\n`)
  const a = Object.hasOwn(table, name) ? table[name] : 'fail'
  if (a === 'hang') return new Promise(() => {})
  if (a === 'nxdomain') throw fail('ENOTFOUND')
  if (!Array.isArray(a)) throw fail('ESERVFAIL')
  return a.map((address) => ({ address, family: isIP(address) || 4 }))
}
// nothing else reaches a real resolver
dns.lookup = (...args) => { const cb = args.at(-1); process.nextTick(() => cb(fail('ESTUB'))) }
syncBuiltinESMExports()
EOF
cat > "$priv/run.mjs" <<'EOF'
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, linkSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, posix } from 'node:path'

const [repo, naila, casesFile, stub] = process.argv.slice(2)
const FILES = join(repo, 'helm/assistant/files')
const { tree, cases } = JSON.parse(readFileSync(casesFile, 'utf8'))
let fail = 0
const bad = (m) => { console.log(`FAIL: ${m}`); fail = 1 }

// the strings between `start`'s `[` and the next `]` in a source file
const listIn = (file, start) => {
  const src = readFileSync(file, 'utf8'), i = src.indexOf(start)
  if (i < 0) return undefined
  const body = src.slice(i + start.length, src.indexOf(']', i + start.length))
  return [...body.matchAll(/'([^']*)'/g)].map((m) => m[1])
}
// The web rules: the text between the markers, each marker line exactly once, in web-guard.mjs and naila's web-rules.ts
const BEGIN = '// web-rules:begin\n', END = '// web-rules:end\n'
const blockOf = (file) => {
  const src = readFileSync(file, 'utf8')
  const count = (m) => src.split('\n').filter((l) => `${l}\n` === m).length
  if (count(BEGIN) !== 1 || count(END) !== 1) return undefined
  const i = src.indexOf(BEGIN), j = src.indexOf(END)
  return j > i ? src.slice(i + BEGIN.length, j) : undefined
}
const rulesTs = join(naila, 'packages/harness/src/floor/web-rules.ts')
const ours = blockOf(join(FILES, 'web-guard.mjs')), theirs = blockOf(rulesTs)
if (ours === undefined || theirs === undefined) bad('web-guard.mjs or naila web-rules.ts lacks the web-rules markers, each exactly once')
else if (ours !== theirs) bad('web-rules block != naila\'s: web-guard.mjs must carry packages/harness/src/floor/web-rules.ts\'s block byte for byte')
else console.log(`OK: web-rules block == naila's (${theirs.split('\n').length - 1} lines, byte for byte)`)
// WEB_TEXT and the marker name from naila's block (its one import first)
const blockFile = join(mkdtempSync(join(tmpdir(), 'rules-')), 'web-rules.mjs')
writeFileSync(blockFile, `import { isIP } from 'node:net'\n${theirs ?? ''}`)
const { WEB_TEXT, WEB_RESEARCHED_MARKER } = await import(blockFile)
if (!WEB_TEXT || WEB_RESEARCHED_MARKER !== 'researched') bad(`naila's block has no WEB_TEXT or its marker is ${WEB_RESEARCHED_MARKER}`)
const wgSrc = readFileSync(join(FILES, 'harness-write-guard.mjs'), 'utf8')
if (!wgSrc.includes(`const RESEARCHED_MARKER = '${WEB_RESEARCHED_MARKER}'`)) bad(`harness-write-guard.mjs's RESEARCHED_MARKER is not naila's WEB_RESEARCHED_MARKER (${WEB_RESEARCHED_MARKER})`)
// an asked run's HARNESS_CAPS lacks these (naila compileClaudeCode)
const askedCaps = listIn(join(naila, 'packages/harness/src/floor/policy.ts'), 'export const ASKED_RUN_CAPS = [')
if (!askedCaps?.length) { bad('could not read naila ASKED_RUN_CAPS'); process.exit(1) }

// the commands as the chart renders them (what the runs below reproduce with T's roots)
const start = readFileSync(join(FILES, 'harness-start.sh'), 'utf8'), claudeYaml = readFileSync(join(repo, 'helm/assistant/templates/claude.yaml'), 'utf8')
const WRITE_MATCHER = '^(Write|Edit|MultiEdit|NotebookEdit|mcp__vault__write_inbox|mcp__vault__append_daily|mcp__vault__workers_write|mcp__finance-notes__.*)$'
for (const [file, text, s] of [
  ['harness-start.sh', start, 'command: "node /config/read-guard.mjs --by-origin || exit 2"'],
  ['harness-start.sh', start, 'command: `node ${grant} --by-caps --uploads ${uploads} --root ${root}${docsExclude} || exit 2`'],
  ['harness-start.sh', start, 'const docsExclude = excluded.length ? ` --exclude ${excluded.map((x) => `${root}/${x}`).join(",")}` : ""'],
  ['harness-start.sh', start, `matcher: "${WRITE_MATCHER}", hooks: [{ type: "command", command: \`node /config/harness-write-guard.mjs --root \${root}/Naila/Workspace || exit 2\`, timeout: 30, onFailure: "block" }]`],
  ['harness-start.sh', start, 'matcher: "WebFetch|WebSearch", hooks: [{ type: "command", command: "node /config/web-guard.mjs --by-worker || exit 2", timeout: 30, onFailure: "block" }]'],
  ['claude.yaml', claudeYaml, '"matcher": "WebFetch|WebSearch", "hooks": [{ "type": "command", "command": "node /config/web-guard.mjs" }]'],
]) if (!text.includes(s)) bad(`${file} no longer renders ${s}`)

// One tree for every case: no hook writes into it (the web guard writes only into its case's own slots folder), and
// docs-grant's only change (its chmod) touches the literal /home/claude/.claude/uploads, never this tree, so no case can
// see another's leftovers.
const t = realpathSync(mkdtempSync(join(tmpdir(), 'floor-')))
for (const d of tree.dirs) mkdirSync(join(t, d), { recursive: true })
for (const [f, text] of Object.entries(tree.files)) writeFileSync(join(t, f), text)
for (const [f, target] of Object.entries(tree.hardlinks)) linkSync(join(t, target), join(t, f))
for (const [f, target] of Object.entries(tree.symlinks)) { mkdirSync(dirname(join(t, f)), { recursive: true }); symlinkSync(join(t, target), join(t, f)) }
const mount = join(t, tree.mount), uploads = join(t, tree.uploads)

const hookArgs = (c, root, exclude) => {
  switch (c.claude) {
    case 'hook:read-guard': return ['read-guard.mjs', '--by-origin']
    case 'hook:write-guard': return ['harness-write-guard.mjs', '--root', `${root}/Naila/Workspace`]
    case 'hook:docs-grant': return ['docs-grant.mjs', '--by-caps', '--uploads', uploads, '--root', root, ...(exclude.length ? ['--exclude', exclude.map((x) => `${root}/${x}`).join(',')] : [])]
    case 'hook:web-guard': return ['web-guard.mjs', '--by-worker']
  }
}
const subst = (v, tok) => typeof v === 'string' ? v.replace(/\$[VUWHS]/g, (m) => tok[m])
  : Array.isArray(v) ? v.map((x) => subst(x, tok)) : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, subst(x, tok)])) : v
// a fresh slots folder holding `used` slots ({search?, open?}), plus the researched marker when asked
const slotsWith = (used = {}, researched = false) => {
  const d = mkdtempSync(join(tmpdir(), 'slots-'))
  for (const kind of ['search', 'open']) for (let n = 1; n <= (used[kind] ?? 0); n++) writeFileSync(join(d, `${kind}-${n}`), '')
  if (researched) writeFileSync(join(d, WEB_RESEARCHED_MARKER), '')
  return d
}
const slotCount = (d) => {
  const names = readdirSync(d), of = (kind) => names.filter((x) => new RegExp(`^${kind}-\\d+$`).test(x)).length
  return { search: of('search'), open: of('open') }
}
const out = (r) => { try { return JSON.parse(r.stdout).hookSpecificOutput } catch { return undefined } }
// the web guard as the harness runs it, with the stub resolver; `dns` the stub table. The names it looked up come back too.
const webRun = (args, env, input, dns = {}, cwd = t) => {
  const log = join(mkdtempSync(join(tmpdir(), 'dnslog-')), 'log')
  writeFileSync(log, '')
  const r = spawnSync(process.execPath, ['--import', stub, join(FILES, 'web-guard.mjs'), ...args], { cwd, input,
    env: { PATH: process.env.PATH, STUB_DNS: JSON.stringify(dns), STUB_DNS_LOG: log, ...env }, encoding: 'utf8', timeout: 20000 })
  return { ...r, lookups: readFileSync(log, 'utf8').split('\n').filter(Boolean) }
}
const sameSet = (a, b) => JSON.stringify([...new Set(a)].sort()) === JSON.stringify([...new Set(b)].sort())

let n = 0, agree = 0
for (const c of cases.filter((x) => x.claude.startsWith('hook:'))) {
  n++
  const ph = tree.phases[c.run.phase], root = join(t, ph.root)
  // only the real phase passes VAULT_EXCLUDE to the docs grant (harness-start.sh)
  const exclude = c.run.phase === 'real' ? ph.exclude : []
  const cwd = join(t, tree.work, c.run.worker)
  // the path tokens, as cases.json's `about` defines them ($S: Claude Code's project slug of the cwd)
  const tok = { $V: mount, $U: uploads, $W: posix.join(root, 'Naila', 'Workspace', c.run.worker), $H: tree.home, $S: cwd.replace(/[^a-zA-Z0-9]/g, '-') }
  const [hook, ...args] = hookArgs(c, root, exclude)
  const caps = c.run.on.filter((x) => !(c.run.asked && askedCaps.includes(x))).join(',')
  const slots = slotsWith(c.web?.used)
  const env = { PATH: process.env.PATH, HARNESS_CAPS: caps, HARNESS_WORKER: c.run.worker, HARNESS_WEB_SLOTS: slots, ...(c.run.origin === undefined ? {} : { HARNESS_ORIGIN: c.run.origin }) }
  const input = JSON.stringify({ tool_name: c.tool, tool_input: subst(c.input, tok), cwd })
  const want = c.hook ?? c.expect
  // in the run's cwd, as Claude Code runs a hook command
  const r = c.claude === 'hook:web-guard' ? webRun(args, env, input, c.web?.dns ?? {}, cwd)
    : spawnSync(process.execPath, [join(FILES, hook), ...args], { cwd, input, env, encoding: 'utf8', timeout: 20000 })
  if (r.status !== 0) { bad(`${c.id} ${c.what}: ${hook} exited ${r.status}: ${(r.stderr ?? '').trim().split('\n').pop()}`); continue }
  const denied = /"permissionDecision":"deny"/.test(r.stdout)
  if (denied !== (want === 'deny')) { bad(`${c.id} ${c.what}: ${hook} ${denied ? 'denies' : 'does not deny'} (want ${want}) ${r.stdout.trim()}`); continue }
  if (c.claude === 'hook:web-guard') {
    const o = out(r), why = []
    if (o?.permissionDecision !== want) why.push(`decision ${o?.permissionDecision}, want ${want}`)
    if (want === 'deny' && o?.permissionDecisionReason !== WEB_TEXT[c.reason]) why.push(`reason ${JSON.stringify(o?.permissionDecisionReason)}, want WEB_TEXT.${c.reason} ${JSON.stringify(WEB_TEXT[c.reason])}`)
    if (!sameSet(r.lookups, c.web?.lookups ?? [])) why.push(`looked up ${JSON.stringify(r.lookups)}, want ${JSON.stringify(c.web?.lookups ?? [])}`)
    const kind = c.tool === 'WebSearch' ? 'search' : 'open', got = slotCount(slots)
    const wantSlots = { search: c.web?.used?.search ?? 0, open: c.web?.used?.open ?? 0 }
    if (want === 'allow') wantSlots[kind]++
    if (JSON.stringify(got) !== JSON.stringify(wantSlots)) why.push(`slots ${JSON.stringify(got)}, want ${JSON.stringify(wantSlots)}`)
    if (why.length) { bad(`${c.id} ${c.what}: web-guard.mjs ${why.join('; ')}`); continue }
  }
  agree++
  if (c.hook !== undefined) console.log(`OK: ${c.id} ${c.what}: ${hook} ${want}s it, the core denies it (${c.ruling})`)
}
console.log(`${agree}/${n} hook cases agree`)

// Homelab-only checks of the web guard (what the shared cases can't state: its flag, its env, its slots folder, its deadline)
const R = { HARNESS_CAPS: 'web.search,web.open', HARNESS_WORKER: 'researcher' }
const PAGE = JSON.stringify({ tool_name: 'WebFetch', tool_input: { url: 'https://site.example/x' } })
const SEARCH = JSON.stringify({ tool_name: 'WebSearch', tool_input: { query: 'BI rate' } })
const PUBLIC = { 'site.example': ['93.184.215.14'], 'www.site.example': ['93.184.215.14'] }
let extra = 0
const web = (what, args, env, input, dns, want, reason, lookups, check) => {
  extra++
  const t0 = Date.now(), r = webRun(args, env, input, dns), o = out(r), ms = Date.now() - t0, why = []
  if (r.status !== 0) why.push(`exit ${r.status}`)
  if (o?.permissionDecision !== want) why.push(`decision ${o?.permissionDecision}, want ${want}`)
  if (reason !== undefined && o?.permissionDecisionReason !== reason) why.push(`reason ${JSON.stringify(o?.permissionDecisionReason)}, want ${JSON.stringify(reason)}`)
  if (lookups !== undefined && !sameSet(r.lookups, lookups)) why.push(`looked up ${JSON.stringify(r.lookups)}, want ${JSON.stringify(lookups)}`)
  if (check) why.push(...check(ms))
  if (why.length) bad(`web-guard.mjs ${what}: ${why.join('; ')}`)
}
const lookedUp = ['site.example', 'www.site.example']
web('without --by-worker (the RC lines), the researcher\'s public page', [], { ...R, HARNESS_WEB_SLOTS: slotsWith() }, PAGE, PUBLIC, 'deny', WEB_TEXT.askResearcher, [])
web('without --by-worker, the researcher\'s search', [], { ...R, HARNESS_WEB_SLOTS: slotsWith() }, SEARCH, {}, 'deny', WEB_TEXT.askResearcher, [])
web('with --by-worker, no HARNESS_CAPS', ['--by-worker'], { HARNESS_WORKER: 'researcher', HARNESS_WEB_SLOTS: slotsWith() }, SEARCH, {}, 'deny', WEB_TEXT.askResearcher, [])
web('with --by-worker, no HARNESS_WORKER', ['--by-worker'], { HARNESS_CAPS: R.HARNESS_CAPS, HARNESS_WEB_SLOTS: slotsWith() }, SEARCH, {}, 'deny', WEB_TEXT.askResearcher, [])
web('the researcher\'s worker named in the tool input only', ['--by-worker'], { HARNESS_CAPS: R.HARNESS_CAPS, HARNESS_WORKER: 'naila', HARNESS_WEB_SLOTS: slotsWith() },
  JSON.stringify({ tool_name: 'WebSearch', tool_input: { query: 'x' }, agent_type: 'researcher', worker: 'researcher' }), {}, 'deny', WEB_TEXT.askResearcher, [])
web('unreadable input', ['--by-worker'], { ...R, HARNESS_WEB_SLOTS: slotsWith() }, '{', {}, 'deny', WEB_TEXT.unreadable, [])
web('a search with no HARNESS_WEB_SLOTS', ['--by-worker'], R, SEARCH, {}, 'deny', WEB_TEXT.noCounter, [])
web('a page with a slots folder that is gone', ['--by-worker'], { ...R, HARNESS_WEB_SLOTS: join(slotsWith(), 'gone') }, PAGE, PUBLIC, 'deny', WEB_TEXT.noCounter, [])
web('a page with a relative HARNESS_WEB_SLOTS', ['--by-worker'], { ...R, HARNESS_WEB_SLOTS: 'web' }, PAGE, PUBLIC, 'deny', WEB_TEXT.noCounter, [])
{
  const d = slotsWith({ open: 39 }, true)
  web('the researched marker is no slot (39 pages used, the marker there)', ['--by-worker'], { ...R, HARNESS_WEB_SLOTS: d }, PAGE, PUBLIC, 'allow', undefined, lookedUp,
    () => (slotCount(d).open === 40 && existsSync(join(d, WEB_RESEARCHED_MARKER)) ? [] : [`slots ${JSON.stringify(slotCount(d))} after`]))
}
web('a lookup that never answers, on the host and both twins (refused at the 5 s race, well before the deadline)', ['--by-worker'], { ...R, HARNESS_WEB_SLOTS: slotsWith() },
  JSON.stringify({ tool_name: 'WebFetch', tool_input: { url: 'https://www.site.example/' } }), { 'www.site.example': 'hang', 'site.example': 'hang' }, 'deny', WEB_TEXT.unresolved, lookedUp,
  (ms) => (ms >= 4500 && ms < 10000 ? [] : [`took ${ms} ms, want about 5000`]))
// The deadline: Claude Code lets the call through when a hook times out, so the hook must refuse by itself at 15 s whatever
// holds it up. Here its input never ends (stdin stays open): a deny, exit 2 (a block whatever the output), the reason on stderr.
// The write guard has the same deadline on its input; both wait at once.
const deadline = (what, args, env, part) => new Promise((resolve) => {
  extra++
  const t0 = Date.now()
  const child = spawn(process.execPath, args, { env: { PATH: process.env.PATH, ...env }, stdio: ['pipe', 'pipe', 'pipe'] })
  let so = '', se = ''
  child.stdout.on('data', (x) => { so += x }); child.stderr.on('data', (x) => { se += x })
  child.stdin.write(part)   // part of a call, and never the end of it
  const kill = setTimeout(() => child.kill('SIGKILL'), 25000)
  child.on('close', (code) => {
    clearTimeout(kill)
    const ms = Date.now() - t0, why = []
    if (code !== 2) why.push(`exit ${code}, want 2`)
    if (!/"permissionDecision":"deny"/.test(so)) why.push(`printed ${JSON.stringify(so)}`)
    if (!/took too long/.test(se)) why.push(`stderr ${JSON.stringify(se)}`)
    if (ms < 14500 || ms > 20000) why.push(`took ${ms} ms, want about 15000`)
    if (why.length) bad(`${what}'s own deadline (its input never ends): ${why.join('; ')}`)
    resolve()
  })
})
const writeDeadline = deadline('harness-write-guard.mjs', [join(FILES, 'harness-write-guard.mjs'), '--root', '/vault/Naila/Workspace'],
  { HARNESS_WORKER: 'naila', HARNESS_WEB_SLOTS: slotsWith() }, '{"tool_name":"Wri')
await deadline('web-guard.mjs', ['--import', stub, join(FILES, 'web-guard.mjs'), '--by-worker'], { ...R, HARNESS_WEB_SLOTS: slotsWith(), STUB_DNS: '{}' }, SEARCH.slice(0, 10))
await writeDeadline

// Homelab-only checks of the write guard: in a run marked researched every write tool is refused, the servers' write tools
// too; a run with no slots folder is refused (fail closed); without the marker the servers' tools are the settings' to decide
const RESEARCHED_TEXT = "A web search happened in this message, so nothing can be written in it: file a plan, or ask again in a message of its own."
const wroot = join(t, tree.phases.real.root)
const write = (what, tool, toolInput, env, want, reason) => {
  extra++
  const r = spawnSync(process.execPath, [join(FILES, 'harness-write-guard.mjs'), '--root', `${wroot}/Naila/Workspace`],
    { cwd: join(t, tree.work, 'naila'), input: JSON.stringify({ tool_name: tool, tool_input: toolInput }), env: { PATH: process.env.PATH, HARNESS_WORKER: 'naila', ...env }, encoding: 'utf8', timeout: 20000 })
  const o = out(r), got = r.stdout.trim() === '' ? 'none' : o?.permissionDecision, why = []
  if (r.status !== 0) why.push(`exit ${r.status}`)
  if (got !== want) why.push(`decision ${got}, want ${want}`)
  if (reason !== undefined && o?.permissionDecisionReason !== reason) why.push(`reason ${JSON.stringify(o?.permissionDecisionReason)}, want ${JSON.stringify(reason)}`)
  if (why.length) bad(`harness-write-guard.mjs ${what}: ${why.join('; ')}`)
}
// every case the shared suite allows (a write in the run's own workspace) is refused once the run is marked, or has no slots
for (const c of cases.filter((x) => x.claude === 'hook:write-guard' && (x.hook ?? x.expect) === 'allow')) {
  const root = join(t, tree.phases[c.run.phase].root)
  const tok = { $V: mount, $U: uploads, $W: posix.join(root, 'Naila', 'Workspace', c.run.worker), $H: tree.home, $S: '' }
  write(`${c.id} (${c.what}) in a run marked researched`, c.tool, subst(c.input, tok), { HARNESS_WEB_SLOTS: slotsWith({}, true) }, 'deny', RESEARCHED_TEXT)
  write(`${c.id} (${c.what}) with no HARNESS_WEB_SLOTS`, c.tool, subst(c.input, tok), {}, 'deny')
  write(`${c.id} (${c.what}) with a slots folder that is gone`, c.tool, subst(c.input, tok), { HARNESS_WEB_SLOTS: join(slotsWith(), 'gone') }, 'deny')
  write(`${c.id} (${c.what}) with a relative HARNESS_WEB_SLOTS`, c.tool, subst(c.input, tok), { HARNESS_WEB_SLOTS: 'web' }, 'deny')
}
const ws = `${wroot}/Naila/Workspace/naila`
for (const [tool, ti] of [['MultiEdit', { file_path: `${ws}/x.md`, edits: [] }], ['NotebookEdit', { notebook_path: `${ws}/x.ipynb`, new_source: 'x' }]]) {
  write(`${tool} in a run marked researched`, tool, ti, { HARNESS_WEB_SLOTS: slotsWith({}, true) }, 'deny', RESEARCHED_TEXT)
  write(`${tool} without the marker (never a workspace write)`, tool, ti, { HARNESS_WEB_SLOTS: slotsWith() }, 'deny')
}
for (const tool of ['mcp__vault__write_inbox', 'mcp__vault__append_daily', 'mcp__vault__workers_write', 'mcp__finance-notes__write_note', 'mcp__finance-notes__edit_note']) {
  write(`${tool} in a run marked researched`, tool, { text: 'x' }, { HARNESS_WEB_SLOTS: slotsWith({}, true) }, 'deny', RESEARCHED_TEXT)
  write(`${tool} without the marker (the settings decide)`, tool, { text: 'x' }, { HARNESS_WEB_SLOTS: slotsWith({ search: 3, open: 2 }) }, 'none')
  write(`${tool} with no HARNESS_WEB_SLOTS`, tool, { text: 'x' }, {}, 'deny')
  write(`${tool} with no HARNESS_WORKER`, tool, { text: 'x' }, { HARNESS_WORKER: '', HARNESS_WEB_SLOTS: slotsWith() }, 'deny')
}
// the rendered matcher covers exactly these tools, anchored (Claude Code tests a regex matcher unanchored)
const m = new RegExp(WRITE_MATCHER)
for (const tool of ['Write', 'Edit', 'MultiEdit', 'NotebookEdit', 'mcp__vault__write_inbox', 'mcp__vault__append_daily', 'mcp__vault__workers_write', 'mcp__finance-notes__write_note', 'mcp__finance-notes__edit_note'])
  if (!m.test(tool)) bad(`the write guard's matcher misses ${tool}`)
for (const tool of ['TodoWrite', 'Read', 'mcp__vault__read_note', 'mcp__vault__search', 'mcp__finance__add_transaction', 'mcp__core__ask_worker', 'WebFetch'])
  if (m.test(tool)) bad(`the write guard's matcher also hooks ${tool}`)
console.log(`${extra} homelab-only web-guard and write-guard checks run`)
process.exit(fail || agree !== n ? 1 : 0)
EOF
node "$priv/run.mjs" "$repo" "$naila" "$cases" "$priv/dns-stub.mjs"
