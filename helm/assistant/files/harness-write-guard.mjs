// PreToolUse hook for the harness runs' writes: Write and Edit (files.write), MultiEdit and NotebookEdit (always refused), and
// the vault and finance-notes servers' write tools (mcp__vault__write_inbox, mcp__vault__append_daily,
// mcp__vault__workers_write, mcp__finance-notes__*).
// Researched runs first: once a researcher report came back in a run's chain, the core puts an empty file named
// `researched` (naila's WEB_RESEARCHED_MARKER) in the run's own web slots folder HARNESS_WEB_SLOTS, and from then on every
// one of these tools is refused (web text may have shaped the call). The core sets HARNESS_WEB_SLOTS beside HARNESS_WORKER
// and HARNESS_CAPS for every tools run, and this hook serves only those (it is in the harness settings alone), so a run with
// no HARNESS_WORKER, or with one but no HARNESS_WEB_SLOTS naming a folder, is refused too (fail closed). With no marker,
// the servers' tools are left to the run's settings (no decision here).
// Write and Edit may then write only inside the run's own workspace,
// <root>/<worker>/, where root (<VAULT_ROOT>/Naila/Workspace) comes from --root on the hook's command line, rendered by
// harness-start.sh, never from the run's env (P18), and the worker from HARNESS_WORKER, which the core sets per run.
// The path is resolved first: no `..`, the real path of its nearest existing ancestor (so a link can't lead out), the
// workspace itself may not be a link, and an existing target must be a plain file with one link (a hardlink could be
// another name for a file outside). Anything else, a missing --root or worker included, is a deny; the hook command adds
// `|| exit 2`, so a crash blocks too. Inside the workspace it decides nothing: the run's settings still have to allow the
// write (files.write on), so this guard alone never opens a write.
// Claude Code lets a call through when a hook times out (unless the settings say onFailure "block", which harness-start.sh
// sets), so this hook also stops itself: if its input has not ended within DEADLINE_MS it refuses with exit 2.
import { lstatSync, realpathSync, statSync } from 'node:fs'
import { posix } from 'node:path'

/** naila's WEB_RESEARCHED_MARKER (packages/harness/src/floor/web-rules.ts). */
const RESEARCHED_MARKER = 'researched'
const RESEARCHED_TEXT = "A web search happened in this message, so nothing can be written in it: file a plan, or ask again in a message of its own."
/** The tools the marker stops. */
const MARKED = new Set(['Write', 'Edit', 'MultiEdit', 'NotebookEdit', 'mcp__vault__write_inbox', 'mcp__vault__append_daily', 'mcp__vault__workers_write'])
const marked = (t) => typeof t === 'string' && (MARKED.has(t) || t.startsWith('mcp__finance-notes__'))

const deny = (why) => {
  console.log(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: why } }))
  process.exit(0)
}
/** The hook's own hard deadline, well inside the settings' hook timeout (30 s). Unref'd: it never keeps a decided hook alive. */
const DEADLINE_MS = 15000
const DEADLINE_TEXT = 'The write check took too long, so the write is refused.'
setTimeout(() => {
  console.log(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: DEADLINE_TEXT } }))
  console.error(DEADLINE_TEXT)
  process.exit(2)
}, DEADLINE_MS).unref()
let input = ''
for await (const chunk of process.stdin) input += chunk
// no `..` or `.` segment, no backslash, no control character (NUL, newline, …)
const plain = (p) => typeof p === 'string' && p.startsWith('/') && !/[\\\x00-\x1f]/.test(p) && !p.split('/').some((s) => s === '..' || s === '.')
try {
  const at = process.argv.indexOf('--root')
  const rootArg = at < 0 ? undefined : process.argv[at + 1]
  if (!plain(rootArg) || !/^\/[A-Za-z0-9._ /-]+$/.test(rootArg)) deny('No workspace root is set for this run, so nothing may be written.')
  const w = process.env.HARNESS_WORKER ?? ''
  if (!/^[a-z][a-z0-9-]*$/.test(w)) deny('This run has no worker, so it has no workspace to write in.')
  let e = {}
  try { e = JSON.parse(input) } catch { deny('Unreadable tool call.') }
  const t = e?.tool_name
  if (!marked(t)) deny('Not a write tool.')
  const slots = process.env.HARNESS_WEB_SLOTS
  if (!plain(slots)) deny("This run has no web slots folder (HARNESS_WEB_SLOTS), so nothing may be written.")
  if (!statSync(slots).isDirectory()) deny("This run's web slots folder is missing, so nothing may be written.")
  try { lstatSync(posix.join(slots, RESEARCHED_MARKER)); deny(RESEARCHED_TEXT) } catch (x) { if (x?.code !== 'ENOENT') throw x }
  if (t.startsWith('mcp__')) process.exit(0)   // a server's write tool, no marker: the run's settings decide
  if (t !== 'Write' && t !== 'Edit') deny('Not a write tool.')
  const p = e.tool_input?.file_path
  const where = `${rootArg.replace(/\/+$/, '')}/${w}/`
  if (!plain(p)) deny(`Write only with a plain absolute path (no ..) inside your workspace ${where}`)
  const root = realpathSync(rootArg.replace(/\/+$/, '') || '/')
  const ws = posix.join(root, w)
  if (realpathSync(ws) !== ws) deny(`Your workspace ${where} is a link; nothing may be written there.`)
  // the nearest existing ancestor's real path, plus the part that doesn't exist yet
  let q = posix.normalize(p).replace(/\/+$/, '') || '/', rest = ''
  for (;;) {
    try { lstatSync(q); break } catch {
      if (q === '/') deny('Unresolvable path.')
      rest = `/${posix.basename(q)}${rest}`
      q = posix.dirname(q)
    }
  }
  const real = realpathSync(q) + rest
  if (!real.startsWith(`${ws}/`)) deny(`You may write only inside your workspace ${where}`)
  if (!rest) {
    const st = statSync(real)
    if (!st.isFile() || st.nlink !== 1) deny('Only a plain file (one link) in your workspace may be overwritten.')
  }
} catch {
  deny('The write could not be checked, so it is refused.')
}
// inside the workspace: no decision, the run's settings decide
