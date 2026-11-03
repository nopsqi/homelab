// PreToolUse hook for Write and Edit in the harness runs (files.write). A run may write only inside its own workspace,
// <root>/<worker>/, where root (<VAULT_ROOT>/Naila/Workspace) comes from --root on the hook's command line, rendered by
// harness-start.sh, never from the run's env (P18), and the worker from HARNESS_WORKER, which the core sets per run.
// The path is resolved first: no `..`, the real path of its nearest existing ancestor (so a link can't lead out), the
// workspace itself may not be a link, and an existing target must be a plain file with one link (a hardlink could be
// another name for a file outside). Anything else, a missing --root or worker included, is a deny; the hook command adds
// `|| exit 2`, so a crash blocks too. Inside the workspace it decides nothing: the run's settings still have to allow the
// write (files.write on), so this guard alone never opens a write.
import { lstatSync, realpathSync, statSync } from 'node:fs'
import { posix } from 'node:path'

const deny = (why) => {
  console.log(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: why } }))
  process.exit(0)
}
let input = ''
for await (const chunk of process.stdin) input += chunk
const plain = (p) => typeof p === 'string' && p.startsWith('/') && !p.includes('\0') && !p.split('/').some((s) => s === '..' || s === '.')
try {
  const at = process.argv.indexOf('--root')
  const rootArg = at < 0 ? undefined : process.argv[at + 1]
  if (!plain(rootArg) || !/^\/[A-Za-z0-9._ /-]+$/.test(rootArg)) deny('No workspace root is set for this run, so nothing may be written.')
  const w = process.env.HARNESS_WORKER ?? ''
  if (!/^[a-z][a-z0-9-]*$/.test(w)) deny('This run has no worker, so it has no workspace to write in.')
  let e = {}
  try { e = JSON.parse(input) } catch { deny('Unreadable tool call.') }
  if (e.tool_name !== 'Write' && e.tool_name !== 'Edit') deny('Not a write tool.')
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
