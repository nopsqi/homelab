#!/usr/bin/env bash
# Usage: tests/docs-grant.sh
# Runs helm/assistant/files/docs-grant.mjs --by-caps --uploads U --root R (the harness runs' mode) against files under a
# temp vault and uploads folder, with HARNESS_CAPS, HARNESS_WORKER, HARNESS_ORIGIN and HARNESS_DOCS_ROOTS in the env as the core
# sets them per run (HARNESS_DOCS_ROOTS by naila's docsRoots, core_roots below: the vault with vault.read, a finance worker's
# Finance and the own workspace with files.read; the hook itself names no worker):
#  - docs.convert must be on, and uploads are convertible only under uploads/<HARNESS_ORIGIN>/ (Ruling 16): another channel's
#    upload is denied (also through a link, a channel folder that is a link, or a --root that holds uploads/), and a missing or
#    malformed HARNESS_ORIGIN (not ^[a-z][a-z0-9-]{0,31}$) opens no upload at all;
#  - beyond the uploads, exactly the HARNESS_DOCS_ROOTS entries: the vault root only with vault.read; <root>/Finance/ only for
#    a finance worker with files.read (P28), or any worker the engine gives it; the worker's own <root>/Naila/Workspace/<worker>/
#    with files.read, never another worker's;
#  - it fails closed: no HARNESS_CAPS, an unusable HARNESS_CAPS or HARNESS_WORKER, no HARNESS_DOCS_ROOTS or an unusable one (an
#    empty entry, a relative or non-plain one, one outside --root), no --uploads or --root, or a relative one deny everything,
#    uploads included; HARNESS_DOCS_ROOTS '' is no root beyond the uploads;
#  - a file with a second hard link, a directory, a symlink out of an allowed root, a path with `..`, a backslash or a control
#    character, and a root (workspace, Finance or any entry) that is itself a link are denied;
#  - with --exclude DIR[,DIR…] (the real phase: the test folder), a file under an excluded dir, or a symlink into one, is
#    denied, a file beside it is not, and a malformed --exclude denies everything.
# Then the RC lines' mode (no flags): it never denies, as before the switches.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
hook="$root/helm/assistant/files/docs-grant.mjs"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
v="$tmp/vault" up="$tmp/uploads"
mkdir -p "$v/Daily" "$v/Finance" "$v/Naila/Workspace/naila" "$v/Naila/Workspace/finance-bookkeeper" "$v/Naila/Workspace/ops-oncall" \
  "$v/Harness-test/Naila" "$up/discord" "$up/test" "$tmp/outside"
echo a > "$v/Daily/x.md"
echo a > "$v/Finance/statement.pdf"
echo a > "$v/Naila/Workspace/naila/n.docx"
echo a > "$v/Naila/Workspace/finance-bookkeeper/b.xlsx"
echo a > "$v/Naila/Workspace/ops-oncall/o.docx"
echo a > "$up/discord/sent.pdf"
echo a > "$up/test/fixture.pdf"
ln -s "$up/discord/sent.pdf" "$up/test/into-discord.pdf"   # a link from the test channel's folder to a Discord upload
ln -s discord "$up/evil"                                   # a channel folder that is a link to another channel's
ln -s "$up/discord/sent.pdf" "$v/Daily/into-uploads.pdf"   # a vault note that is a link to a Discord upload
echo b > "$tmp/outside/secret.pdf"
echo b > "$tmp/outside/plain.pdf"
ln "$tmp/outside/secret.pdf" "$up/discord/linked.pdf"
ln -s "$tmp/outside/secret.pdf" "$up/discord/sym.pdf"
ln -s "$v/Finance/statement.pdf" "$up/discord/into-finance.pdf"
echo c > "$v/Harness-test/Naila/test.pdf"
ln -s "$v/Harness-test/Naila/test.pdf" "$v/Daily/into-test.pdf"
# a second vault whose workspace and Finance folders are links (into the first one's Daily)
v2="$tmp/vault2"
mkdir -p "$v2/Naila/Workspace"
ln -s "$v/Daily" "$v2/Naila/Workspace/naila"
ln -s "$v/Daily" "$v2/Finance"

