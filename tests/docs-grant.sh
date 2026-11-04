#!/usr/bin/env bash
# Usage: tests/docs-grant.sh
# Runs helm/assistant/files/docs-grant.mjs --by-caps --uploads U --root R (the harness runs' mode) against files under a
# temp vault and uploads folder, with HARNESS_CAPS and HARNESS_WORKER in the env as the core sets them per run:
#  - docs.convert must be on, and uploads are always convertible;
#  - the vault root only with vault.read; <root>/Finance/ only for a finance worker with files.read (P28); the worker's own
#    <root>/Naila/Workspace/<worker>/ with files.read, never another worker's;
#  - it fails closed: no HARNESS_CAPS, an unusable HARNESS_CAPS or HARNESS_WORKER, no --uploads or --root, or a relative one
#    deny everything, uploads included;
#  - a file with a second hard link, a directory, a symlink out of an allowed root, a path with `..`, a backslash or a control
#    character, and a workspace or Finance folder that is itself a link are denied;
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
  "$v/Harness-test/Naila" "$up/discord" "$tmp/outside"
echo a > "$v/Daily/x.md"
echo a > "$v/Finance/statement.pdf"
echo a > "$v/Naila/Workspace/naila/n.docx"
echo a > "$v/Naila/Workspace/finance-bookkeeper/b.xlsx"
echo a > "$v/Naila/Workspace/ops-oncall/o.docx"
echo a > "$up/discord/sent.pdf"
echo b > "$tmp/outside/secret.pdf"
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
run() {  # run CAPS WORKER PATH [hook args…]; CAPS or WORKER "-" leaves the variable unset
  local caps="$1" w="$2" p="$3"; shift 3
  local e=(env -u HARNESS_CAPS -u HARNESS_WORKER)
  [ "$caps" = - ] || e+=("HARNESS_CAPS=$caps")
  [ "$w" = - ] || e+=("HARNESS_WORKER=$w")
  node -e 'console.log(JSON.stringify({ tool_name: "mcp__docs__convert", tool_input: { path: process.argv[1] } }))' "$p" | "${e[@]}" node "$hook" "$@"
}
expect() {  # expect allow|deny CAPS WORKER PATH [hook args; default --by-caps --uploads $up --root $v; "rc" for none]
  local want="$1" caps="$2" w="$3" p="$4"; shift 4
  local args=("$@")
  if [ "${#args[@]}" -eq 0 ]; then args=(--by-caps --uploads "$up" --root "$v"); elif [ "${args[0]}" = rc ]; then args=(); fi
  local out rc=0; out="$(run "$caps" "$w" "$p" ${args[@]+"${args[@]}"})" || rc=$?
  if [ "$rc" != 0 ]; then echo "FAIL: $p ($w, caps $caps): exit $rc"; fail=1; return; fi
  if [ "$want" = allow ] && [ -n "$out" ]; then echo "FAIL: $p ($w, caps $caps) denied: $out"; fail=1; fi
  if [ "$want" = deny ] && ! grep -q '"permissionDecision":"deny"' <<<"$out"; then echo "FAIL: $p ($w, caps $caps) not denied"; fail=1; fi
}
# the switches
expect deny  "$BK" finance-bookkeeper "$v/Daily/x.md"                     # vault.read off: no vault file
expect allow "$BK" finance-bookkeeper "$up/discord/sent.pdf"               # uploads always
expect allow "$NA" naila "$v/Daily/x.md"                                   # vault.read on
expect allow "$NA" naila "$up/discord/sent.pdf"
expect allow "$BK" finance-bookkeeper "$v/Finance/statement.pdf"           # Finance: a finance worker with files.read
expect allow "$BK" finance-advisor "$v/Finance/statement.pdf"
expect deny  "docs.convert,messaging.ask,budget.read" finance-bookkeeper "$v/Finance/statement.pdf"   # files.read off
expect deny  "docs.convert,files.read,messaging.ask,cluster.read" ops-oncall "$v/Finance/statement.pdf"   # not a finance worker
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
for p in "$v/Daily/x.md" "$tmp/outside/secret.pdf" "$up/discord/linked.pdf"; do
  expect allow - - "$p" rc
  expect allow "docs.convert" ops-oncall "$p" rc
done
[ "$fail" = 0 ] && echo "OK: docs-grant --by-caps (switches), --exclude, RC mode"
exit "$fail"
