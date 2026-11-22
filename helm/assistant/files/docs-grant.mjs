// PreToolUse hook for mcp__docs__convert. The Claude app saves uploads owner-only (0600 in a 0700 folder), and the
// docs sidecar runs as another user (uid 1001, group 1000) on purpose, so it can't open them. Just before a
// conversion, this grants group read on that one file and group access to its folders up to uploads/: the owner
// (claude) can change the mode, the sidecar can't. Only real files under uploads/ after resolving symlinks and `..`,
// with one link (a hardlink in uploads/ can be another name for a file outside it); the vault is already readable
// and anything else is the sidecar's to refuse. Without flags (the RC lines) it decides nothing.
// --by-caps --uploads DIR --root VAULT_ROOT (the harness runs): it follows the run's switches, from HARNESS_CAPS (the run's
// capabilities that are on, comma-separated), HARNESS_WORKER, HARNESS_ORIGIN (the channel the run's conversation came from)
// and HARNESS_DOCS_ROOTS (the folders the run's switches open, comma-separated, in order; '' for none), all set by the core
// per run (as web-guard.mjs and the write guard read them). The core decides the folders (naila's docsRoots: the vault with
// vault.read, a finance worker's Finance and the own workspace with files.read), so this hook names no worker. It allows
// only a plain file with one link whose real path lies under one of:
//   DIR/<HARNESS_ORIGIN>/, always (Ruling 16: a run converts only its own channel's uploads);  each HARNESS_DOCS_ROOTS entry.
// Each of those counts only when it is no link itself (its real path is where it says). And only with docs.convert on.
// Every other path is denied, and a file under DIR outside DIR/<HARNESS_ORIGIN>/ is denied even when another root holds it:
// the docs sidecar reads every upload through its group, so this deny is the only thing between a run and another channel's
// files. A missing or malformed HARNESS_ORIGIN (not ^[a-z][a-z0-9-]{0,31}$; the scheduler's runs have none, and an image
// older than naila 95dd7a2 sets none) opens no upload at all. It fails closed: a missing or unusable HARNESS_CAPS,
// HARNESS_WORKER or HARNESS_DOCS_ROOTS (an image older than the switches, or than the engine's docs roots, sets none, so its
// runs convert nothing; usable means every entry plain, at --root or under it, none empty, the whole value possibly ''), a
// missing or relative --uploads or --root, a path with `..` or `.` segments, a backslash or a control character, a root that
// is itself a link, or anything unreadable or unexpected is a deny (and the hook command adds `|| exit 2`, so a crash
// blocks too).
// --desk DIR (file actions: the pod's desk, HARNESS_DESK_ROOT, a plain absolute path): an HARNESS_DOCS_ROOTS entry is also
// usable when it lies strictly under DIR (the core gives a run only its own desk folder there, <DIR>/<worker> or
// <DIR>/_test/<worker>, with files.read); without the flag a desk entry is outside --root, so it denies everything, as
// before. A --desk with no value, or a relative or dotted DIR, denies everything.
// --exclude DIR[,DIR…] (the real phase: /vault/Harness-test) denies every path that is, after resolving symlinks and `..`,
// under one of those dirs, compared case-insensitively (the vault may be a case-insensitive share). It fails closed too: an
// empty or relative entry, or a path that can't be resolved, is a deny.
import { chmodSync, realpathSync, statSync } from 'node:fs'
import { dirname, posix } from 'node:path'

const UPLOADS = '/home/claude/.claude/uploads'
const deny = (why) => { console.log(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: why } })); process.exit(0) }
const argOf = (f) => { const i = process.argv.indexOf(f); return i < 0 ? undefined : process.argv[i + 1] }
// an absolute path with no `..` or `.` segment, no backslash, no control character (NUL, newline, …), as the write guard
const plain = (p) => typeof p === 'string' && p.startsWith('/') && !/[\\\x00-\x1f\x7f]/.test(p) && !p.split('/').some((s) => s === '..' || s === '.')

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
if (process.argv.includes('--by-caps')) {
  let ok = false, where = 'nowhere'
  try {
    const caps = process.env.HARNESS_CAPS, w = process.env.HARNESS_WORKER ?? '', o = process.env.HARNESS_ORIGIN, dr = process.env.HARNESS_DOCS_ROOTS
    const origin = typeof o === 'string' && /^[a-z][a-z0-9-]{0,31}$/.test(o) ? o : undefined   // as the core's CHANNEL_NAME
    const upArg = argOf('--uploads'), rootArg = argOf('--root'), withDesk = process.argv.includes('--desk'), deskArg = argOf('--desk')
    // exactly what the core writes: on capabilities joined by commas, no spaces, no empty entries (an empty string is none on)
    const usable = typeof caps === 'string' && /^(?:[a-z][a-z-]*\.[a-z][a-z-]*(?:,[a-z][a-z-]*\.[a-z][a-z-]*)*)?$/.test(caps)
    // the core's docs roots: '' is none; else each entry plain and at --root or under it (as named), none empty (the core
    // refuses a root holding a comma, so a comma only ever separates two)
    const v = typeof rootArg === 'string' ? rootArg.replace(/\/+$/, '') : ''   // as named, without a trailing / (no `//` below)
    const inRoot = (e) => plain(e) && (e === (v || '/') || e.startsWith(`${v}/`))
    // --desk: strictly under the desk (never the desk root itself), as named without a trailing /
    const desk = withDesk && plain(deskArg) ? deskArg.replace(/\/+$/, '') : ''
    const inDesk = (e) => desk !== '' && plain(e) && e.startsWith(`${desk}/`) && e.length > desk.length + 1
    const deskOk = !withDesk || desk !== ''
    const given = typeof dr !== 'string' ? undefined : dr === '' ? [] : dr.split(',')
    if (usable && deskOk && given?.every((e) => inRoot(e) || inDesk(e)) && /^[a-z][a-z0-9-]*$/.test(w) && plain(upArg) && plain(rootArg)) {
      const on = new Set(caps.split(',').filter(Boolean))
      const p = JSON.parse(input).tool_input?.path
      if (on.has('docs.convert') && plain(p)) {
        const up = realpathSync(upArg.replace(/\/+$/, '') || '/')
        // a folder counts only when it is no link itself (its real path is where it says)
        const own = (d) => { try { return realpathSync(d) === d ? [d] : [] } catch { return [] } }
        const mine = origin ? own(posix.join(up, origin)) : []
        const roots = [...mine, ...given.flatMap(own)]
        const u = upArg.replace(/\/+$/, '')   // as named, without a trailing /
        where = [...(origin ? [`${u}/${origin}`] : []), ...given].join(', ') || 'nowhere'
        const real = realpathSync(p)
        const st = statSync(real)
        const under = (r) => r !== '/' && real.startsWith(r + '/')
        // Ruling 16: another channel's upload is denied, whichever root would hold it
        const foreign = (real === up || under(up)) && !mine.some(under)
        // one link only: a second hard link would make a file outside the roots convertible under a name inside them
        ok = !foreign && roots.some(under) && st.isFile() && st.nlink === 1
      }
    }
  } catch { ok = false }
  if (!ok) deny(`You may convert only a plain file in ${where} (your capabilities decide which; docs.convert must be on).`)
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