fail=0
BK="docs.convert,files.read,messaging.ask,budget.read,budget.write-plans"   # the bookkeeper's seed: vault.read off
NA="docs.convert,files.read,messaging.ask,vault.read,vault.write"           # naila's seed
# The core's HARNESS_DOCS_ROOTS (naila floor/docs-grant.ts docsRoots) for CAPS, WORKER and the hook's --root: the vault with
# vault.read, Finance for a finance worker with files.read, the own workspace with files.read, comma-joined, no trailing /
core_roots() {
  local caps=",$1," w="$2" r; r="$(printf '%s' "$3" | sed 's:/*$::')"; [ -n "$r" ] || r=/
  local out=()
  case "$caps" in *,vault.read,*) out+=("$r") ;; esac
  case "$caps" in *,files.read,*)
    case "$w" in finance-bookkeeper|finance-advisor) out+=("$r/Finance") ;; esac
    out+=("$r/Naila/Workspace/$w") ;;
  esac
  (IFS=,; printf '%s' "${out[*]}")
}
run() {  # run CAPS WORKER PATH [hook args…]; CAPS or WORKER "-" leaves the variable unset; HARNESS_ORIGIN is $O (default
  # discord, the channel of the uploads above; "-" leaves it unset); HARNESS_DOCS_ROOTS is $R (default the core's, core_roots
  # for CAPS, WORKER and the --root given; "-" leaves it unset)
  local caps="$1" w="$2" p="$3" o="${O-discord}"; shift 3
  local hroot="" a prev=""
  for a in "$@"; do [ "$prev" = --root ] && hroot="$a"; prev="$a"; done
  local dr="${R-$(core_roots "${caps#-}" "$w" "$hroot")}"
  local e=(env -u HARNESS_CAPS -u HARNESS_WORKER -u HARNESS_ORIGIN -u HARNESS_DOCS_ROOTS)
  [ "$caps" = - ] || e+=("HARNESS_CAPS=$caps")
  [ "$w" = - ] || e+=("HARNESS_WORKER=$w")
  [ "$o" = - ] || e+=("HARNESS_ORIGIN=$o")
  [ "$dr" = - ] || e+=("HARNESS_DOCS_ROOTS=$dr")
  node -e 'console.log(JSON.stringify({ tool_name: "mcp__docs__convert", tool_input: { path: process.argv[1] } }))' "$p" | "${e[@]}" node "$hook" "$@"
}
expect() {  # expect allow|deny CAPS WORKER PATH [hook args; default --by-caps --uploads $up --root $v; "rc" for none]
  local want="$1" caps="$2" w="$3" p="$4"; shift 4
  local args=("$@")
  if [ "${#args[@]}" -eq 0 ]; then args=(--by-caps --uploads "$up" --root "$v"); elif [ "${args[0]}" = rc ]; then args=(); fi
  local out rc=0; out="$(run "$caps" "$w" "$p" ${args[@]+"${args[@]}"})" || rc=$?
  local ctx="$w, caps $caps, origin ${O-discord}, docs roots ${R-by the core}"
  if [ "$rc" != 0 ]; then echo "FAIL: $p ($ctx): exit $rc"; fail=1; return; fi
  if [ "$want" = allow ] && [ -n "$out" ]; then echo "FAIL: $p ($ctx) denied: $out"; fail=1; fi
  if [ "$want" = deny ] && ! grep -q '"permissionDecision":"deny"' <<<"$out"; then echo "FAIL: $p ($ctx) not denied"; fail=1; fi
}
# the switches
expect deny  "$BK" finance-bookkeeper "$v/Daily/x.md"                     # vault.read off: no vault file
expect allow "$BK" finance-bookkeeper "$up/discord/sent.pdf"               # uploads always
expect allow "$NA" naila "$v/Daily/x.md"                                   # vault.read on
expect allow "$NA" naila "$up/discord/sent.pdf"
expect allow "$BK" finance-bookkeeper "$v/Finance/statement.pdf"           # Finance: a finance worker with files.read (the engine gives it)
expect allow "$BK" finance-advisor "$v/Finance/statement.pdf"
expect deny  "docs.convert,messaging.ask,budget.read" finance-bookkeeper "$v/Finance/statement.pdf"   # files.read off
expect deny  "docs.convert,files.read,messaging.ask,cluster.read" ops-oncall "$v/Finance/statement.pdf"   # not a finance worker (the engine gives no Finance)
expect deny  "docs.convert,files.read" naila "$v/Finance/statement.pdf"    # naila, files.read on, vault.read off
expect allow "$BK" finance-bookkeeper "$v/Naila/Workspace/finance-bookkeeper/b.xlsx"   # its own workspace with files.read
expect deny  "$BK" finance-bookkeeper "$v/Naila/Workspace/naila/n.docx"    # another worker's workspace
expect deny  "docs.convert,messaging.ask" finance-bookkeeper "$v/Naila/Workspace/finance-bookkeeper/b.xlsx"   # files.read off
expect allow "docs.convert,files.read" ops-oncall "$v/Naila/Workspace/ops-oncall/o.docx"
expect deny  "docs.convert,files.read" ops-oncall "$v/Daily/x.md"
expect deny  "files.read,vault.read" naila "$up/discord/sent.pdf"          # docs.convert off: nothing
expect deny  "files.read,vault.read" naila "$v/Daily/x.md"
expect allow "docs.convert" ops-oncall "$up/discord/sent.pdf"
expect allow "$BK,vault.read" finance-bookkeeper "$v/Daily/x.md"           # switched on later: the vault opens
# Ruling 16: uploads only under the run's own origin channel
O=test expect deny  "$NA" naila "$up/discord/sent.pdf"                     # a test-origin run: not Discord's upload
O=test expect allow "$NA" naila "$up/test/fixture.pdf"                     # its own
expect allow "$BK" finance-bookkeeper "$up/discord/sent.pdf"               # a discord-origin run: its own
expect deny  "$NA" naila "$up/test/fixture.pdf"                            # a discord-origin run: not the test fixture
O=- expect deny  "$NA" naila "$up/discord/sent.pdf"                        # no origin (the scheduler's runs): no upload
O=- expect deny  "$NA" naila "$up/test/fixture.pdf"
O=- expect allow "$NA" naila "$v/Daily/x.md"                               # ... the rest as the switches say
for o in "" Discord "../discord" "discord/x" "discord,test" " discord" "discord " "1discord" "-discord" "disc_ord" $'discord\n' \
         "a$(printf '%032d' 0)"; do                                        # malformed (the last one 33 characters): no upload
  O="$o" expect deny "$NA" naila "$up/discord/sent.pdf"
done
O="a$(printf '%031d' 0)" expect deny "$NA" naila "$up/discord/sent.pdf"   # well-formed (32), but not Discord
O=test expect deny  "$NA" naila "$up/test/into-discord.pdf"                # a link from its own folder into another channel's
O=evil expect deny  "$NA" naila "$up/evil/sent.pdf"                        # its channel folder is a link to Discord's
O=evil expect deny  "$NA" naila "$up/discord/sent.pdf"
O=test expect deny  "$NA" naila "$v/Daily/into-uploads.pdf"                # a vault link to a Discord upload (vault.read on)
expect allow "$NA" naila "$v/Daily/into-uploads.pdf"                       # ... which a discord-origin run converts
O=test expect deny  "$NA" naila "$up/discord/sent.pdf" --by-caps --uploads "$up" --root "$tmp"   # a deny, not a missing grant:
O=test expect allow "$NA" naila "$tmp/outside/plain.pdf" --by-caps --uploads "$up" --root "$tmp"   # a root holding uploads/ still can't open it
# the deny reason names the folders without a doubled slash when --uploads or --root ends in /
why="$(run "$BK" finance-bookkeeper "$v/Daily/x.md" --by-caps --uploads "$up/" --root "$v/")"
case "$why" in *"$up/discord, $v/Finance, $v/Naila/Workspace/finance-bookkeeper "*) ;; *) echo "FAIL: the deny reason with a trailing / is: $why"; fail=1 ;; esac
case "$why" in *//*) echo "FAIL: the deny reason has a doubled slash: $why"; fail=1 ;; esac
# HARNESS_DOCS_ROOTS (the engine's docs roots): the hook takes its folders from there, and parses it strictly
R=- expect deny  "$NA" naila "$up/discord/sent.pdf"                        # HARNESS_DOCS_ROOTS unset denies everything, uploads included
R=- expect deny  "$NA" naila "$v/Daily/x.md"
R="" expect allow "$NA" naila "$up/discord/sent.pdf"                       # '' is no root: the own uploads still
R="" expect deny  "$NA" naila "$v/Daily/x.md"                              # ... and nothing else, vault.read on or not
R="$tmp/outside" expect deny "$NA" naila "$tmp/outside/plain.pdf"          # a root outside --root denies everything
R="$tmp/outside" expect deny "$NA" naila "$up/discord/sent.pdf"
R="$v,$tmp/outside" expect deny "$NA" naila "$v/Daily/x.md"
R="$v,$tmp/outside" expect deny "$NA" naila "$up/discord/sent.pdf"
R="$tmp" expect deny "$NA" naila "$tmp/outside/plain.pdf"                  # --root's parent is outside it too
for r in "$v," ",$v" "$v,,$v/Finance" "," "vault" "$v/../vault" "$v/./Daily" "$v/Daily\\x" "$(printf '%s/Da\001ily' "$v")" " $v" "$v/Daily
"; do   # an empty, relative or non-plain entry denies everything
  R="$r" expect deny "$NA" naila "$v/Daily/x.md"
  R="$r" expect deny "$NA" naila "$up/discord/sent.pdf"
