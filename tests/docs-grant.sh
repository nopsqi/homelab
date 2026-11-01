#!/usr/bin/env bash
# Usage: tests/docs-grant.sh
# Runs helm/assistant/files/docs-grant.mjs --only ROOT (the test runs' mode) against files under a temp root:
#  - a plain file under the root is allowed (no output);
#  - a file with a second hard link (one name inside the root, one outside) is denied;
#  - a path outside the root, a directory and a symlink out of the root are denied;
#  - with --exclude DIR[,DIR…] (the real phase: the test folder), a file under an excluded dir, or a symlink into one, is
#    denied, a file beside it is not, and a malformed --exclude denies everything.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
hook="$root/helm/assistant/files/docs-grant.mjs"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/root/sub" "$tmp/outside"
echo a > "$tmp/root/sub/plain.pdf"
echo b > "$tmp/outside/secret.pdf"
ln "$tmp/outside/secret.pdf" "$tmp/root/sub/linked.pdf"
ln -s "$tmp/outside/secret.pdf" "$tmp/root/sub/sym.pdf"
mkdir -p "$tmp/root/Harness-test/Naila"
echo c > "$tmp/root/Harness-test/Naila/test.pdf"
ln -s "$tmp/root/Harness-test/Naila/test.pdf" "$tmp/root/sub/into-test.pdf"

fail=0
run() { printf '{"tool_input":{"path":"%s"}}' "$1" | node "$hook" --only "$tmp/root" "${@:2}"; }
expect() {  # expect allow|deny PATH [extra hook args]
  local out; out="$(run "$2" "${@:3}")"
  if [ "$1" = allow ] && [ -n "$out" ]; then echo "FAIL: $2 denied: $out"; fail=1; fi
  if [ "$1" = deny ] && ! grep -q '"permissionDecision":"deny"' <<<"$out"; then echo "FAIL: $2 not denied"; fail=1; fi
}
expect allow "$tmp/root/sub/plain.pdf"
expect deny "$tmp/root/sub/linked.pdf"
expect deny "$tmp/outside/secret.pdf"
expect deny "$tmp/root/sub"
expect deny "$tmp/root/sub/sym.pdf"
expect allow "$tmp/root/Harness-test/Naila/test.pdf"
ex=(--exclude "$tmp/root/Harness-test")
expect allow "$tmp/root/sub/plain.pdf" "${ex[@]}"
expect deny "$tmp/root/Harness-test/Naila/test.pdf" "${ex[@]}"
expect deny "$tmp/root/sub/into-test.pdf" "${ex[@]}"
expect deny "$tmp/root/Harness-test/Naila/test.pdf" --exclude "/nonexistent,$tmp/root/Harness-test"
expect deny "$tmp/root/sub/plain.pdf" --exclude "relative/dir"
expect deny "$tmp/root/sub/plain.pdf" --exclude ""
[ "$fail" = 0 ] && echo "OK: docs-grant --only, --exclude"
exit "$fail"
