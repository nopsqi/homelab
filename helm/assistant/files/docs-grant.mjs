// PreToolUse hook for mcp__docs__convert. The Claude app saves uploads owner-only (0600 in a 0700 folder), and the
// docs sidecar runs as another user (uid 1001, group 1000) on purpose, so it can't open them. Just before a
// conversion, this grants group read on that one file and group access to its folders up to uploads/: the owner
// (claude) can change the mode, the sidecar can't. Only real files under uploads/ after resolving symlinks and `..`,
// with one link (a hardlink in uploads/ can be another name for a file outside it); the vault is already readable
// and anything else is the sidecar's to refuse. It decides nothing.
import { chmodSync, realpathSync, statSync } from 'node:fs'
import { dirname } from 'node:path'

const UPLOADS = '/home/claude/.claude/uploads'

let input = ''
for await (const chunk of process.stdin) input += chunk
try {
  const p = JSON.parse(input).tool_input?.path
  const real = typeof p === 'string' && p.startsWith('/') ? realpathSync(p) : ''
  const st = real.startsWith(UPLOADS + '/') && statSync(real)
  if (st && st.isFile() && st.nlink === 1) {
    chmodSync(real, st.mode & 0o7777 | 0o040)
    for (let d = dirname(real); d.startsWith(UPLOADS + '/'); d = dirname(d)) chmodSync(d, statSync(d).mode & 0o7777 | 0o050)
  }
} catch { /* nothing granted: the sidecar reports what it can't read */ }
