// PreToolUse hook for WebSearch and WebFetch. Only the finance-advisor subagent may use the web (Claude Code puts
// agent_type in the hook input for subagent calls, none for the main session), and it may fetch only https pages on
// the sites below: official sources and major Indonesian financial news. Everything else is denied, so a web page or
// document can't steer it into sending budget data to a site of its choosing; long query strings are refused too, so
// data can't ride along to an allowed site either. Exits 0 with a decision either way.
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

if (e.agent_type !== 'finance-advisor') decide('deny', 'Only the finance advisor may use the web.')
else if (e.tool_name === 'WebSearch') decide('allow', 'finance advisor web search')
else if (e.tool_name === 'WebFetch') {
  let host = '', https = false, query = ''
  try { const u = new URL(e.tool_input?.url ?? ''); host = u.hostname.toLowerCase(); https = u.protocol === 'https:'; query = u.search } catch { /* not a URL */ }
  const site = https && SITES.some((s) => host === s || host.endsWith('.' + s))
  if (!site) decide('deny', `Not an allowed site (${host || 'no host'}). Allowed: ${SITES.join(', ')}`)
  else if (query.length > 120) decide('deny', 'Query string too long: fetch the page without it, or search instead.')
  else decide('allow', `allowed site ${host}`)
} else decide('deny', 'Not a web tool.')
