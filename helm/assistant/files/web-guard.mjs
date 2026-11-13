// PreToolUse hook for WebSearch and WebFetch: only the researcher reads the web (the Rule of Two: the one worker with the
// open web holds none of the user's data, and every other worker, which does, has no web).
// - With --by-worker (the harness runs, as harness-start.sh renders it): the run's worker and its switches come from the
//   run's env, set by the core alone (HARNESS_WORKER, and HARNESS_CAPS: the run's capabilities that are on, comma-separated),
//   never from the tool input. Every worker but the researcher is refused, and so is a run with no HARNESS_CAPS. The
//   researcher's call is then judged in the same steps, order and words as naila's decideWeb (packages/harness/src/floor/
//   web.ts): a search needs web.search and a free search slot; a page needs web.open, an https address with no user name,
//   password or port, a path and query of at most WEB_LIMITS.pathQuery characters, a host that is no IP literal and no
//   internal name (nor is its www./bare twin, which Claude Code's WebFetch follows by itself), a free page slot (peeked
//   before any lookup), then the host and its twins looked up together (dns.promises.lookup, all addresses, each raced
//   against WEB_LIMITS.resolveMs): the host must resolve, a twin may not exist, any other failure or any private address
//   refuses; then the page slot is claimed. No figure check on queries or addresses (the researcher's only input is its
//   ask, and the core guards that).
// - Without --by-worker (the RC lines, and any settings that predate this guard) every call is refused.
// The slots: one empty file per call in the run's own folder HARNESS_WEB_SLOTS (set by the core for that run alone),
// search-<n> or open-<n> for n = 1..cap, taken with an exclusive create, so two calls at once never take the same one. The
// core's `researched` marker in that folder is no slot. A missing folder or env keeps the web closed.
// Everything between the web-rules:begin and web-rules:end lines is naila's block, copied byte for byte (tests/floor-
// conformance.sh compares the two).
// Claude Code lets a call through when a PreToolUse hook times out, so this hook stops itself: if it has not decided within
// DEADLINE_MS it refuses with exit 2 (a block whatever its output). Otherwise it prints one decision and exits 0.
import { isIP } from 'node:net'
import dns from 'node:dns'
import { closeSync, lstatSync, openSync, statSync } from 'node:fs'
import { join } from 'node:path'
// web-rules:begin
/** The one worker that may read the web. */
export const WEB_WORKER = 'researcher'

/** The empty file the core writes into a run's web slots folder (HARNESS_WEB_SLOTS) once a researcher report came back in
 *  its chain: from then on the run's direct writes (the vault server's write tools, Write and Edit) are refused. */
export const WEB_RESEARCHED_MARKER = 'researched'

/** Per run: searches and page opens, the path-and-query length of an address, and the DNS lookup's time limit. */
export const WEB_LIMITS = Object.freeze({ searches: 20, pages: 40, pathQuery: 250, resolveMs: 5000 })

/** The refusal texts, word for word the same in the core and the hook. */
export const WEB_TEXT = Object.freeze({
  askResearcher: 'Ask the researcher: only the researcher reads the web.',
  figure: "That request carries a figure; ask without the user's numbers.",
  searchOff: 'Web search is switched off for you (capability web.search).',
  openOff: 'Opening web pages is switched off for you (capability web.open).',
  httpsOnly: 'Only https addresses can be opened.',
  userinfo: 'An address with a user name or password is refused: open the page without them.',
  port: 'Only the default https port is allowed: open the address without a port.',
  tooLong: 'Address too long: open a shorter page address, or search instead.',
  ipLiteral: 'An address must name a host, not an IP address.',
  internalHost: 'That host is internal (not a public domain name), so it is not opened.',
  unresolved: 'That host could not be resolved, so it is not opened.',
  privateHost: 'That host resolves to a private or internal address, so it is not opened.',
  searchCap: `This run has used its ${WEB_LIMITS.searches} searches.`,
  openCap: `This run has opened its ${WEB_LIMITS.pages} pages.`,
  noCounter: 'The web counter of this run is missing, so the web stays closed.',
  notWeb: 'Not a web tool.',
  unreadable: 'The tool call could not be read.',
})

