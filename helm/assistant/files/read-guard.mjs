// PreToolUse hook for Read, Glob and Grep. Under ~/.claude only two places may be read: the uploads folder (files the
// user sends from the Claude app land there) and a session's own tool-results (pages WebFetch saved, e.g. PDFs).
// Everything else there, and ~/.claude.json, is refused: the login, the workers' keys, test copies, transcripts.
// Paths are resolved first (.., symlinks), so a link inside uploads can't point back at the login.
// Anywhere else it decides nothing and the normal permission rules apply.
import { realpathSync } from 'node:fs'
import { dirname, isAbsolute, resolve } from 'node:path'

const CLAUDE = '/home/claude/.claude'
const OK = [/^\/home\/claude\/\.claude\/uploads(\/|$)/, /^\/home\/claude\/\.claude\/projects\/[^/]+\/[^/]+\/tool-results\//]

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
else if (!e.tool_name || paths.some(inside) || raw.some(wild)) deny('Under ~/.claude only uploads/ (files the user sent) and tool-results/ may be read.')
else if (paths.some(above)) deny('That search would include ~/.claude: search a narrower folder (the vault, an upload folder, your own folder).')
