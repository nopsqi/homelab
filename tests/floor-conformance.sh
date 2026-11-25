#!/usr/bin/env bash
# Usage: tests/floor-conformance.sh <naila-dir>
# The chart side of naila's floor conformance suite (spec §5.3.6). naila's packages/harness/test/floor/cases.json holds the
# permission cases; its floor-conformance.test.ts decides each one with the core's ports of the chart hooks (decidePath,
# decideWeb, grantDocs). This script runs every case tagged hook:<name> through that hook in helm/assistant/files/, so a
# port and its hook can't drift apart:
#  - it builds the cases' `tree` in a temp folder T, and runs the hook as harness-start.sh (or claude.yaml) renders it:
#    read-guard.mjs --by-origin --private-root <phase root>/Private; harness-write-guard.mjs --root <phase root>/<workspace
#    root> (the profile's, Naila/Workspace in production: vault-mcp's layout of the rendered prod profile) --private-root
#    <phase root>/Private; docs-grant.mjs --by-caps --uploads <uploads> --root <phase root> --private-root <phase root>/Private
#    [--exclude <phase root>/<VAULT_EXCLUDE dir>,…] (real phase); web-guard.mjs
#    --by-worker. The rendered /vault and /home/claude/.claude/uploads don't exist here, so --root and --uploads name T's
#    (F14); a path under ~/.claude stays the literal /home/claude/.claude;
#  - it pipes the Claude Code hook input {tool_name, tool_input, cwd} (cwd: T/work/<role>, also the hook's own) into the hook, with
#    the env the core gives the run: naila's hookEnv (packages/harness/dist/floor/hook-env.js, its roster installed from the
#    cases' own role fixtures, cases.json `roles`: a roles spec v5 with the roles chief, ledger, planner, watch and scout; and,
#    since pure-core phase 4, the setup the chart renders for production installed from the prod render's
#    harness-setup.json (helm template, values.yaml + values.prod.yaml: naila's parseSetup with the job requests beside it,
#    then installSetup; the core's policy reads the profile's paths); build naila first) for the case's role (run.role), switches, origin and asked flag in the case's tree and phase (HARNESS_CAPS,
#    HARNESS_WORKER, HARNESS_ORIGIN when the run has one,
#    HARNESS_DOCS_ROOTS), plus HARNESS_WEB_SLOTS (a fresh, empty slots folder per case). Its HARNESS_CAPS must equal this
#    script's own (the case's capabilities in naila's CAPABILITY_IDS order, comma-joined; an asked run's without naila's
#    ASKED_RUN_CAPS), else the case fails as a drift. It checks that the hook prints a deny exactly when the case says so: `hook` where a ruling
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
#  - homelab-only checks: the web guard without --by-worker, without or with an empty HARNESS_CAPS, with a web switch beside
#    another one, with web switches named only in the tool input, with one web switch alone, and with HARNESS_WORKER naming
#    the lead beside web switches (it decides by the run's switches alone, never by the role's name), a missing slots folder, the researched marker
#    is no slot, a resolver that never answers (refused after the 5 s race), and the hook's own 15 s deadline (stdin never
#    closes: a deny with exit 2, since Claude Code lets a call through when a hook times out); the write guard refuses every
#    write tool (and the vault and finance-notes servers' write tools) in a run marked researched or with no slots folder, and
#    has the same 15 s deadline on its input; its refusal text is naila's RESEARCHED_WRITE_REFUSED, read from naila's built
#    dist (packages/harness/dist/research.js: build naila first), word for word;
#  - file actions Task 17: every docs-grant case runs again with --desk (production's hook carries HARNESS_DESK_ROOT) and
#    gives the same verdict; naila's cases-desk.json (beside cases.json) runs through docs-grant.mjs --desk <T's desk> in
#    cases.json's tree plus its own desk part, with the core's env for a policy context holding deskRoot, each case agreeing
#    with its expectation and with the core's port (grantDocs on the same policy, from the built dist);
#  - workers by plan Task 13: naila's cases-private.json (Task 11: the private folders; its own role fixtures, keeper a
#    private role) runs every hook case through its hook with --private-root, in cases.json's tree plus its own part, with
#    the core's env (hookEnv: HARNESS_PRIVATE_OWN for the private role's run alone), each agreeing with its expectation and
#    with the core's port (floor-model.ts port(), from the built dist), and giving the port's private text word for word;
#  - it checks that harness-start.sh and claude.yaml still render those hook commands (the web and write hooks with their
#    30 s timeout and onFailure block), and that web-guard.mjs carries naila's
#    web-rules block byte for byte (the text between the web-rules:begin and web-rules:end lines, each once in both files, read
#    from the source packages/harness/src/floor/web-rules.ts, so no build of naila is needed and a stale dist can't hide a drift).
# Node (and helm with python3's yaml to render the prod setup) only: no containers, no network. The two hang cases and the deadline checks wait for real (about 5 s, 5 s and 15 s,
# the two deadlines at once).
set -euo pipefail
naila="${1:?usage: tests/floor-conformance.sh <naila-dir>}"
repo="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cases="$naila/packages/harness/test/floor/cases.json"
[ -f "$cases" ] || { echo "FAIL: no cases at $cases"; exit 2; }
priv="$(mktemp -d)"
trap 'rm -rf "$priv"' EXIT
export TMPDIR="$priv"
# the prod render's setup file and the job requests beside it (ConfigMap assistant-harness), as the harness pod mounts them
mkdir -p "$priv/config"
helm template "$repo/helm/assistant" -f "$repo/helm/assistant/values.yaml" -f "$repo/helm/assistant/values.prod.yaml" | python3 -c '
import sys, os, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
cm = [d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "assistant-harness"]
data = cm[0]["data"] if len(cm) == 1 else {}
# the channels the core reads (HARNESS_CHANNELS): it installs the test channels from them (a test-origin run has the _test desk)
dep = [d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "assistant-harness"]
chans = [e.get("value") for c in (dep[0]["spec"]["template"]["spec"]["containers"] if dep else []) if c["name"] == "harness" for e in c.get("env", []) if e["name"] == "HARNESS_CHANNELS"]
if len(chans) != 1: sys.exit("FAIL: the prod render has no HARNESS_CHANNELS on the harness container")
open(os.path.join(sys.argv[1], "harness-channels.json"), "w").write(chans[0])
if "harness-setup.json" not in data: sys.exit("FAIL: the prod render has no harness-setup.json in ConfigMap assistant-harness")
for k, v in data.items():
    if k == "harness-setup.json" or k.startswith("harness-job-"): open(os.path.join(sys.argv[1], k), "w").write(v)
