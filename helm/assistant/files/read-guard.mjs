// PreToolUse hook for Read, Glob and Grep. Under ~/.claude only two places may be read: the uploads folder (files the
// user sends from the Claude app land there) and a session's own tool-results (pages WebFetch saved, e.g. PDFs).
// Everything else there, and ~/.claude.json, is refused: the login, the workers' keys, test copies, transcripts.
// Paths are resolved first (.., symlinks), so a link inside uploads can't point back at the login.
// Anywhere else it decides nothing and the normal permission rules apply.
// --by-origin (the harness runs, Ruling 16): of the uploads only uploads/<HARNESS_ORIGIN>/ may be read, the folder of the
// channel the run's conversation came from (the core sets HARNESS_ORIGIN per run). A missing or malformed HARNESS_ORIGIN (not
// ^[a-z][a-z0-9-]{0,31}$: the scheduler's runs, an image older than naila 95dd7a2) opens no upload at all. The run's own
// Read allow is narrowed the same way by the core; this is the defence in depth. Without flags (the RC lines) as before.
// --private-root DIR (workers by plan Task 13; the harness runs, required with --by-origin: <VAULT_ROOT>/Private, the private
// roles' folders): a Read, Glob or Grep whose path, as given or real, lies under DIR/<entry> is denied unless <entry> is the
// run's own folder, HARNESS_PRIVATE_OWN (which the core sets for a private role's run alone) when it is exactly
// DIR/<HARNESS_WORKER>; so every other role, the lead included, is kept out of every entry, one under its own id too. A Glob
// or Grep rooted at DIR, or at any folder above it (the vault root, /), is refused with the core's words: its root is an
// absolute Glob pattern's literal folders (up to its first wildcard segment), else its `path`, else the cwd. Names compare
// case-insensitively (NFC, lower case), DIR as named and as its real path. A missing, empty, relative or dotted DIR denies
// every call.
// Fix round 2 of batch D: with --by-origin (or --private-root) a run reads only its own session's tool-results:
// ~/.claude/projects/<P>/<session_id>/tool-results/, where <P> is the folder of its transcript and both come from Claude
// Code's own hook input (transcript_path ~/.claude/projects/<P>/<session_id>.jsonl, session_id), never from the model. Each
// role runs in its own folder, so <P> is the role's: no run reads another session's saved outputs, another role's (a private
// role's) above all. Hook input without them, or not of that shape, opens no tool-results. Without flags as before.
import { realpathSync } from 'node:fs'
import { dirname, isAbsolute, resolve } from 'node:path'

const CLAUDE = '/home/claude/.claude'
const byOrigin = process.argv.includes('--by-origin')
const o = process.env.HARNESS_ORIGIN
const origin = typeof o === 'string' && /^[a-z][a-z0-9-]{0,31}$/.test(o) ? o : undefined   // as the core's CHANNEL_NAME
const UPLOADS = !byOrigin ? /^\/home\/claude\/\.claude\/uploads(\/|$)/ : origin ? new RegExp(`^/home/claude/\\.claude/uploads/${origin}(/|$)`) : undefined
const why = !byOrigin ? 'Under ~/.claude only uploads/ (files the user sent) and tool-results/ may be read.'
  : origin ? `Under ~/.claude only uploads/${origin}/ (files sent in this conversation's channel) and tool-results/ may be read.`
  : 'Under ~/.claude only tool-results/ may be read: this run came from no channel, so no uploads are open to it.'

// the private folders (--private-root): naila's PRIVATE_SEARCH_REFUSAL and PRIVATE_REFUSAL (packages/harness/src/floor/paths.ts),
// word for word
const PRIVATE_SEARCH = 'search a folder: the vault root holds private folders'
const PRIVATE_TEXT = 'That folder is private: only the worker it belongs to may read or write it.'
const plainAbs = (p) => typeof p === 'string' && p.startsWith('/') && !/[\\\x00-\x1f\x7f]/.test(p) && !p.split('/').some((s) => s === '..' || s === '.')
const fold = (s) => s.normalize('NFC').toLowerCase().normalize('NFC')
const prAt = process.argv.indexOf('--private-root'), prArg = prAt < 0 ? undefined : process.argv[prAt + 1]
const needPrivate = byOrigin || prAt >= 0
const PR = needPrivate && plainAbs(prArg) ? prArg.replace(/\/+$/, '') : ''   // '' (none, or `/`): every call is denied
const worker = process.env.HARNESS_WORKER, ownEnv = process.env.HARNESS_PRIVATE_OWN
const ownName = PR && typeof worker === 'string' && /^[a-z][a-z0-9-]*$/.test(worker) && plainAbs(ownEnv) && ownEnv.replace(/\/+$/, '') === `${PR}/${worker}` ? fold(worker) : undefined

