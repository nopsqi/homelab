// PreToolUse hook for WebSearch and WebFetch. In a harness run (HARNESS_CAPS set by the core: the run's capabilities that are
// on, comma-separated), WebSearch is allowed only when it lists web.search and WebFetch only when it lists web.fetch, for
// whichever worker. Otherwise (the RC lines) only the finance-advisor subagent may use the web (Claude Code puts agent_type
// in the hook input for subagent calls, none for the main session). Either way it may fetch only https pages on
// the sites below: official sources and major Indonesian financial news. Everything else is denied, so a web page or
// document can't steer it into sending budget data to a site of its choosing; long addresses (path + query) are
// refused too, so data can't ride along to an allowed site either. Exits 0 with a decision either way.
const SITES = [
  'bi.go.id', 'ojk.go.id', 'lps.go.id', 'pajak.go.id', 'kemenkeu.go.id', 'idx.co.id', 'ksei.co.id',
  'bpjs-kesehatan.go.id', 'bpjsketenagakerjaan.go.id', 'bps.go.id', 'jdih.kemenkeu.go.id', 'peraturan.go.id',
  'bca.co.id', 'logammulia.com', 'pegadaian.co.id', 'bareksa.com',
  'kontan.co.id', 'bisnis.com', 'cnbcindonesia.com', 'katadata.co.id', 'kompas.com', 'investor.id', 'tempo.co',
]
const decide = (permissionDecision, permissionDecisionReason) =>
  console.log(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision, permissionDecisionReason } }))

let input = ''
for await (const chunk of process.stdin) input += chunk
let e = {}
try { e = JSON.parse(input) } catch { /* unreadable input: denied below */ }

const caps = process.env.HARNESS_CAPS
const on = (c) => caps.split(',').map((x) => x.trim()).includes(c)
if (caps !== undefined && e.tool_name === 'WebSearch' && !on('web.search')) decide('deny', 'Web search is switched off for you (capability web.search).')
else if (caps !== undefined && e.tool_name === 'WebFetch' && !on('web.fetch')) decide('deny', 'Fetching web pages is switched off for you (capability web.fetch).')
else if (caps === undefined && e.agent_type !== 'finance-advisor') decide('deny', 'Only the finance advisor may use the web.')
else if (e.tool_name === 'WebSearch') decide('allow', caps === undefined ? 'finance advisor web search' : 'web search (web.search on)')
else if (e.tool_name === 'WebFetch') {
  let host = '', https = false, rest = ''
  try { const u = new URL(e.tool_input?.url ?? ''); host = u.hostname.toLowerCase(); https = u.protocol === 'https:'; rest = u.pathname + u.search } catch { /* not a URL */ }
  const site = https && SITES.some((s) => host === s || host.endsWith('.' + s))
  if (!site) decide('deny', `Not an allowed site (${host || 'no host'}). Allowed: ${SITES.join(', ')}`)
  else if (rest.length > 250) decide('deny', 'Address too long: fetch a shorter page address, or search instead.')
  else decide('allow', `allowed site ${host}`)
} else decide('deny', 'Not a web tool.')
