// PreToolUse hook for mcp__docs__convert. The Claude app saves uploads owner-only (0600 in a 0700 folder), and the
// docs sidecar runs as another user (uid 1001, group 1000) on purpose, so it can't open them. Just before a
// conversion, this grants group read on that one file and group access to its folders up to uploads/: the owner
// (claude) can change the mode, the sidecar can't. Only real files under uploads/ after resolving symlinks and `..`,
// with one link (a hardlink in uploads/ can be another name for a file outside it); the vault is already readable
// and anything else is the sidecar's to refuse. It decides nothing, except with --only ROOT[:ROOT…] (test runs): then it
// denies every path that isn't, after resolving symlinks and `..`, a file with one link under one of the roots. That mode fails closed:
// anything unreadable or unexpected is a deny (and the hook command adds `|| exit 2`, so a crash blocks too).
// --exclude DIR[,DIR…] (the real phase: /vault/Harness-test) denies every path that is, after resolving symlinks and `..`,
// under one of those dirs, compared case-insensitively (the vault may be a case-insensitive share). It fails closed too: an
// empty or relative entry, or a path that can't be resolved, is a deny.
import { chmodSync, realpathSync, statSync } from 'node:fs'
import { dirname } from 'node:path'

const UPLOADS = '/home/claude/.claude/uploads'
const at = process.argv.indexOf('--only')
const only = at < 0 ? undefined : (process.argv[at + 1] ?? '').split(':').filter((r) => r.startsWith('/'))
const deny = (why) => { console.log(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: why } })); process.exit(0) }

let input = ''
for await (const chunk of process.stdin) input += chunk
const ex = process.argv.indexOf('--exclude')
if (ex >= 0) {
  let ok = false
  try {
    const dirs = (process.argv[ex + 1] ?? '').split(',')
    const p = JSON.parse(input).tool_input?.path
    if (dirs.every((d) => d.startsWith('/')) && typeof p === 'string' && p.startsWith('/')) {
      const real = realpathSync(p).toLowerCase()
      // an excluded dir that doesn't exist still counts by its own name; one that does, by its real path as well
      const roots = dirs.flatMap((d) => { const r = [d.replace(/\/+$/, '')]; try { r.push(realpathSync(d)) } catch {} return r.map((x) => x.toLowerCase()) })
      ok = !roots.some((r) => real === r || real.startsWith(r + '/'))
    }
  } catch { ok = false }
  if (!ok) deny(`Documents in ${process.argv[ex + 1] ?? '(none)'} can't be converted here.`)
}
if (only) {
  let ok = false
  try {
    const p = JSON.parse(input).tool_input?.path
    const real = typeof p === 'string' && p.startsWith('/') ? realpathSync(p) : ''
    const roots = only.flatMap((r) => { try { return [realpathSync(r)] } catch { return [] } })
    const st = real ? statSync(real) : undefined
    // one link only: a second hard link would make a file outside the roots convertible under a name inside them
    ok = !!st && roots.some((r) => real.startsWith(r + '/')) && st.isFile() && st.nlink === 1
  } catch { ok = false }
  if (!ok) deny(`In this test run documents can be converted only from ${only.join(' or ')}.`)
}
try {
  const p = JSON.parse(input).tool_input?.path
  const real = typeof p === 'string' && p.startsWith('/') ? realpathSync(p) : ''
  const st = real.startsWith(UPLOADS + '/') && statSync(real)
  if (st && st.isFile() && st.nlink === 1) {
    chmodSync(real, st.mode & 0o7777 | 0o040)
    for (let d = dirname(real); d.startsWith(UPLOADS + '/'); d = dirname(d)) chmodSync(d, statSync(d).mode & 0o7777 | 0o050)
  }
} catch { /* nothing granted: the sidecar reports what it can't read */ }