' "$priv/config" || exit 1
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

const [repo, naila, casesFile, stub, configDir] = process.argv.slice(2)
const FILES = join(repo, 'helm/assistant/files')
const { tree, roles, cases } = JSON.parse(readFileSync(casesFile, 'utf8'))
let fail = 0
const bad = (m) => { console.log(`FAIL: ${m}`); fail = 1 }

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
// the core's own env for a run (pure core Task 3): hookEnv, over the roster the core installs from its roles spec at start
const dist = join(naila, 'packages/harness/dist')
// an asked run's HARNESS_CAPS lacks these (naila compileClaudeCode): imported from the built dist, since pure-core phase 3
// generates the list from the service declarations (no literal left in the source)
const { ASKED_RUN_CAPS: askedCaps } = await import(join(dist, 'floor/policy.js'))
if (!Array.isArray(askedCaps) || !askedCaps.length || !askedCaps.every((x) => typeof x === 'string')) { bad(`could not read naila ASKED_RUN_CAPS from ${dist}/floor/policy.js: build naila first (npm run build)`); process.exit(1) }
const { installRoster, rosterFrom } = await import(join(dist, 'roster.js'))
const { parseWorkerSpecs } = await import(join(dist, 'workers-spec.js'))
const { hookEnv } = await import(join(dist, 'floor/hook-env.js'))
const { CAPABILITY_IDS } = await import(join(dist, 'capabilities.js'))
if (typeof hookEnv !== 'function') { bad(`naila's built ${dist}/floor/hook-env.js has no hookEnv: build naila first (npm run build)`); process.exit(1) }
// the cases' own role fixtures (cases.json `roles`, a roles spec v5), as naila's floor-conformance.test.ts installs them
if (!roles || !Array.isArray(roles.roles)) { bad(`${casesFile} has no role fixtures (roles): naila predates pure-core phase 2`); process.exit(1) }
installRoster(rosterFrom(parseWorkerSpecs(JSON.stringify(roles), () => '')))
// pure-core phase 4: the core's policy (hookEnv -> compile, policy) reads the installed profile; the one the chart renders
// for production, as the core installs it at start (main.ts: parseSetup, the requests beside it, then installSetup)
const setupJs = join(dist, 'setup.js')
if (!existsSync(setupJs)) { bad(`naila's built ${setupJs} is missing: build naila first (npm run build)`); process.exit(1) }
const { parseSetup, installSetup, profile } = await import(setupJs)
const setupFile = join(configDir, 'harness-setup.json')
try { installSetup(parseSetup(readFileSync(setupFile, 'utf8'), setupFile, (name) => readFileSync(join(configDir, name), 'utf8'))) }
catch (e) { bad(`naila's parseSetup refuses the prod render's setup: ${e.message}`); process.exit(1) }
// the write guard's root under the phase root: vault-mcp's layout of the profile's paths, as harness-start.sh takes it
const { vaultLayout } = await import(join(naila, 'packages/vault-mcp/dist/layout.js'))
const WS = vaultLayout(profile().paths).workspaces
if (WS !== 'Naila/Workspace') bad(`the prod profile's workspace root is ${WS}, but the cases' tree (and $W) has Naila/Workspace`)
// the lead fixture: the write guard's homelab-only checks run as its run
const LEAD = roles.roles.find((r) => r.lead === true)?.id
if (typeof LEAD !== 'string') { bad('the role fixtures have no lead'); process.exit(1) }

