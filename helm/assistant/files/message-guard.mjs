// PreToolUse hook for SendMessage. Cross-session messages stay inside Naila's office: Naila may message her own
// temporary subagents (recipient_kind "agent") and her workers' direct lines by name (/config/direct-lines); a worker's
// line may message Naila only; a temporary subagent (agent_id set) may message no one. Everything else is refused,
// including the user's sessions on other machines that Remote Control lists, and raw socket addresses.
import { readFileSync } from 'node:fs'

const lines = (() => { try { return readFileSync('/config/direct-lines', 'utf8').split('\n').map((l) => l.trim().split(/\s+/)[0]).filter(Boolean) } catch { return [] } })()
const named = (to, names) => names.some((n) => to === n || new RegExp(`^${n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}-[0-9a-f]+$`).test(to))
const deny = (why) => console.log(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: why } }))

let input = ''
for await (const chunk of process.stdin) input += chunk
let e = {}
try { e = JSON.parse(input) } catch { /* unreadable: denied below */ }
const i = e.tool_input ?? {}, to = String(i.to ?? i.recipient ?? ''), kind = i.recipient_kind

if (e.tool_name !== 'SendMessage') deny('Unreadable message request.')   // only registered for SendMessage
else if (e.agent_id) deny('A temporary subagent sends nothing: report back in your final answer.')
else if (!e.agent_type) {   // Naila
  // A subagent's address has a fixed form (a + 16 hex); the model's own recipient_kind label is not trusted.
  if ((kind === 'agent' && /^a[0-9a-f]{16}$/.test(to)) || named(to, lines)) { /* allowed */ } else deny(`Naila may message only her workers' lines (${lines.join(', ')}) and her own subagents.`)
} else if (lines.includes(e.agent_type)) {   // a worker's direct line
  if (to !== 'naila') deny('Workers message Naila only (to: "naila").')
} else deny('Not allowed to send messages.')