// carriesFigures judges the ask text sent to the researcher, strictly (the researcher's own queries and pages are not
// judged: its only input is this ask).
// A currency marker next to digits, on either side: Rp, IDR or USD starting a word (any case, an optional dot after
// it) or $ or €, with at most 3 spaces or `.:+_-` between marker and digits. After digits, the word marker must also end
// its word ("5 rpm" is no amount).
const MARKER_BEFORE = /(?:(?<!\p{L})(?:rp|idr|usd)|[$€])[\s.:+_-]{0,3}\p{Nd}/iu
const MARKER_AFTER = /\p{Nd}[\s.:+_-]{0,3}(?:(?<!\p{L})(?:rp|idr|usd)(?!\p{L})|[$€])/iu
// A magnitude or currency word right after digits, with or without a space, an optional "-an" suffix ("5 jutaan"),
// standing alone ("50 rbx" is not one); or the shorthand M, K or T ("1,5 M", "5k"), strictly: "5 m" of metres counts too.
const MAGNITUDE_AFTER =
  /\p{Nd}\s{0,3}(?:(?:juta|jt|ribu|rb|miliar|milyar|triliun|rupiah|dollars?|dolar)(?:an)?|[mkt])(?!\p{L})/iu
// 6 or more digits, with at most one `.` or `,` between any two: an account-like number or a separated amount.
const DIGIT_RUN = /\p{Nd}(?:[.,]?\p{Nd}){5,}/u
// Digit groups joined by single spaces or hyphens, an optional + before them; 10 or more digits make an account or phone.
const DIGIT_GROUPS = /\+?\p{Nd}+(?:[ -]\p{Nd}+)+/gu
const MIN_GROUPED_DIGITS = 10

// The most percent-escapes decodeEscapes takes on; a text with more is refused unread (fail closed).
const MAX_ESCAPES = 2000

/** `text` with each percent-escape decoded on its own: at every escape the longest run of 1 to 4 escapes that decodes
 *  (one UTF-8 character) is decoded, and an escape that never decodes stays as it is, so one bad escape hides nothing.
 *  null when the text holds more than MAX_ESCAPES escapes. */
function decodeEscapes(text = '') {
  if ((text.match(/%[0-9a-f]{2}/gi) ?? []).length > MAX_ESCAPES) return null
  return text.replace(/(?:%[0-9a-f]{2})+/gi, (run) => {
    const esc = run.match(/%[0-9a-f]{2}/gi) ?? []
    let out = ''
    for (let i = 0; i < esc.length;) {
      let took = 0
      for (let len = Math.min(4, esc.length - i); len > 0 && took === 0; len--) {
        try { out += decodeURIComponent(esc.slice(i, i + len).join('')); took = len } catch { /* a shorter run, or none */ }
      }
      if (took === 0) { out += esc[i]; took = 1 }
      i += took
    }
    return out
  })
}

/** Whether `text` carries a figure: a currency marker next to digits; a magnitude word after digits (juta, jt, ribu, rb,
 *  miliar, milyar, triliun, rupiah, dollar, dolar, each with an optional "-an"; or M, K, T); a run of 6 or more digits ignoring `.` and `,` between them (so any
 *  1.234.567 or 1,234,567 amount); or 10 or more digits in groups joined by single spaces or hyphens (an account or phone
 *  number). On the safe side: the text is judged as given and with its percent-escapes decoded, each NFKC-normalized
 *  (fullwidth digits and signs) and with its format characters (\p{Cf}: zero-width and the like) removed. A text with
 *  more than MAX_ESCAPES percent-escapes carries a figure as far as this guard knows (fail closed). */
