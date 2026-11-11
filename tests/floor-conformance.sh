#!/usr/bin/env bash
# Usage: tests/floor-conformance.sh <naila-dir>
# The chart side of naila's floor conformance suite (spec §5.3.6). naila's packages/harness/test/floor/cases.json holds the
# permission cases; its floor-conformance.test.ts decides each one with the core's ports of the chart hooks (decidePath,
# decideFetch, grantDocs). This script runs every case tagged hook:<name> through that hook in helm/assistant/files/, so a
# port and its hook can't drift apart:
#  - it builds the cases' `tree` in a temp folder T, and runs the hook as harness-start.sh (or claude.yaml, web-guard) renders
#    it: read-guard.mjs --by-origin; harness-write-guard.mjs --root <phase root>/Naila/Workspace; docs-grant.mjs --by-caps
#    --uploads <uploads> --root <phase root> [--exclude <phase root>/<VAULT_EXCLUDE dir>,…] (real phase); web-guard.mjs. The
#    rendered /vault and /home/claude/.claude/uploads don't exist here, so --root and --uploads name T's (F14); a path under
#    ~/.claude stays the literal /home/claude/.claude;
#  - it pipes the Claude Code hook input {tool_name, tool_input, cwd} (cwd: T/work/<worker>, also the hook's own) into the hook, with
#    HARNESS_CAPS (the case's capabilities, comma-joined), HARNESS_WORKER and HARNESS_ORIGIN (unset for a run from no channel)
#    in its env, and checks that it prints a deny exactly when the case says so: `hook` where a ruling makes the core
#    stricter than the hook (named in `ruling`), else `expect`. A hook that exits non-zero fails the case (it would block,
#    but no case expects a crash);
#  - it checks that harness-start.sh and claude.yaml still render those hook commands, and that web-guard.mjs's SITES are
#    naila's WEB_SITES, in order (F26: both read from the source files, packages/harness/src/floor/web.ts, so no build of
#    naila is needed and a stale dist can't hide a drift).
# Node only: no containers, no network. Asked runs' hook cases are refused (their HARNESS_CAPS would need the core's asked
# subtraction; none exists today).
set -euo pipefail
naila="${1:?usage: tests/floor-conformance.sh <naila-dir>}"
repo="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cases="$naila/packages/harness/test/floor/cases.json"
[ -f "$cases" ] || { echo "FAIL: no cases at $cases"; exit 2; }
priv="$(mktemp -d)"
trap 'rm -rf "$priv"' EXIT
export TMPDIR="$priv"
cat > "$priv/run.mjs" <<'EOF'
import { spawnSync } from 'node:child_process'
import { linkSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, posix } from 'node:path'

const [repo, naila, casesFile] = process.argv.slice(2)
const FILES = join(repo, 'helm/assistant/files')
const { tree, cases } = JSON.parse(readFileSync(casesFile, 'utf8'))
let fail = 0
const bad = (m) => { console.log(`FAIL: ${m}`); fail = 1 }

// F26: the web guard's sites are the core's, in order (each list read from its source: the strings between its `[` and `]`)
const listIn = (file, start) => {
  const src = readFileSync(file, 'utf8'), i = src.indexOf(start)
  if (i < 0) return undefined
  const body = src.slice(i + start.length, src.indexOf(']', i + start.length))
  return [...body.matchAll(/'([^']*)'/g)].map((m) => m[1])
}
const sites = listIn(join(FILES, 'web-guard.mjs'), 'const SITES = [')
const webSites = listIn(join(naila, 'packages/harness/src/floor/web.ts'), 'export const WEB_SITES: readonly string[] = [')
if (!sites?.length || !webSites?.length) bad('could not read web-guard.mjs SITES or naila WEB_SITES')
else if (JSON.stringify(sites) !== JSON.stringify(webSites)) bad(`web-guard.mjs SITES ${JSON.stringify(sites)} != naila WEB_SITES ${JSON.stringify(webSites)}`)
else console.log(`OK: web-guard.mjs SITES == naila WEB_SITES (${sites.length} sites, in order)`)