// the commands as the chart renders them (what the runs below reproduce with T's roots)
const start = readFileSync(join(FILES, 'harness-start.sh'), 'utf8'), claudeYaml = readFileSync(join(repo, 'helm/assistant/templates/claude.yaml'), 'utf8')
const WRITE_MATCHER = '^(Write|Edit|MultiEdit|NotebookEdit|mcp__vault__write_inbox|mcp__vault__append_daily|mcp__vault__workers_write|mcp__finance-notes__.*)$'
for (const [file, text, s] of [
  ['harness-start.sh', start, 'command: `node /config/read-guard.mjs --by-origin --private-root ${root}/Private || exit 2`'],
  ['harness-start.sh', start, 'command: `node ${grant} --by-caps --uploads ${uploads} --root ${root} --private-root ${root}/Private${docsDesk}${docsExclude} || exit 2`'],
  ['harness-start.sh', start, 'const docsExclude = excluded.length ? ` --exclude ${excluded.map((x) => `${root}/${x}`).join(",")}` : ""'],
  ['harness-start.sh', start, 'const docsDesk = desk ? ` --desk ${desk}` : ""'],
  ['harness-start.sh', start, `matcher: "${WRITE_MATCHER}", hooks: [{ type: "command", command: \`node /config/harness-write-guard.mjs --root \${root}/\${workspaces} --private-root \${root}/Private || exit 2\`, timeout: 30, onFailure: "block" }]`],
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

// workers by plan Task 13: every hook takes --private-root <phase root>/Private (the core's policy default, PolicyContext
// privateRoot), at harness-start.sh's fixed position: after --by-origin, after --root, after --root and before --desk/--exclude
const hookArgs = (c, root, exclude, desk, up = uploads) => {
  const pr = ['--private-root', `${root}/Private`]
  switch (c.claude) {
    case 'hook:read-guard': return ['read-guard.mjs', '--by-origin', ...pr]
    case 'hook:write-guard': return ['harness-write-guard.mjs', '--root', `${root}/${WS}`, ...pr]
    // file actions: the desk (HARNESS_DESK_ROOT) after --root and before --exclude, as harness-start.sh renders it
    case 'hook:docs-grant': return ['docs-grant.mjs', '--by-caps', '--uploads', up, '--root', root, ...pr, ...(desk ? ['--desk', desk] : []), ...(exclude.length ? ['--exclude', exclude.map((x) => `${root}/${x}`).join(',')] : [])]
    case 'hook:web-guard': return ['web-guard.mjs', '--by-worker']
  }
}
const subst = (v, tok) => typeof v === 'string' ? v.replace(/\$[VUWHSD]/g, (m) => tok[m] ?? m)
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
  const cwd = join(t, tree.work, c.run.role)
  // the path tokens, as cases.json's `about` defines them ($S: Claude Code's project slug of the cwd)
  const tok = { $V: mount, $U: uploads, $W: posix.join(root, 'Naila', 'Workspace', c.run.role), $H: tree.home, $S: cwd.replace(/[^a-zA-Z0-9]/g, '-') }
  const [hook, ...args] = hookArgs(c, root, exclude)
  const unknownCap = c.run.on.find((x) => !CAPABILITY_IDS.includes(x))
  if (unknownCap !== undefined) { bad(`${c.id} ${c.what}: ${unknownCap} is not a capability`); continue }
  const caps = CAPABILITY_IDS.filter((x) => c.run.on.includes(x) && !(c.run.asked && askedCaps.includes(x))).join(',')
  // the case's policy context, as naila's floor-conformance.test.ts ctxFor builds it
  const ctx = { phase: c.run.phase, vaultRoot: root, vaultMount: mount, vaultExclude: ph.exclude, uploadsRoot: uploads, workRoot: join(t, tree.work), claudeHome: tree.home }
  let core
  try { core = hookEnv({ worker: c.run.role, on: c.run.on, ...(c.run.origin === undefined ? {} : { origin: c.run.origin }), asked: c.run.asked }, ctx) }
  catch (e) { bad(`${c.id} ${c.what}: hookEnv throws: ${e.message}`); continue }
  if (core.HARNESS_CAPS !== caps) { bad(`${c.id}: HARNESS_CAPS drift (hookEnv ${JSON.stringify(core.HARNESS_CAPS)}, the case's ${JSON.stringify(caps)})`); continue }
  const slots = slotsWith(c.web?.used)
  const env = { PATH: process.env.PATH, ...core, HARNESS_WEB_SLOTS: slots }
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

// File actions Task 17: production's docs hook carries --desk (HARNESS_DESK_ROOT). Every docs-grant case of cases.json gives
// the same verdict with it (a desk the case's run has no root under changes nothing), and cases-desk.json's cases (naila
// Task 10: a run's own desk, another worker's, a link, a hard link, a test-origin run's _test desk, files.read off) run
// through the hook with --desk, in cases.json's tree plus their own desk part, each agreeing with its expectation and with the
// core's port (grantDocs on the case's policy, deskRoot set).
const deskFile = join(dirname(casesFile), 'cases-desk.json')
let dn = 0, dagree = 0
if (!existsSync(deskFile)) bad(`no desk cases at ${deskFile}: naila predates file actions (Task 10)`)
else {
  const { policyFor } = await import(join(dist, 'floor/policy.js'))
  const { grantDocs } = await import(join(dist, 'floor/docs-grant.js'))
  const { NOT_AVAILABLE } = await import(join(dist, 'capabilities.js'))
  // the test channels, as the core installs them from the rendered HARNESS_CHANNELS at start (main.ts)
  const { installTestChannels } = await import(join(dist, 'channel-kinds.js'))
  installTestChannels(JSON.parse(readFileSync(join(configDir, 'harness-channels.json'), 'utf8')).filter((x) => x.kind === 'test').map((x) => x.name))
  const D = JSON.parse(readFileSync(deskFile, 'utf8'))
  // the docs cases of cases.json, with --desk at a desk no run's roots reach: the same verdicts
  for (const c of cases.filter((x) => x.claude === 'hook:docs-grant')) {
    dn++
    const ph = tree.phases[c.run.phase], root = join(t, ph.root), exclude = c.run.phase === 'real' ? ph.exclude : []
    const cwd = join(t, tree.work, c.run.role)
    const tok = { $V: mount, $U: uploads, $W: posix.join(root, 'Naila', 'Workspace', c.run.role), $H: tree.home, $S: cwd.replace(/[^a-zA-Z0-9]/g, '-') }
    const ctx = { phase: c.run.phase, vaultRoot: root, vaultMount: mount, vaultExclude: ph.exclude, uploadsRoot: uploads, workRoot: join(t, tree.work), claudeHome: tree.home }
    const core = hookEnv({ worker: c.run.role, on: c.run.on, ...(c.run.origin === undefined ? {} : { origin: c.run.origin }), asked: c.run.asked }, ctx)
    const [hook, ...args] = hookArgs(c, root, exclude, join(t, 'desk'))
    const r = spawnSync(process.execPath, [join(FILES, hook), ...args], { cwd, input: JSON.stringify({ tool_name: c.tool, tool_input: subst(c.input, tok), cwd }), env: { PATH: process.env.PATH, ...core }, encoding: 'utf8', timeout: 20000 })
    const denied = /"permissionDecision":"deny"/.test(r.stdout)
    if (r.status !== 0 || denied !== ((c.hook ?? c.expect) === 'deny')) { bad(`${c.id} ${c.what}: with --desk, docs-grant.mjs ${denied ? 'denies' : 'does not deny'} (exit ${r.status}), want ${c.hook ?? c.expect} as without it`); continue }
    dagree++
  }
  // the desk cases' tree: cases.json's, then their own desk part (their links point into both)
  const td = realpathSync(mkdtempSync(join(tmpdir(), 'floor-desk-')))
  for (const part of [tree, D.tree]) {
    for (const d of part.dirs ?? []) mkdirSync(join(td, d), { recursive: true })
    for (const [f, text] of Object.entries(part.files ?? {})) { mkdirSync(dirname(join(td, f)), { recursive: true }); writeFileSync(join(td, f), text) }
    for (const [f, target] of Object.entries(part.hardlinks ?? {})) linkSync(join(td, target), join(td, f))
    for (const [f, target] of Object.entries(part.symlinks ?? {})) { mkdirSync(dirname(join(td, f)), { recursive: true }); symlinkSync(join(td, target), join(td, f)) }
  }
  const dmount = join(td, tree.mount), duploads = join(td, tree.uploads), desk = join(td, D.tree.desk)
  for (const c of D.cases) {
    dn++
    if (c.claude !== 'hook:docs-grant' || c.tool !== 'mcp__docs__convert' || !['allow', 'deny'].includes(c.expect)) { bad(`${c.id}: a desk case must be a docs-grant case with an expectation`); continue }
    const ph = tree.phases[c.run.phase], root = join(td, ph.root), exclude = c.run.phase === 'real' ? ph.exclude : []
    const cwd = join(td, tree.work, c.run.role)
    const tok = { $V: dmount, $U: duploads, $W: posix.join(root, 'Naila', 'Workspace', c.run.role), $H: tree.home, $S: cwd.replace(/[^a-zA-Z0-9]/g, '-'), $D: desk }
    const input = subst(c.input, tok)
    if (/\$[A-Za-z]/.test(JSON.stringify(input))) { bad(`${c.id} ${c.what}: a path token is left in ${JSON.stringify(input)}`); continue }
    const ctx = { phase: c.run.phase, vaultRoot: root, vaultMount: dmount, vaultExclude: ph.exclude, uploadsRoot: duploads, workRoot: join(td, tree.work), claudeHome: tree.home, deskRoot: desk }
    const run = { worker: c.run.role, on: c.run.on, ...(c.run.origin === undefined ? {} : { origin: c.run.origin }), asked: c.run.asked }
    let core, policy
    try {
      core = hookEnv(run, ctx)
      const on = new Set(run.on)
      const stub = { state: () => Object.fromEntries([...CAPABILITY_IDS.map((x) => [x, on.has(x) ? 'on' : 'off']), ...NOT_AVAILABLE.map((x) => [x, 'unavailable'])]), servers: () => [] }
      policy = policyFor(run.worker, stub, ctx, { ...(run.origin === undefined ? {} : { origin: run.origin }), asked: run.asked })
    } catch (e) { bad(`${c.id} ${c.what}: the core's policy throws: ${e.message}`); continue }
    const port = await grantDocs(policy, input.path)
    const args = ['--by-caps', '--uploads', duploads, '--root', root, '--private-root', `${root}/Private`, '--desk', desk, ...(exclude.length ? ['--exclude', exclude.map((x) => `${root}/${x}`).join(',')] : [])]
    const r = spawnSync(process.execPath, [join(FILES, 'docs-grant.mjs'), ...args], { cwd, input: JSON.stringify({ tool_name: c.tool, tool_input: input, cwd }), env: { PATH: process.env.PATH, ...core }, encoding: 'utf8', timeout: 20000 })
    if (r.status !== 0) { bad(`${c.id} ${c.what}: docs-grant.mjs exited ${r.status}`); continue }
    const hook = /"permissionDecision":"deny"/.test(r.stdout) ? 'deny' : 'allow', theirs = port.ok ? 'allow' : 'deny'
    if (hook !== c.expect || theirs !== c.expect) { bad(`${c.id} ${c.what}: docs-grant.mjs --desk ${hook}s, the port ${theirs}s, want ${c.expect} ${r.stdout.trim()} ${port.reason ?? ''}`); continue }
    // without --desk a desk root is outside --root: the hook denies the case (it fails closed, as it did before the desk)
    const r0 = spawnSync(process.execPath, [join(FILES, 'docs-grant.mjs'), ...args.filter((a, i) => a !== '--desk' && args[i - 1] !== '--desk')], { cwd, input: JSON.stringify({ tool_name: c.tool, tool_input: input, cwd }), env: { PATH: process.env.PATH, ...core }, encoding: 'utf8', timeout: 20000 })
    if (!/"permissionDecision":"deny"/.test(r0.stdout) && (core.HARNESS_DOCS_ROOTS ?? '').split(',').some((e) => e.startsWith(`${desk}/`))) { bad(`${c.id} ${c.what}: without --desk docs-grant.mjs lets a desk root through`); continue }
    dagree++
  }
}
console.log(`${dagree}/${dn} desk checks agree (cases.json's docs cases with --desk, and cases-desk.json through the hook and the port)`)

// Workers by plan Task 13: the chart hooks deny every cases-private.json case the port denies. naila Task 11's private folder
// cases (beside cases.json; its own role fixtures: chief the lead, ledger, and keeper, a private role) run through their hook
// with --private-root, in cases.json's tree plus their own part (Private/ at the real phase's root), with the core's env for
// the case's run (hookEnv: HARNESS_PRIVATE_OWN for keeper's alone), each agreeing with its expectation and with the core's
// port of the hook (decidePath, the search-root rule, grantDocs on the case's policy, as naila's floor-model.ts port runs
// them); where the port refuses with a private text (PRIVATE_SEARCH_REFUSAL, PRIVATE_REFUSAL) the hook gives it word for word.
const privFile = join(dirname(casesFile), 'cases-private.json')
let pn = 0, pagree = 0
if (!existsSync(privFile)) bad(`no private folder cases at ${privFile}: naila predates workers by plan Task 11`)
else {
  const { policyFor } = await import(join(dist, 'floor/policy.js'))
  const { grantDocs } = await import(join(dist, 'floor/docs-grant.js'))
  const { NOT_AVAILABLE } = await import(join(dist, 'capabilities.js'))
  const { decidePath, expandHome, patternRefusal, privateSearchRefusal, searchRootOf, PRIVATE_SEARCH_REFUSAL, PRIVATE_REFUSAL } = await import(join(dist, 'floor/paths.js'))
  const { uninstallRosterForTests } = await import(join(dist, 'roster.js'))
  if (typeof PRIVATE_SEARCH_REFUSAL !== 'string' || typeof PRIVATE_REFUSAL !== 'string') { bad(`naila's built ${dist}/floor/paths.js has no private texts: build naila first`); process.exit(1) }
  const P = JSON.parse(readFileSync(privFile, 'utf8'))
  uninstallRosterForTests(); installRoster(rosterFrom(parseWorkerSpecs(JSON.stringify(P.roles), () => '')))
  const tp = realpathSync(mkdtempSync(join(tmpdir(), 'floor-private-')))
  for (const part of [tree, P.tree]) {
    for (const d of part.dirs ?? []) mkdirSync(join(tp, d), { recursive: true })
    for (const [f, text] of Object.entries(part.files ?? {})) { mkdirSync(dirname(join(tp, f)), { recursive: true }); writeFileSync(join(tp, f), text) }
    for (const [f, target] of Object.entries(part.hardlinks ?? {})) linkSync(join(tp, target), join(tp, f))
    for (const [f, target] of Object.entries(part.symlinks ?? {})) { mkdirSync(dirname(join(tp, f)), { recursive: true }); symlinkSync(join(tp, target), join(tp, f)) }
  }
  const pmount = join(tp, tree.mount), puploads = join(tp, tree.uploads)
  // naila floor-model.ts port(): the core's decision on a hook case
  const port = async (c, p, i, cwd) => {
    switch (c.claude) {
      case 'hook:read-guard': {
        if (c.tool === 'Read') return decidePath(p, 'read', String(i.file_path), cwd)
        const pattern = c.tool === 'Glob' ? i.pattern : i.glob
        const refused = pattern === undefined ? undefined : patternRefusal(pattern)
        if (refused) return { ok: false, reason: refused }
        let at = posix.resolve(cwd, expandHome(i.path ?? cwd))
        if (c.tool === 'Glob') { const segs = posix.resolve(at, expandHome(i.pattern)).split('/').slice(1), k = segs.findIndex((x) => /[*?]/.test(x)); at = `/${(k < 0 ? segs : segs.slice(0, k)).join('/')}` }
        const d = await decidePath(p, 'search', at, cwd)
        if (!d.ok) return d
        const why = await privateSearchRefusal(p, searchRootOf(c.tool, i, cwd), cwd)
        return why ? { ok: false, reason: why } : d
      }
      case 'hook:write-guard': return decidePath(p, 'write', String(i.file_path))
      case 'hook:docs-grant': return grantDocs(p, i.path)
    }
  }
  const reasonOf = (r) => { try { return JSON.parse(r.stdout).hookSpecificOutput?.permissionDecisionReason } catch { return undefined } }
  for (const c of P.cases.filter((x) => x.claude.startsWith('hook:'))) {
    pn++
    const ph = tree.phases[c.run.phase], root = join(tp, ph.root), exclude = c.run.phase === 'real' ? ph.exclude : []
    const cwd = join(tp, tree.work, c.run.role)
    const tok = { $V: pmount, $U: puploads, $W: posix.join(root, 'Naila', 'Workspace', c.run.role), $H: tree.home, $S: cwd.replace(/[^a-zA-Z0-9]/g, '-') }
    const input = subst(c.input, tok)
    if (/\$[A-Za-z]/.test(JSON.stringify(input))) { bad(`${c.id} ${c.what}: a path token is left in ${JSON.stringify(input)}`); continue }
    const ctx = { phase: c.run.phase, vaultRoot: root, vaultMount: pmount, vaultExclude: ph.exclude, uploadsRoot: puploads, workRoot: join(tp, tree.work), claudeHome: tree.home }
    const run = { worker: c.run.role, on: c.run.on, ...(c.run.origin === undefined ? {} : { origin: c.run.origin }), asked: c.run.asked }
    let core, policy
    try {
      core = hookEnv(run, ctx)
      const on = new Set(run.on)
      const stub = { state: () => Object.fromEntries([...CAPABILITY_IDS.map((x) => [x, on.has(x) ? 'on' : 'off']), ...NOT_AVAILABLE.map((x) => [x, 'unavailable'])]), servers: () => [] }
      policy = policyFor(run.worker, stub, ctx, { ...(run.origin === undefined ? {} : { origin: run.origin }), asked: run.asked })
    } catch (e) { bad(`${c.id} ${c.what}: the core's policy throws: ${e.message}`); continue }
    const theirs = await port(c, policy, input, cwd)
    const [hook, ...args] = hookArgs(c, root, exclude, undefined, puploads)
    const r = spawnSync(process.execPath, [join(FILES, hook), ...args], { cwd, input: JSON.stringify({ tool_name: c.tool, tool_input: input, cwd }),
      env: { PATH: process.env.PATH, ...core, HARNESS_WEB_SLOTS: slotsWith() }, encoding: 'utf8', timeout: 20000 })
    if (r.status !== 0) { bad(`${c.id} ${c.what}: ${hook} exited ${r.status}: ${(r.stderr ?? '').trim().split('\n').pop()}`); continue }
    const want = c.hook ?? c.expect, mine = /"permissionDecision":"deny"/.test(r.stdout) ? 'deny' : 'allow', portV = theirs.ok ? 'allow' : 'deny'
    if (mine !== want || portV !== want) { bad(`${c.id} ${c.what}: ${hook} ${mine}s, the port ${portV}s, want ${want} ${r.stdout.trim()} ${theirs.reason ?? ''}`); continue }
    if (want === 'deny' && [PRIVATE_SEARCH_REFUSAL, PRIVATE_REFUSAL].includes(theirs.reason) && reasonOf(r) !== theirs.reason) { bad(`${c.id} ${c.what}: ${hook} says ${JSON.stringify(reasonOf(r))}, the port ${JSON.stringify(theirs.reason)}`); continue }
    pagree++
  }
  // the rest of this script runs as cases.json's roles
  uninstallRosterForTests(); installRoster(rosterFrom(parseWorkerSpecs(JSON.stringify(roles), () => '')))
}
console.log(`${pagree}/${pn} private folder cases agree (cases-private.json through the hook and the port)`)

// Homelab-only checks of the web guard (what the shared cases can't state: its flag, its env, its slots folder, its deadline)
const R = { HARNESS_CAPS: 'web.search,web.open' }
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
web('without --by-worker (the RC lines), a web run\'s public page', [], { ...R, HARNESS_WEB_SLOTS: slotsWith() }, PAGE, PUBLIC, 'deny', WEB_TEXT.askResearcher, [])
web('without --by-worker, a web run\'s search', [], { ...R, HARNESS_WEB_SLOTS: slotsWith() }, SEARCH, {}, 'deny', WEB_TEXT.askResearcher, [])
web('with --by-worker, no HARNESS_CAPS', ['--by-worker'], { HARNESS_WEB_SLOTS: slotsWith() }, SEARCH, {}, 'deny', WEB_TEXT.askResearcher, [])
web('with --by-worker, HARNESS_CAPS empty', ['--by-worker'], { HARNESS_CAPS: '', HARNESS_WEB_SLOTS: slotsWith() }, SEARCH, {}, 'deny', WEB_TEXT.askResearcher, [])
web('web switches named in the tool input only', ['--by-worker'], { HARNESS_CAPS: 'files.read,vault.read', HARNESS_WEB_SLOTS: slotsWith() },
  JSON.stringify({ tool_name: 'WebSearch', tool_input: { query: 'x', HARNESS_CAPS: R.HARNESS_CAPS, caps: ['web.search', 'web.open'] }, HARNESS_CAPS: R.HARNESS_CAPS, agent_type: 'scout', worker: 'scout' }), {}, 'deny', WEB_TEXT.askResearcher, [])
{
  const d = slotsWith()
  web('HARNESS_CAPS web.search,files.read is refused (a web switch beside another one)', ['--by-worker'], { HARNESS_CAPS: 'web.search,files.read', HARNESS_WEB_SLOTS: d }, SEARCH, {}, 'deny', WEB_TEXT.askResearcher, [],
    () => (slotCount(d).search === 0 ? [] : [`took a slot: ${JSON.stringify(slotCount(d))}`]))
}
{
  const d = slotsWith()
  web('HARNESS_CAPS web.search alone allows a search', ['--by-worker'], { HARNESS_CAPS: 'web.search', HARNESS_WEB_SLOTS: d }, SEARCH, {}, 'allow', undefined, [],
    () => (JSON.stringify(slotCount(d)) === JSON.stringify({ search: 1, open: 0 }) ? [] : [`slots ${JSON.stringify(slotCount(d))} after, want one search`]))
}
{
  const d = slotsWith()
  web(`HARNESS_WORKER=naila with web switches still decides by switches`, ['--by-worker'], { ...R, HARNESS_WORKER: 'naila', HARNESS_WEB_SLOTS: d }, SEARCH, {}, 'allow', undefined, [],
    () => (slotCount(d).search === 1 ? [] : [`slots ${JSON.stringify(slotCount(d))} after, want one search`]))
}
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
const writeDeadline = deadline('harness-write-guard.mjs', [join(FILES, 'harness-write-guard.mjs'), '--root', `/vault/${WS}`, '--private-root', '/vault/Private'],
  { HARNESS_WORKER: LEAD, HARNESS_WEB_SLOTS: slotsWith() }, '{"tool_name":"Wri')
await deadline('web-guard.mjs', ['--import', stub, join(FILES, 'web-guard.mjs'), '--by-worker'], { ...R, HARNESS_WEB_SLOTS: slotsWith(), STUB_DNS: '{}' }, SEARCH.slice(0, 10))
await writeDeadline

// Homelab-only checks of the write guard: in a run marked researched every write tool is refused, the servers' write tools
// too; a run with no slots folder is refused (fail closed); without the marker the servers' tools are the settings' to decide
// The refusal is the core's own (naila's RESEARCHED_WRITE_REFUSED, from its built dist): one text for a researched write,
// whichever side refuses it. It offers no plan: an addition after a search has no plan form, it waits for the next message.
const researchJs = join(naila, 'packages/harness/dist/research.js')
const RESEARCHED_TEXT = existsSync(researchJs) ? (await import(researchJs)).RESEARCHED_WRITE_REFUSED : undefined
if (typeof RESEARCHED_TEXT !== 'string' || !RESEARCHED_TEXT) bad(`naila's built ${researchJs} has no RESEARCHED_WRITE_REFUSED: build naila first (npm run build)`)
else if (!wgSrc.includes(`const RESEARCHED_TEXT = ${JSON.stringify(RESEARCHED_TEXT)}\n`)) bad(`harness-write-guard.mjs's RESEARCHED_TEXT is not naila's RESEARCHED_WRITE_REFUSED (${JSON.stringify(RESEARCHED_TEXT)})`)
if (/file a plan/i.test(RESEARCHED_TEXT ?? '')) bad('the researched write refusal offers a plan: an addition after a search has none')
const wroot = join(t, tree.phases.real.root)
const write = (what, tool, toolInput, env, want, reason) => {
  extra++
  const r = spawnSync(process.execPath, [join(FILES, 'harness-write-guard.mjs'), '--root', `${wroot}/${WS}`, '--private-root', `${wroot}/Private`],
    { cwd: join(t, tree.work, LEAD), input: JSON.stringify({ tool_name: tool, tool_input: toolInput }), env: { PATH: process.env.PATH, HARNESS_WORKER: LEAD, ...env }, encoding: 'utf8', timeout: 20000 })
  const o = out(r), got = r.stdout.trim() === '' ? 'none' : o?.permissionDecision, why = []
  if (r.status !== 0) why.push(`exit ${r.status}`)
  if (got !== want) why.push(`decision ${got}, want ${want}`)
  if (reason !== undefined && o?.permissionDecisionReason !== reason) why.push(`reason ${JSON.stringify(o?.permissionDecisionReason)}, want ${JSON.stringify(reason)}`)
  if (why.length) bad(`harness-write-guard.mjs ${what}: ${why.join('; ')}`)
}
// every case the shared suite allows (a write in the run's own workspace) is refused once the run is marked, or has no slots
for (const c of cases.filter((x) => x.claude === 'hook:write-guard' && (x.hook ?? x.expect) === 'allow')) {
  const root = join(t, tree.phases[c.run.phase].root)
  const tok = { $V: mount, $U: uploads, $W: posix.join(root, 'Naila', 'Workspace', c.run.role), $H: tree.home, $S: '' }
  write(`${c.id} (${c.what}) in a run marked researched`, c.tool, subst(c.input, tok), { HARNESS_WEB_SLOTS: slotsWith({}, true) }, 'deny', RESEARCHED_TEXT)
  write(`${c.id} (${c.what}) with no HARNESS_WEB_SLOTS`, c.tool, subst(c.input, tok), {}, 'deny')
  write(`${c.id} (${c.what}) with a slots folder that is gone`, c.tool, subst(c.input, tok), { HARNESS_WEB_SLOTS: join(slotsWith(), 'gone') }, 'deny')
  write(`${c.id} (${c.what}) with a relative HARNESS_WEB_SLOTS`, c.tool, subst(c.input, tok), { HARNESS_WEB_SLOTS: 'web' }, 'deny')
}
const ws = `${wroot}/Naila/Workspace/${LEAD}`
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
process.exit(fail || agree !== n || dagree !== dn || pagree !== pn ? 1 : 0)
EOF
node "$priv/run.mjs" "$repo" "$naila" "$cases" "$priv/dns-stub.mjs" "$priv/config"
