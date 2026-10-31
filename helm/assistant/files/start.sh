set -eu
export NPM_CONFIG_PREFIX=$HOME/.npm-global PATH=$HOME/.npm-global/bin:$PATH
[ "$(claude --version 2>/dev/null | cut -d' ' -f1)" = "$CLAUDE_VERSION" ] || npm i -g @anthropic-ai/claude-code@$CLAUDE_VERSION
mkdir -p $HOME/.claude $HOME/work
cp /config/settings.json $HOME/.claude/settings.json
cp /config/CLAUDE.md $HOME/work/CLAUDE.md
# Workers are subagents (the chart's `workers` list, one /config/agent-<name>.md each, named <division>-<job>); their
# MCP servers are defined inline in their files so the main session never has their tools (the advisor's bearer only
# sees read tools). The files live under ~/.claude, which the session's Read deny covers (they hold the bearers). The
# folder is rebuilt from /config on every start, so a renamed worker leaves nothing behind.
rm -rf $HOME/.claude/agents && mkdir -p $HOME/.claude/agents
for f in /config/agent-*.md; do
  n=${f#/config/agent-}
  sed -e "s/__MCP_FINANCE_TOKEN__/$MCP_FINANCE_TOKEN/" -e "s/__MCP_FINANCE_READ_TOKEN__/$MCP_FINANCE_READ_TOKEN/" -e "s/__MCP_OPS_TOKEN__/$MCP_OPS_TOKEN/" "$f" > $HOME/.claude/agents/$n
done
unset MCP_FINANCE_TOKEN MCP_FINANCE_READ_TOKEN MCP_OPS_TOKEN   # only the agent files (under the Read-denied ~/.claude) keep them
claude mcp remove vault --scope user >/dev/null 2>&1 || true
claude mcp add vault --scope user -e VAULT_ROOT=/vault -e TZ="$TZ" -- node /naila/packages/vault-mcp/dist/server.js
# Documents to Markdown (MarkItDown), served by the `docs` sidecar on 127.0.0.1.
claude mcp remove docs --scope user >/dev/null 2>&1 || true
claude mcp add --transport http docs --scope user http://127.0.0.1:3002/mcp
# Direct lines (/config/direct-lines, "<name> <model>" per worker): each folder runs that worker as the main session,
# with only the worker's own tools (so a read-only worker stays read-only and can't call another worker). The model
# is pinned here (Remote Control ignores the agent's own `model:`); the folders are pre-trusted, their only content
# is this settings file.
while read -r n m; do
  [ -n "$n" ] || continue
  mkdir -p $HOME/$n/.claude
  echo "{\"agent\": \"$n\", \"model\": \"$m\"}" > $HOME/$n/.claude/settings.json
  [ -f $HOME/.claude.json ] && node -e 'const f=process.argv[1], p=process.argv[2], c=require(f); c.projects ??= {}; c.projects[p] = { ...c.projects[p], hasTrustDialogAccepted: true }; require("fs").writeFileSync(f, JSON.stringify(c, null, 2))' $HOME/.claude.json "/home/claude/$n"
done < /config/direct-lines
cd $HOME/work
# No login yet: start interactive Claude Code so you can `kubectl -n assistant attach -it deploy/assistant-claude`,
# /login, then /exit; the pod restarts into Remote Control (attach once more to accept its trust/enable prompts).
[ -f $HOME/.claude/.credentials.json ] || exec claude
# Each direct line's server runs in the background (restarted if it exits), under a pty because Remote Control draws a
# screen; Naila's server stays the container's main process, so `kubectl attach` still reaches her.
# stdin is /dev/null, not a pipe: bash waits for every command of a pipeline, so `sleep infinity | script` never looped.
while read -r d _; do
  [ -n "$d" ] || continue
  (cd $HOME/$d; while :; do script -qfc "claude remote-control --name $d --spawn same-dir" /dev/null </dev/null >/dev/null 2>&1; sleep 10; done) &
done < /config/direct-lines
exec claude remote-control --name naila --spawn same-dir