// the commands as the chart renders them (what the runs below reproduce with T's roots)
const start = readFileSync(join(FILES, 'harness-start.sh'), 'utf8'), claudeYaml = readFileSync(join(repo, 'helm/assistant/templates/claude.yaml'), 'utf8')
for (const [file, text, s] of [
  ['harness-start.sh', start, 'command: "node /config/read-guard.mjs --by-origin || exit 2"'],
  ['harness-start.sh', start, 'command: `node ${grant} --by-caps --uploads ${uploads} --root ${root}${docsExclude} || exit 2`'],
  ['harness-start.sh', start, 'const docsExclude = excluded.length ? ` --exclude ${excluded.map((x) => `${root}/${x}`).join(",")}` : ""'],
  ['harness-start.sh', start, 'command: `node /config/harness-write-guard.mjs --root ${root}/Naila/Workspace || exit 2`'],
  ['claude.yaml', claudeYaml, '"matcher": "WebFetch|WebSearch", "hooks": [{ "type": "command", "command": "node /config/web-guard.mjs" }]'],
]) if (!text.includes(s)) bad(`${file} no longer renders ${s}`)

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
    case 'hook:web-guard': return ['web-guard.mjs']
  }
}
const subst = (v, tok) => typeof v === 'string' ? v.replace(/\$[VUWHS]/g, (m) => tok[m])
  : Array.isArray(v) ? v.map((x) => subst(x, tok)) : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, subst(x, tok)])) : v

let n = 0, agree = 0
for (const c of cases.filter((x) => x.claude.startsWith('hook:'))) {
  n++
  if (c.run.asked) { bad(`${c.id}: an asked run's hook case (its HARNESS_CAPS would need the core's asked subtraction)`); continue }
  const ph = tree.phases[c.run.phase], root = join(t, ph.root)
  // only the real phase passes VAULT_EXCLUDE to the docs grant (harness-start.sh)
  const exclude = c.run.phase === 'real' ? ph.exclude : []
  const cwd = join(t, tree.work, c.run.worker)
  // the path tokens, as cases.json's `about` defines them ($S: Claude Code's project slug of the cwd)
  const tok = { $V: mount, $U: uploads, $W: posix.join(root, 'Naila', 'Workspace', c.run.worker), $H: tree.home, $S: cwd.replace(/[^a-zA-Z0-9]/g, '-') }
  const [hook, ...args] = hookArgs(c, root, exclude)
  const env = { PATH: process.env.PATH, HARNESS_CAPS: c.run.on.join(','), HARNESS_WORKER: c.run.worker, ...(c.run.origin === undefined ? {} : { HARNESS_ORIGIN: c.run.origin }) }
  const input = JSON.stringify({ tool_name: c.tool, tool_input: subst(c.input, tok), cwd })
  // in the run's cwd, as Claude Code runs a hook command
  const r = spawnSync(process.execPath, [join(FILES, hook), ...args], { cwd, input, env, encoding: 'utf8', timeout: 20000 })
  const want = c.hook ?? c.expect
  if (r.status !== 0) { bad(`${c.id} ${c.what}: ${hook} exited ${r.status}: ${(r.stderr ?? '').trim().split('\n').pop()}`); continue }
  const denied = /"permissionDecision":"deny"/.test(r.stdout)
  if (denied !== (want === 'deny')) { bad(`${c.id} ${c.what}: ${hook} ${denied ? 'denies' : 'does not deny'} (want ${want}) ${r.stdout.trim()}`); continue }
  agree++
  if (c.hook !== undefined) console.log(`OK: ${c.id} ${c.what}: ${hook} ${want}s it, the core denies it (${c.ruling})`)
}
console.log(`${agree}/${n} hook cases agree`)
process.exit(fail || agree !== n ? 1 : 0)
EOF
node "$priv/run.mjs" "$repo" "$naila" "$cases"