export function carriesFigures(text = '') {
  const raw = String(text ?? '')
  const decoded = decodeEscapes(raw)
  if (decoded === null) return true
  return [raw, decoded].some((t) => {
    const n = t.normalize('NFKC').replace(/\p{Cf}/gu, '')
    if (MARKER_BEFORE.test(n) || MARKER_AFTER.test(n) || MAGNITUDE_AFTER.test(n) || DIGIT_RUN.test(n)) return true
    return (n.match(DIGIT_GROUPS) ?? []).some((g) => g.replace(/\P{Nd}/gu, '').length >= MIN_GROUPED_DIGITS)
  })
}

// IPv4 ranges that are not public: this network, private, CGNAT, loopback, link-local (cloud metadata), private,
// IETF protocol assignments, documentation (3), the old 6to4 relay, private, benchmarking, multicast, reserved and
// broadcast.
const V4_NOT_PUBLIC = [
  ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8], ['169.254.0.0', 16], ['172.16.0.0', 12],
  ['192.0.0.0', 24], ['192.0.2.0', 24], ['192.88.99.0', 24], ['192.168.0.0', 16], ['198.18.0.0', 15],
  ['198.51.100.0', 24], ['203.0.113.0', 24], ['224.0.0.0', 4], ['240.0.0.0', 4],
]

/** A dotted IPv4 address (already checked by isIP) as a number. */
function v4Number(ip = '') {
  return ip.split('.').reduce((n, part) => n * 256 + Number(part), 0)
}

function v4Private(ip = '') {
  const n = v4Number(ip)
  return V4_NOT_PUBLIC.some(([base, bits]) => {
    const size = 2 ** (32 - Number(bits))
    return Math.floor(n / size) === Math.floor(v4Number(String(base)) / size)
  })
}

/** An IPv6 address (already checked by isIP, no zone) as its 8 groups of 16 bits; a dotted IPv4 tail becomes 2 groups. */
function v6Groups(ip = '') {
  let s = ip.toLowerCase()
  if (s.includes('.')) {
    const at = s.lastIndexOf(':') + 1
    const n = v4Number(s.slice(at))
    s = `${s.slice(0, at)}${Math.floor(n / 65536).toString(16)}:${(n % 65536).toString(16)}`
  }
  const halves = s.split('::')
  const head = halves[0] ? halves[0].split(':') : []
  const tail = halves.length > 1 && halves[1] ? halves[1].split(':') : []
  const fill = halves.length > 1 ? 8 - head.length - tail.length : 0
  return [...head, ...Array.from({ length: fill }, () => '0'), ...tail].map((g) => parseInt(g, 16))
}

/** The IPv4 address in the last 32 bits of IPv6 groups `g`. */
function embeddedV4(g = [0]) {
  const hi = g[6] ?? 0, lo = g[7] ?? 0
  return [hi >> 8, hi & 255, lo >> 8, lo & 255].join('.')
}

/** Whether `ip` is anything but a valid public address. Refused: every IPv4 range above; IPv4-mapped (::ffff:0:0/96)
 *  and NAT64 (64:ff9b::/96) addresses by their embedded IPv4; every IPv6 address outside global unicast 2000::/3 (so ::,
 *  ::1, IPv4-compatible ::/96, 100::/64, 64:ff9b:1::/48, unique-local fc00::/7, link-local fe80::/10, site-local fec0::/10
 *  and multicast ff00::/8); inside it, IETF protocol assignments 2001::/23 (Teredo included), documentation 2001:db8::/32
 *  and 3fff::/20, and 6to4 2002::/16. Also refused: any address with a zone id, and anything isIP rejects (another
 *  spelling such as 0x7f.0.0.1 or 2130706433, brackets, spaces, a host name, a non-string). */
