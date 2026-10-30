# Unattended test of Naila's real setup (CLAUDE.md, subagents, MCP servers, deny list) without the phone:
#   kubectl -n assistant exec deploy/assistant-claude -- bash /config/naila-test.sh "<request>"
#   ... naila-test.sh --finance "<request>"   tests the direct finance session instead
# Only the "ask" rules are dropped, in a throwaway CLAUDE_CONFIG_DIR (not HOME: agents copied under a swapped
# HOME count as an untrusted project folder and lose their inline MCP servers). Naila can't run this (Bash is denied).
set -eu
export PATH=$HOME/.npm-global/bin:$PATH
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp -a "$HOME/.claude/agents" "$HOME/.claude/.credentials.json" "$T/"
cp "$HOME/.claude.json" "$T/.claude.json"
node -e 'const s=require(process.argv[1]); delete s.permissions.ask; s.permissions.defaultMode="dontAsk"; s.permissions.allow.push("mcp__finance__add_transaction","mcp__finance__transfer","mcp__finance__update_transaction","mcp__finance__actual_write","mcp__vault__write_inbox","mcp__vault__append_daily","Agent"); process.stdout.write(JSON.stringify(s))' "$HOME/.claude/settings.json" > "$T/settings.json"
D=work; [ "$1" = --finance ] && { D=finance; shift; }
cd "$HOME/$D"
CLAUDE_CONFIG_DIR="$T" claude -p "$1" --output-format text </dev/null
