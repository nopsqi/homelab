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
const paths = [i.file_path, i.path, typeof i.pattern === 'string' && isAbsolute(i.pattern) ? i.pattern : undefined]
  .filter((p) => typeof p === 'string' && p).map((p) => real(resolve(e.cwd ?? '/', p.replace(/^~(?=\/|$)/, '/home/claude'))))
const inside = (p) => p === '/home/claude/.claude.json' || ((p === CLAUDE || p.startsWith(CLAUDE + '/')) && !OK.some((r) => r.test(p)))
// A Glob or Grep rooted above ~/.claude (/home/claude, /home, /) would search inside it.
const above = (p) => e.tool_name !== 'Read' && (p === '/' || CLAUDE.startsWith(p.replace(/\/\*\*.*$/, '').replace(/\/+$/, '') + '/'))
const deny = (why) => console.log(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: why } }))
if (!e.tool_name || paths.some(inside)) deny('Under ~/.claude only uploads/ (files the user sent) and tool-results/ may be read.')
else if (paths.some(above)) deny('That search would include ~/.claude: search a narrower folder (the vault, an upload folder, your own folder).')
