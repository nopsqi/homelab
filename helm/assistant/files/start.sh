set -eu
export NPM_CONFIG_PREFIX=$HOME/.npm-global PATH=$HOME/.npm-global/bin:$PATH
[ "$(claude --version 2>/dev/null | cut -d' ' -f1)" = "$CLAUDE_VERSION" ] || npm i -g @anthropic-ai/claude-code@$CLAUDE_VERSION
mkdir -p $HOME/.claude $HOME/work
cp /config/settings.json $HOME/.claude/settings.json
cp /config/CLAUDE.md $HOME/work/CLAUDE.md
# Workers are subagents, named by division (finance-bookkeeper); the bookkeeper's MCP server is defined inline in its
# file so the main session never has money tools. The files live under ~/.claude, which the session's Read deny
# covers (they hold the bearers). The folder is rebuilt from /config on every start, so a renamed worker leaves nothing behind.
rm -rf $HOME/.claude/agents && mkdir -p $HOME/.claude/agents
sed "s/__MCP_FINANCE_TOKEN__/$MCP_FINANCE_TOKEN/" /config/finance-bookkeeper.md > $HOME/.claude/agents/finance-bookkeeper.md
sed "s/__MCP_OPS_TOKEN__/$MCP_OPS_TOKEN/" /config/ops-agent.md > $HOME/.claude/agents/ops.md
unset MCP_FINANCE_TOKEN MCP_OPS_TOKEN   # only the agent files (under the Read-denied ~/.claude) keep them
claude mcp remove vault --scope user >/dev/null 2>&1 || true
claude mcp add vault --scope user -e VAULT_ROOT=/vault -e TZ="$TZ" -- node /naila/packages/vault-mcp/dist/server.js
# Direct line to the bookkeeper: its own folder runs the finance-bookkeeper agent as the main session. The model is
# pinned here too (Remote Control ignores the agent's own `model:`); the folder is pre-trusted, since its only
# content is this settings file.
mkdir -p $HOME/bookkeeper/.claude
echo '{"agent": "finance-bookkeeper", "model": "haiku"}' > $HOME/bookkeeper/.claude/settings.json
[ -f $HOME/.claude.json ] && node -e 'const f=process.argv[1], c=require(f); c.projects ??= {}; c.projects["/home/claude/bookkeeper"] = { ...c.projects["/home/claude/bookkeeper"], hasTrustDialogAccepted: true }; require("fs").writeFileSync(f, JSON.stringify(c, null, 2))' $HOME/.claude.json
cd $HOME/work
# No login yet: start interactive Claude Code so you can `kubectl -n assistant attach -it deploy/assistant-claude`,
# /login, then /exit; the pod restarts into Remote Control (attach once more to accept its trust/enable prompts).
[ -f $HOME/.claude/.credentials.json ] || exec claude
# The bookkeeper's server runs in the background (restarted if it exits), under a pty because Remote Control draws a
# screen; Naila's server stays the container's main process, so `kubectl attach` still reaches her.
# stdin is /dev/null, not a pipe: bash waits for every command of a pipeline, so `sleep infinity | script` never looped.
(cd $HOME/bookkeeper; while :; do script -qfc "claude remote-control --name bookkeeper --spawn same-dir" /dev/null </dev/null >/dev/null 2>&1; sleep 10; done) &
exec claude remote-control --name naila --spawn same-dir
