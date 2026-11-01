#!/usr/bin/env bash
# Usage: tests/docs-grant.sh
# Runs helm/assistant/files/docs-grant.mjs --only ROOT (the test runs' mode) against files under a temp root:
#  - a plain file under the root is allowed (no output);
#  - a file with a second hard link (one name inside the root, one outside) is denied;
#  - a path outside the root, a directory and a symlink out of the root are denied.
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

fail=0
run() { printf '{"tool_input":{"path":"%s"}}' "$1" | node "$hook" --only "$tmp/root"; }
expect() {  # expect allow|deny PATH
  local out; out="$(run "$2")"
  if [ "$1" = allow ] && [ -n "$out" ]; then echo "FAIL: $2 denied: $out"; fail=1; fi
  if [ "$1" = deny ] && ! grep -q '"permissionDecision":"deny"' <<<"$out"; then echo "FAIL: $2 not denied"; fail=1; fi
}
expect allow "$tmp/root/sub/plain.pdf"
expect deny "$tmp/root/sub/linked.pdf"
expect deny "$tmp/outside/secret.pdf"
expect deny "$tmp/root/sub"
expect deny "$tmp/root/sub/sym.pdf"
[ "$fail" = 0 ] && echo "OK: docs-grant --only"
exit "$fail"
