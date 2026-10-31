# Unattended test of Naila's real setup (CLAUDE.md, subagents, MCP servers, deny list) without the phone:
#   kubectl -n assistant exec deploy/assistant-claude -- bash /config/naila-test.sh "<request>"
#   ... naila-test.sh --line <worker> "<request>"   tests that worker's direct line instead (e.g. --line finance-bookkeeper)
#   NAILA_TEST_TRACE=1 ...   prints a TRACE line after the answer: subagents used and the tools each called
# The finance workers in a test always use assistant-finance-test (the test copy), whatever budget Naila is on, and
# the advisor reads and writes the fixture cabinet /tmp/naila-cabinet instead of the vault's Finance/ folder.
# Only the "ask" rules are dropped, in a throwaway CLAUDE_CONFIG_DIR (not HOME: agents copied under a swapped
# HOME count as an untrusted project folder and lose their inline MCP servers). Naila can't run this (Bash is denied).
set -eu
export PATH=$HOME/.npm-global/bin:$PATH
# The copy holds the login and the finance bearers, so it lives under ~/.claude, which Naila's Read deny covers.
T=$(mktemp -d -p "$HOME/.claude" test.XXXXXX); trap 'rm -rf "$T"' EXIT
cp -a "$HOME/.claude/agents" "$HOME/.claude/.credentials.json" "$T/"
cp "$HOME/.claude.json" "$T/.claude.json"
node -e 'const s=require(process.argv[1]); delete s.permissions.ask; s.permissions.defaultMode="dontAsk"; s.permissions.deny.push("SendMessage","ListAgents"); s.permissions.allow.push("mcp__finance__add_transaction","mcp__finance__transfer","mcp__finance__update_transaction","mcp__finance__actual_write","mcp__vault__write_inbox","mcp__vault__append_daily","mcp__finance-notes__write_note","Agent"); process.stdout.write(JSON.stringify(s))' "$HOME/.claude/settings.json" > "$T/settings.json"
# The finance workers go to the test server (the test copy of the budget, its own bearers), never the real one;
# without a test server there are no finance workers at all.
rm -f "$T/agents/finance-bookkeeper.md" "$T/agents/finance-advisor.md"
A=${NAILA_TEST_AGENTS:-/config}   # tests/live/run.sh PREVIEW=…: agent files rendered from the chart, before they ship
if [ -n "${MCP_FINANCE_TEST_TOKEN:-}" ]; then
  { sed -e "s/__MCP_FINANCE_TOKEN__/$MCP_FINANCE_TEST_TOKEN/" -e 's#//assistant-finance:#//assistant-finance-test:#' $A/agent-finance-bookkeeper.md
    grep -q 'TEST COPY' $A/agent-finance-bookkeeper.md || { echo; cat /config/finance-test-note; }; } > "$T/agents/finance-bookkeeper.md"
fi
if [ -n "${MCP_FINANCE_TEST_READ_TOKEN:-}" ]; then
  sed -e "s/__MCP_FINANCE_READ_TOKEN__/$MCP_FINANCE_TEST_READ_TOKEN/" -e 's#//assistant-finance:#//assistant-finance-test:#' \
    -e 's#/vault/Finance/#/tmp/naila-cabinet/#g' $A/agent-finance-advisor.md > "$T/agents/finance-advisor.md"
  node -e 'const f=process.argv[1], s=JSON.parse(require("fs").readFileSync(f)); s.permissions.allow.push("Read(//tmp/naila-cabinet/**)"); require("fs").writeFileSync(f, JSON.stringify(s))' "$T/settings.json"
fi
D=naila; [ "$1" = --line ] && { D=$2; shift 2; grep -q "^$D " /config/direct-lines || { echo "no direct line: $D"; exit 2; }; }
cd "$HOME/$D"
if [ -n "${NAILA_TEST_TRACE:-}" ]; then
  CLAUDE_CONFIG_DIR="$T" claude -p "$1" --output-format stream-json --verbose </dev/null | node /config/naila-trace.mjs
else
  CLAUDE_CONFIG_DIR="$T" claude -p "$1" --output-format text </dev/null
fi