/** The real path of p, or of its nearest existing ancestor (globs and files that don't exist yet). */
const real = (p) => {
  let q = p.split(/[*?[{]/)[0].replace(/\/+$/, '') || '/'
  for (;;) { try { return realpathSync(q) + p.slice(q.length) } catch { if (q === '/') return p; q = dirname(q) } }
}

let input = ''
for await (const chunk of process.stdin) input += chunk
let e = {}
try { e = JSON.parse(input) } catch { /* unreadable: fall through to the deny below */ }
const i = e.tool_input ?? {}
const sid = typeof e.session_id === 'string' && /^[A-Za-z0-9-]{1,64}$/.test(e.session_id) ? e.session_id : undefined
const proj = sid === undefined || typeof e.transcript_path !== 'string' ? undefined
  : new RegExp(`^/home/claude/\\.claude/projects/([A-Za-z0-9-]{1,255})/${sid}\\.jsonl$`).exec(e.transcript_path)?.[1]
const RESULTS = !needPrivate ? /^\/home\/claude\/\.claude\/projects\/[^/]+\/[^/]+\/tool-results\//
  : proj === undefined ? undefined : new RegExp(`^/home/claude/\\.claude/projects/${proj}/${sid}/tool-results/`)
const OK = [UPLOADS, RESULTS].filter(Boolean)
const home = (p) => p.replace(/^~(?=\/|$)/, '/home/claude')
// Glob's pattern is a path (relative ones start at its `path` or the cwd); Grep's pattern is a regex, not a path.
const globPath = e.tool_name === 'Glob' && typeof i.pattern === 'string' ? resolve(home(i.path ?? e.cwd ?? '/'), home(i.pattern)) : undefined
const raw = [i.file_path, i.path, globPath].filter((p) => typeof p === 'string' && p).map((p) => resolve(e.cwd ?? '/', home(p)))
const paths = raw.map(real)
// A wildcard before ~/.claude ends (/home/claud*/…, /home/*/.claude/…) could match inside it; `..` after one could climb out.
const wild = (p) => { const k = p.search(/[*?[{]/); if (k < 0) return false; const lit = p.slice(0, k)
  // Braces hide paths (uploads/{x,../agents}/*): none under /home/claude, and no `..` anywhere after a wildcard.
  if (p.slice(k).includes('..') || (p.includes('{') && (p.startsWith('/home/claude/') || '/home/claude/'.startsWith(lit)))) return true
  return CLAUDE.startsWith(lit) || ((lit + '/').startsWith(CLAUDE + '/') && !OK.some((r) => r.test(lit))) }
const inside = (p) => p === '/home/claude/.claude.json' || ((p === CLAUDE || p.startsWith(CLAUDE + '/')) && !OK.some((r) => r.test(p)))
// A Glob or Grep rooted above ~/.claude (/home/claude, /home, /) would search inside it.
const above = (p) => e.tool_name !== 'Read' && (p === '/' || CLAUDE.startsWith(p.replace(/\/\*\*.*$/, '').replace(/\/+$/, '') + '/'))
// the private roots (as named and real, folded); a path under an entry of one but the run's own folder
const prs = PR ? [...new Set([PR, real(PR)])].map(fold) : []
const othersPrivate = (p) => { const f = fold(p); return prs.some((r) => f.startsWith(`${r}/`) && f.slice(r.length + 1).split('/')[0] !== ownName) }
// a Glob or Grep's root: an absolute pattern's literal folders, else its path, else the cwd; it may not be DIR or above it
const searchRoot = () => {
  const pat = e.tool_name === 'Glob' && typeof i.pattern === 'string' ? home(i.pattern) : undefined
  if (pat !== undefined && pat.startsWith('/')) { const segs = pat.split('/').slice(1), k = segs.findIndex((x) => /[*?]/.test(x)); return resolve(`/${(k < 0 ? segs : segs.slice(0, k)).join('/')}`) }
  return resolve(e.cwd ?? '/', home(typeof i.path === 'string' && i.path !== '' ? i.path : (e.cwd ?? '/')))
}
const atOrAbove = (x) => { const f = fold(x); return prs.some((r) => f === r || f === '/' || r.startsWith(`${f}/`)) }
const deny = (why) => console.log(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: why } }))
// Patterns get the plain wildcards only (*, ?, **: none of them climbs past a `/`). Braces can hold absolute or `..`
// alternatives, classes and escapes can spell `..` without the text: all refused, on the raw pattern, wherever the
// search starts. Covers Glob's pattern and Grep's file filter.
const pats = [e.tool_name === 'Glob' ? i.pattern : undefined, e.tool_name === 'Grep' ? i.glob : undefined].filter((p) => typeof p === 'string')
const sneaky = pats.some((p) => /[{}[\]\\]/.test(p) || p.includes('..'))
if (needPrivate && !PR) deny('No private root is set for this run, so nothing may be read.')
else if (sneaky) deny('Use plain wildcards only (*, ?, **) in file patterns: no {braces}, [classes], backslashes or `..`. Search twice instead of using braces.')
else if (!e.tool_name || paths.some(inside) || raw.some(wild)) deny(why)
else if (paths.some(above)) deny('That search would include ~/.claude: search a narrower folder (the vault, an upload folder, your own folder).')
else if (PR && e.tool_name !== 'Read' && (() => { const r = searchRoot(); return [r, real(r)].some(atOrAbove) })()) deny(PRIVATE_SEARCH)
else if (PR && [...raw, ...paths].some(othersPrivate)) deny(PRIVATE_TEXT)
