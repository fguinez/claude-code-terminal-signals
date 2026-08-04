#!/usr/bin/env bash
# Installer for claude-code-terminal-signals.
#
#   ./install.sh                # install both features
#   ./install.sh --no-color     # only the tab attention glyphs (hooks)
#   ./install.sh --no-hooks     # only the per-session color wrapper (zsh)
#   ./install.sh --dir PATH     # custom install dir (default: ~/.claude/terminal-signals)
#
# Idempotent: safe to re-run. It backs up settings.json before editing and only
# touches the hook entries it owns (those referencing term-title.sh/term-perm.sh).
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.claude/terminal-signals"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="${CLAUDE_DIR}/settings.json"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
DO_HOOKS=1
DO_COLOR=1

while [ $# -gt 0 ]; do
  case "$1" in
    --no-hooks) DO_HOOKS=0 ;;
    --no-color) DO_COLOR=0 ;;
    --dir) INSTALL_DIR="$2"; shift ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

command -v python3 >/dev/null 2>&1 || { echo "✗ python3 is required (used to set the tab title and merge settings.json)." >&2; exit 1; }

echo "→ Installing to: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp "$REPO_DIR/hooks/term-title.sh" "$REPO_DIR/hooks/term-perm.sh" \
   "$REPO_DIR/hooks/term-busy.sh" "$REPO_DIR/hooks/term-agents.sh" "$INSTALL_DIR/"
cp "$REPO_DIR/shell/claude-session-color.zsh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/term-title.sh" "$INSTALL_DIR/term-perm.sh" \
         "$INSTALL_DIR/term-busy.sh" "$INSTALL_DIR/term-agents.sh"

# ---------------------------------------------------------------------------
# Feature 1 — tab attention glyphs (Claude Code hooks)
# ---------------------------------------------------------------------------
if [ "$DO_HOOKS" -eq 1 ]; then
  mkdir -p "$CLAUDE_DIR"
  [ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  INSTALL_DIR="$INSTALL_DIR" SETTINGS="$SETTINGS" python3 <<'PY'
import json, os, sys

d = os.environ['INSTALL_DIR']
settings = os.environ['SETTINGS']
title_cmd = 'sh "%s/term-title.sh" "✦"' % d   # ✦ for clarifying questions
perm_cmd  = 'sh "%s/term-perm.sh"' % d             # ✦ question / ✿ permission
busy_cmd  = 'sh "%s/term-busy.sh"' % d             # ⧗ turn ended, background work still running
agent_cmd = 'sh "%s/term-agents.sh"' % d           # tracks background subagents for term-busy.sh

try:
    with open(settings) as f:
        cfg = json.load(f)
except FileNotFoundError:
    cfg = {}
except Exception:
    sys.exit("✗ %s is not valid JSON — aborting so it isn't clobbered. Fix it and re-run." % settings)

hooks = cfg.setdefault('hooks', {})

def strip(event, needle):
    """Drop hook entries we own (by command substring); keep everyone else's."""
    kept = []
    for g in hooks.get(event, []):
        g = dict(g)
        g['hooks'] = [h for h in g.get('hooks', []) if needle not in (h.get('command') or '')]
        if g['hooks']:
            kept.append(g)
    if kept:
        hooks[event] = kept
    elif event in hooks:
        del hooks[event]

# Insert at the front so our glyph wins over other title-writing hooks (e.g. peon-ping).
strip('PreToolUse', 'term-title.sh')
hooks.setdefault('PreToolUse', []).insert(0, {
    'matcher': 'AskUserQuestion',
    'hooks': [{'type': 'command', 'command': title_cmd}],
})

strip('PermissionRequest', 'term-perm.sh')
hooks.setdefault('PermissionRequest', []).insert(0, {
    'hooks': [{'type': 'command', 'command': perm_cmd}],
})

strip('Stop', 'term-busy.sh')
hooks.setdefault('Stop', []).insert(0, {
    'hooks': [{'type': 'command', 'command': busy_cmd}],
})

# A subagent leaves no process behind, so its start/stop are recorded as markers.
for event in ('SubagentStart', 'SubagentStop'):
    strip(event, 'term-agents.sh')
    hooks.setdefault(event, []).insert(0, {
        'hooks': [{'type': 'command', 'command': agent_cmd}],
    })

with open(settings, 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write('\n')
print("✓ Registered hooks in %s" % settings)
PY
fi

# ---------------------------------------------------------------------------
# Feature 2 — unique bar color per session (zsh wrapper)
# ---------------------------------------------------------------------------
if [ "$DO_COLOR" -eq 1 ]; then
  SRC_LINE="source \"$INSTALL_DIR/claude-session-color.zsh\""
  MARKER="# claude-code-terminal-signals (color)"
  if [ -f "$ZSHRC" ] && grep -qF "$MARKER" "$ZSHRC"; then
    echo "✓ Color wrapper already sourced in $ZSHRC"
  else
    {
      printf '\n%s\n' "$MARKER"
      printf '%s\n' "$SRC_LINE"
    } >> "$ZSHRC"
    echo "✓ Added color wrapper to $ZSHRC"
  fi
fi

echo
echo "Done. Next steps:"
[ "$DO_HOOKS" -eq 1 ] && echo "  • Restart Claude Code (or start a new session) so the new hooks load."
[ "$DO_COLOR" -eq 1 ] && echo "  • Run 'source ~/.zshrc' (or open a new terminal) to enable per-session colors."
