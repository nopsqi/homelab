// Turns `claude -p --output-format stream-json --verbose` into the final answer plus one TRACE line: which
// subagents ran and the tools each one called (refused calls marked !), so a test can check routing, not just text.
import { createInterface } from 'node:readline'

const calls = new Map(), agents = new Map(), refused = new Set()
let answer = ''
for await (const line of createInterface({ input: process.stdin })) {
  let e; try { e = JSON.parse(line) } catch { continue }
  for (const c of e.message?.content ?? []) {
    if (c.type === 'tool_use') {
      calls.set(c.id, { name: c.name, input: c.input ?? {}, parent: e.parent_tool_use_id ?? null })
      if (c.input?.subagent_type) agents.set(c.id, c.input.subagent_type)
    }
    if (c.type === 'tool_result' && c.is_error) refused.add(c.tool_use_id)
  }
  if (e.type === 'result') answer = e.result ?? ''
}
const label = (id, c) => {
  let n = c.name.replace(/^mcp__/, '').replace('__', ':')
  if (c.name === 'WebFetch') { try { n += `(${new URL(c.input.url).hostname})` } catch { n += '(?)' } }
  if (c.name === 'Read' || c.name === 'Glob') n += `(${c.input.file_path ?? c.input.pattern ?? ''})`
  return refused.has(id) ? n + '!' : n
}
const by = new Map()
for (const [id, c] of calls) {
  if (agents.has(id)) continue
  const who = c.parent ? agents.get(c.parent) ?? 'subagent' : 'naila'
  by.set(who, [...(by.get(who) ?? []), label(id, c)])
}
console.log(answer)
console.log('TRACE agents=' + ([...new Set(agents.values())].join(',') || 'none') + ' | ' + [...by].map(([w, t]) => `${w}: ${t.join(' ')}`).join(' | '))