done
R="$v2/Finance" expect deny  "docs.convert" naila "$v2/Finance/x.md" --by-caps --uploads "$up" --root "$v2"   # a root that is a link opens nothing
R="$v2/Finance" expect allow "docs.convert" naila "$up/discord/sent.pdf" --by-caps --uploads "$up" --root "$v2"   # ... but the value is usable
R="$v2" expect deny "docs.convert" naila "$v2/Naila/Workspace/naila/x.md" --by-caps --uploads "$up" --root "$v2"   # under a root, through a link
R="$v/Finance" expect allow "docs.convert,files.read,messaging.ask,cluster.read" ops-oncall "$v/Finance/statement.pdf"   # a non-finance worker given Finance by the engine converts there
R="$v/Daily" expect allow "docs.convert" researcher "$v/Daily/x.md"        # the engine decides, whatever HARNESS_CAPS says beyond docs.convert
R="$v/Daily" expect deny  "files.read,vault.read" naila "$v/Daily/x.md"    # ... but docs.convert must be on
R="$v/Daily,$v/Finance" expect allow "docs.convert" naila "$v/Finance/statement.pdf"   # every entry counts
why="$(R="$v/Daily,$v/Finance" run "docs.convert" naila "$tmp/outside/plain.pdf" --by-caps --uploads "$up" --root "$v")"   # where: the entries in order
case "$why" in *"in $up/discord, $v/Daily, $v/Finance ("*) ;; *) echo "FAIL: the deny reason does not name the engine's roots in order: $why"; fail=1 ;; esac
why="$(R=- run "$NA" naila "$v/Daily/x.md" --by-caps --uploads "$up" --root "$v")"
case "$why" in *"in nowhere ("*) ;; *) echo "FAIL: the deny reason without HARNESS_DOCS_ROOTS is: $why"; fail=1 ;; esac
n="$(grep -c "finance-bookkeeper\|finance-advisor" "$hook" || true)"   # the hook names no worker
[ "$n" = 0 ] || { echo "FAIL: docs-grant.mjs names a finance worker ($n lines): the engine decides the folders"; fail=1; }
# fails closed
expect deny  - naila "$up/discord/sent.pdf"                                # no HARNESS_CAPS (an image older than the switches)
expect deny  - naila "$v/Daily/x.md"
expect deny  "$NA" - "$up/discord/sent.pdf"                                # no HARNESS_WORKER
expect deny  "$NA" "" "$up/discord/sent.pdf"
expect deny  "$NA" "../naila" "$up/discord/sent.pdf"
expect deny  "$NA" "Naila" "$up/discord/sent.pdf"
expect deny  "docs.convert, vault.read" naila "$v/Daily/x.md"              # unusable HARNESS_CAPS
expect deny  "docs.convert;vault.read" naila "$up/discord/sent.pdf"
expect deny  "docs.convert,,vault.read" naila "$up/discord/sent.pdf"
expect deny  "$NA" naila "$v/Daily/x.md" --by-caps --uploads "$up"        # no --root
expect deny  "$NA" naila "$up/discord/sent.pdf" --by-caps --root "$v"     # no --uploads
expect deny  "$NA" naila "$up/discord/sent.pdf" --by-caps --uploads uploads --root "$v"
expect deny  "$NA" naila "$v/Daily/x.md" --by-caps --uploads "$up" --root vault
expect deny  "$NA" naila "$v/Daily/x.md" --by-caps --uploads "$up" --root
expect deny  "$NA" naila "$v/Daily/x.md" --by-caps --uploads "$up" --root "$v/../vault"
# paths
expect deny  "$NA" naila "$up/discord/linked.pdf"                          # a second hard link
expect deny  "$NA" naila "$up/discord/sym.pdf"                             # a symlink out
expect allow "$BK" finance-bookkeeper "$up/discord/into-finance.pdf"       # a symlink from uploads: judged by its real path (Finance)
expect deny  "docs.convert,files.read" ops-oncall "$up/discord/into-finance.pdf"   # the same link: not a finance worker
expect deny  "$NA" naila "$tmp/outside/secret.pdf"
expect deny  "$NA" naila "$v/Daily"                                        # a directory
expect deny  "$NA" naila "$up/discord/../discord/sent.pdf"                 # ..
expect deny  "$NA" naila "$v/Daily/./x.md"
expect deny  "$NA" naila "$up/discord\\sent.pdf"                           # a backslash
expect deny  "$NA" naila "$(printf '%s/discord/sent\001.pdf' "$up")"      # a control character
expect deny  "$NA" naila "discord/sent.pdf"                                # relative
expect deny  "docs.convert,files.read" naila "$v2/Naila/Workspace/naila/x.md" --by-caps --uploads "$up" --root "$v2"   # workspace is a link
expect deny  "docs.convert,files.read" finance-bookkeeper "$v2/Finance/x.md" --by-caps --uploads "$up" --root "$v2"    # Finance is a link
# --exclude (the real phase)
ex=(--by-caps --uploads "$up" --root "$v" --exclude "$v/Harness-test")
expect allow "$NA" naila "$v/Daily/x.md" "${ex[@]}"
expect deny  "$NA" naila "$v/Harness-test/Naila/test.pdf" "${ex[@]}"
expect deny  "$NA" naila "$v/Daily/into-test.pdf" "${ex[@]}"
expect allow "$NA" naila "$v/Harness-test/Naila/test.pdf"                  # without --exclude (the test phase's root holds it)
expect deny  "$NA" naila "$v/Harness-test/Naila/test.pdf" --by-caps --uploads "$up" --root "$v" --exclude "/nonexistent,$v/Harness-test"
expect deny  "$NA" naila "$v/Daily/x.md" --by-caps --uploads "$up" --root "$v" --exclude "relative/dir"
expect deny  "$NA" naila "$v/Daily/x.md" --by-caps --uploads "$up" --root "$v" --exclude ""
# the RC lines' mode (no flags): nothing denied, whatever the env
for p in "$v/Daily/x.md" "$tmp/outside/secret.pdf" "$up/discord/linked.pdf" "$up/test/fixture.pdf"; do
  O=- expect allow - - "$p" rc
  O=test expect allow "docs.convert" ops-oncall "$p" rc
done
[ "$fail" = 0 ] && echo "OK: docs-grant --by-caps (switches, own origin's uploads only), --exclude, RC mode"
exit "$fail"
