// PreToolUse hook for Read, Glob and Grep. Under ~/.claude only two places may be read: the uploads folder (files the
// user sends from the Claude app land there) and a session's own tool-results (pages WebFetch saved, e.g. PDFs).
// Everything else there, and ~/.claude.json, is refused: the login, the workers' keys, test copies, transcripts.
// Paths are resolved first (.., symlinks), so a link inside uploads can't point back at the login.
// Anywhere else it decides nothing and the normal permission rules apply.
// --by-origin (the harness runs, Ruling 16): of the uploads only uploads/<HARNESS_ORIGIN>/ may be read, the folder of the
// channel the run's conversation came from (the core sets HARNESS_ORIGIN per run). A missing or malformed HARNESS_ORIGIN (not
// ^[a-z][a-z0-9-]{0,31}$: the scheduler's runs, an image older than naila 95dd7a2) opens no upload at all. The run's own
// Read allow is narrowed the same way by the core; this is the defence in depth. Without flags (the RC lines) as before.
import { realpathSync } from 'node:fs'
import { dirname, isAbsolute, resolve } from 'node:path'

const CLAUDE = '/home/claude/.claude'
const byOrigin = process.argv.includes('--by-origin')
const o = process.env.HARNESS_ORIGIN
const origin = typeof o === 'string' && /^[a-z][a-z0-9-]{0,31}$/.test(o) ? o : undefined   // as the core's CHANNEL_NAME
const UPLOADS = !byOrigin ? /^\/home\/claude\/\.claude\/uploads(\/|$)/ : origin ? new RegExp(`^/home/claude/\\.claude/uploads/${origin}(/|$)`) : undefined
const OK = [UPLOADS, /^\/home\/claude\/\.claude\/projects\/[^/]+\/[^/]+\/tool-results\//].filter(Boolean)
const why = !byOrigin ? 'Under ~/.claude only uploads/ (files the user sent) and tool-results/ may be read.'
  : origin ? `Under ~/.claude only uploads/${origin}/ (files sent in this conversation's channel) and tool-results/ may be read.`
  : 'Under ~/.claude only tool-results/ may be read: this run came from no channel, so no uploads are open to it.'

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
const deny = (why) => console.log(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: why } }))
// Patterns get the plain wildcards only (*, ?, **: none of them climbs past a `/`). Braces can hold absolute or `..`
// alternatives, classes and escapes can spell `..` without the text: all refused, on the raw pattern, wherever the
// search starts. Covers Glob's pattern and Grep's file filter.
const pats = [e.tool_name === 'Glob' ? i.pattern : undefined, e.tool_name === 'Grep' ? i.glob : undefined].filter((p) => typeof p === 'string')
const sneaky = pats.some((p) => /[{}[\]\\]/.test(p) || p.includes('..'))
if (sneaky) deny('Use plain wildcards only (*, ?, **) in file patterns: no {braces}, [classes], backslashes or `..`. Search twice instead of using braces.')
else if (!e.tool_name || paths.some(inside) || raw.some(wild)) deny(why)
else if (paths.some(above)) deny('That search would include ~/.claude: search a narrower folder (the vault, an upload folder, your own folder).')