export function isPrivateAddress(ip = '') {
  if (typeof ip !== 'string' || ip.includes('%')) return true
  const kind = isIP(ip)
  if (kind === 4) return v4Private(ip)
  if (kind !== 6) return true
  const g = v6Groups(ip)
  if (g.length !== 8 || g.some((x) => !(x >= 0 && x <= 0xffff))) return true
  const zero5 = g[0] === 0 && g[1] === 0 && g[2] === 0 && g[3] === 0 && g[4] === 0
  if (zero5 && g[5] === 0xffff) return v4Private(embeddedV4(g))
  if (g[0] === 0x64 && g[1] === 0xff9b && g[2] === 0 && g[3] === 0 && g[4] === 0 && g[5] === 0) return v4Private(embeddedV4(g))
  const first = g[0] ?? 0, second = g[1] ?? 0
  if ((first & 0xe000) !== 0x2000) return true
  if (first === 0x2001 && (second < 0x200 || second === 0xdb8)) return true
  if (first === 0x2002) return true
  if (first === 0x3fff && second < 0x1000) return true
  return false
}

/** Whether `host` names no public domain: with one trailing dot stripped ("localhost." is localhost), a name with no dot,
 *  "localhost", or a name ending in ".localhost", in any case. A missing or non-string host is judged as its string form. */
export function isInternalHost(host = '') {
  const h = String(host ?? '').toLowerCase().replace(/\.$/, '')
  return !h.includes('.') || h === 'localhost' || h.endsWith('.localhost')
}
// web-rules:end

/** The hook's own hard deadline, well inside the settings' hook timeout and well above the lookups' race. */
const DEADLINE_MS = 15000
const DEADLINE_TEXT = 'The web check took too long, so the call is refused.'

let done = false
const say = (decision, reason) =>
  JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: decision, permissionDecisionReason: reason } }) + '\n'
/** Prints the one decision and ends the process at once (a lookup still pending in the resolver's pool would keep it alive). */
const decide = (decision, reason, code = 0) => {
  if (done) return
  done = true
  process.stdout.write(say(decision, reason))
  if (code !== 0) process.stderr.write(reason + '\n')
  process.exit(code)
}
setTimeout(() => decide('deny', DEADLINE_TEXT, 2), DEADLINE_MS)

/** The run's slot folder: HARNESS_WEB_SLOTS when it is an absolute path to a folder, else undefined (no counter). */
function slotsDir() {
  const d = process.env.HARNESS_WEB_SLOTS ?? ''
  if (!d.startsWith('/')) return undefined
  try { return statSync(d).isDirectory() ? d : undefined } catch { return undefined }
}
const CAP = { search: WEB_LIMITS.searches, open: WEB_LIMITS.pages }
/** Whether a slot of `kind` is free, without taking it: room, full, or missing (no folder). Other errors throw. */
function room(kind) {
  const d = slotsDir()
  if (d === undefined) return 'missing'
  for (let n = 1; n <= CAP[kind]; n++) {
    try { lstatSync(join(d, `${kind}-${n}`)) } catch (e) { if (e?.code === 'ENOENT') return 'room'; throw e }
  }
  return 'full'
}
/** Takes the first free slot of `kind`: claimed, full, or missing (no folder). Other errors throw. */
function claim(kind) {
  const d = slotsDir()
  if (d === undefined) return 'missing'
  for (let n = 1; n <= CAP[kind]; n++) {
    try { closeSync(openSync(join(d, `${kind}-${n}`), 'wx', 0o600)); return 'claimed' } catch (e) {
      if (e?.code === 'EEXIST') continue
      if (e?.code === 'ENOENT' || e?.code === 'ENOTDIR') return 'missing'
      throw e
    }
  }
  return 'full'
}
/** The counter's answer as a refusal text, or undefined when it is room (peek) or claimed. */
function counted(kind, peek) {
  let r
  try { r = peek ? room(kind) : claim(kind) } catch { return WEB_TEXT.noCounter }
  if (r === (peek ? 'room' : 'claimed')) return undefined
  if (r === 'full') return kind === 'search' ? WEB_TEXT.searchCap : WEB_TEXT.openCap
  return WEB_TEXT.noCounter
}

