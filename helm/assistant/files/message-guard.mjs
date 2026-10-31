// PreToolUse hook for SendMessage. Cross-session messages stay inside Naila's pod: Naila may message her own
// temporary subagents and her workers' live lines; a worker's live line may message Naila only; a temporary subagent
// (agent_id set) messages no one. Recipients are resolved by place, not by name: every session here has a socket
// /tmp/cc-socks/<pid>.sock, and a live line is the session whose parent is `claude remote-control --name <line>`.
// The hook rewrites "naila" / "finance-bookkeeper" / … into that local address, so a session on another machine
// (Remote Control lists them too) or a test stand-in can never be the recipient, whatever its name.
import { readFileSync, readdirSync, statSync } from 'node:fs'

const SOCKS = '/tmp/cc-socks'
const workers = (() => { try { return readFileSync('/config/direct-lines', 'utf8').split('\n').map((l) => l.trim().split(/\s+/)[0]).filter(Boolean) } catch { return [] } })()
const say = (o) => console.log(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', ...o } }))
const deny = (why) => say({ permissionDecision: 'deny', permissionDecisionReason: why })

/** The live line a local session belongs to: the --name of the remote-control server that is its parent. */
const lineOf = (pid) => {
  try {
    const ppid = readFileSync(`/proc/${pid}/stat`, 'utf8').split(') ')[1].split(' ')[1]
    return /claude remote-control --name (\S+)/.exec(readFileSync(`/proc/${ppid}/cmdline`, 'utf8').replace(/\0/g, ' '))?.[1]
  } catch { return undefined }
}
/** Local address of a line's newest session, or undefined. */
const addressOf = (line) => {
  let best
  for (const f of (() => { try { return readdirSync(SOCKS) } catch { return [] } })()) {
    const pid = /^(\d+)\.sock$/.exec(f)?.[1]
    if (!pid || lineOf(pid) !== line) continue
    const t = statSync(`${SOCKS}/${f}`).mtimeMs
    if (!best || t > best.t) best = { t, addr: `uds:${SOCKS}/${f}` }
  }
  return best?.addr
}
/** Which line a requested recipient means: a line name, its listed name (finance-bookkeeper-0e), or one of our sockets. */
const wanted = (to, allowed) => {
  const u = /^uds:\/tmp\/cc-socks\/(\d+)\.sock$/.exec(to)
  if (u) { const l = lineOf(u[1]); return allowed.includes(l) ? l : undefined }
  return allowed.find((n) => to === n || new RegExp(`^${n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}-[0-9a-f]+$`).test(to))
}

let input = ''
for await (const chunk of process.stdin) input += chunk
let e = {}
try { e = JSON.parse(input) } catch { /* unreadable: denied below */ }
const i = e.tool_input ?? {}, to = String(i.to ?? i.recipient ?? '')
const sender = e.agent_id ? 'temp' : !e.agent_type ? 'naila' : workers.includes(e.agent_type) ? 'worker' : 'other'

if (e.tool_name !== 'SendMessage') deny('Unreadable message request.')   // only registered for SendMessage
else if (sender === 'temp') deny('A temporary subagent sends nothing: report back in your final answer.')
else if (sender === 'naila' && i.recipient_kind === 'agent' && /^a[0-9a-f]{16}$/.test(to)) { /* her own subagent: no decision */ }
else if (sender === 'other') deny('Not allowed to send messages.')
else {
  const line = wanted(to, sender === 'naila' ? workers : ['naila'])
  const addr = line && addressOf(line)
  if (!line) deny(sender === 'naila' ? `Naila may message only her workers' lines (${workers.join(', ')}).` : 'Workers message Naila only (to: "naila").')
  else if (!addr) deny(`${line}'s live line isn't running right now.`)
  else say({ permissionDecision: 'allow', permissionDecisionReason: `local ${line}`, updatedInput: { ...i, to: addr, ...(i.recipient !== undefined ? { recipient: addr } : {}) } })
}