/** A resolver error that means the name does not exist (or has no address): for a twin, no host to follow to. */
const NO_SUCH_NAME = new Set(['ENOTFOUND', 'ENODATA'])
/** One lookup, bounded by WEB_LIMITS.resolveMs: the addresses, `none` for a name that does not exist, or `failed` (any other
 *  error, the time running out, or an answer that is not a list). The resolver is dns.promises.lookup, read at call time. */
async function lookup(host) {
  let timer
  const expiry = new Promise((resolve) => { timer = setTimeout(() => resolve('failed'), WEB_LIMITS.resolveMs) })
  try {
    return await Promise.race([
      (async () => dns.promises.lookup(host, { all: true }))().then((a) => (Array.isArray(a) ? a.map((x) => x?.address) : 'failed')),
      expiry,
    ])
  } catch (e) {
    return typeof e?.code === 'string' && NO_SUCH_NAME.has(e.code) ? 'none' : 'failed'
  } finally {
    clearTimeout(timer)
  }
}
/** `host`, `host` without its leading "www.", and "www." + that, each once, `host` first (naila's webTwins). */
const webTwins = (host) => {
  const bare = host.replace(/^www\./, '')
  return [...new Set([host, bare, `www.${bare}`])]
}

/** The refusal text for this call, or undefined to allow it (the steps of naila's decideWeb, in its order). */
async function judge(e) {
  if (!process.argv.includes('--by-worker')) return WEB_TEXT.askResearcher
  const caps = process.env.HARNESS_CAPS
  if (caps === undefined || process.env.HARNESS_WORKER !== WEB_WORKER) return WEB_TEXT.askResearcher
  const on = new Set(caps.split(',').map((c) => c.trim()))
  if (e === null || typeof e !== 'object' || Array.isArray(e)) return WEB_TEXT.unreadable
  const search = e.tool_name === 'WebSearch'
  if (!search && e.tool_name !== 'WebFetch') return WEB_TEXT.notWeb
  const i = e.tool_input
  if (i === null || typeof i !== 'object' || Array.isArray(i)) return WEB_TEXT.unreadable
  const value = i[search ? 'query' : 'url']
  if (typeof value !== 'string') return WEB_TEXT.unreadable
  if (search) return on.has('web.search') ? counted('search', false) : WEB_TEXT.searchOff

  if (!on.has('web.open')) return WEB_TEXT.openOff
  let u
  try { u = new URL(value) } catch { return WEB_TEXT.httpsOnly }
  if (u.protocol !== 'https:') return WEB_TEXT.httpsOnly
  if (u.username !== '' || u.password !== '') return WEB_TEXT.userinfo
  if (u.port !== '') return WEB_TEXT.port
  if ((u.pathname + u.search).length > WEB_LIMITS.pathQuery) return WEB_TEXT.tooLong
  const host = u.hostname.replace(/^\[(.*)\]$/, '$1')
  if (isIP(host) !== 0) return WEB_TEXT.ipLiteral
  const twins = webTwins(host)
  if (twins.some((h) => isInternalHost(h))) return WEB_TEXT.internalHost
  const full = counted('open', true)
  if (full !== undefined) return full
  const answers = await Promise.all(twins.map((h) => lookup(h)))
  const own = answers[0]
  if (own === undefined || own === 'none' || own === 'failed' || own.length === 0) return WEB_TEXT.unresolved
  if (answers.some((a) => a === 'failed')) return WEB_TEXT.unresolved
  if (answers.some((a) => a !== 'none' && a !== 'failed' && a.some((ip) => isPrivateAddress(ip)))) return WEB_TEXT.privateHost
  return counted('open', false)
}

let input = ''
try { for await (const chunk of process.stdin) input += chunk } catch { input = '' }
let e
try { e = JSON.parse(input) } catch { e = undefined }
try {
  const no = await judge(e === undefined ? null : e)
  if (no === undefined) decide('allow', e.tool_name === 'WebSearch' ? 'web search (the researcher)' : 'public https page (the researcher)')
  else decide('deny', no)
} catch {
  decide('deny', 'The web check failed, so the call is refused.', 2)
}
