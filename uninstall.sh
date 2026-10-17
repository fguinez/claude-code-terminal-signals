#!/usr/bin/env bash
# Uninstaller for claude-code-terminal-signals.
#   ./uninstall.sh            # remove hooks, statusline + color wrapper, keep installed files
#   ./uninstall.sh --purge    # also delete the install dir and color lock dir
set -euo pipefail

INSTALL_DIR="${HOME}/.claude/terminal-signals"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="${CLAUDE_DIR}/settings.json"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
PURGE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) INSTALL_DIR="$2"; shift ;;
    --purge) PURGE=1 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# Remove our hook entries from settings.json (leave the rest intact).
if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  INSTALL_DIR="$INSTALL_DIR" SETTINGS="$SETTINGS" python3 <<'PY'
import json, os, sys
settings = os.environ['SETTINGS']
try:
    with open(settings) as f:
        cfg = json.load(f)
except Exception:
    sys.exit(0)
hooks = cfg.get('hooks', {})
for event, needle in (('PreToolUse', 'term-title.sh'),
                      ('PermissionRequest', 'term-perm.sh'),
                      ('Stop', 'term-busy.sh'),
                      ('SubagentStart', 'term-agents.sh'),
                      ('SubagentStop', 'term-agents.sh')):
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
# unwrap hooks we gated behind term-done.sh, restoring the original command
for event in ('Stop', 'Notification'):
    for g in hooks.get(event, []):
        for h in g.get('hooks', []):
            cmd = h.get('command') or ''
            if cmd.startswith('sh "') and '/term-done.sh" ' in cmd:
                h['command'] = cmd.split('/term-done.sh" ', 1)[1]
# only a statusLine pointing at our own script; someone else's stays
if '%s/statusline.sh' % os.environ['INSTALL_DIR'] in ((cfg.get('statusLine') or {}).get('command') or ''):
    del cfg['statusLine']
with open(settings, 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write('\n')
PY
  echo "✓ Removed hooks and statusline from $SETTINGS"
fi

# Remove the sourced color wrapper from .zshrc.
if [ -f "$ZSHRC" ] && grep -qF "claude-code-terminal-signals (color)" "$ZSHRC"; then
  cp "$ZSHRC" "$ZSHRC.bak.$(date +%Y%m%d%H%M%S)"
  python3 - "$ZSHRC" <<'PY'
import sys
path = sys.argv[1]
lines = open(path).read().splitlines()
out, skip = [], False
for ln in lines:
    if ln.strip() == '# claude-code-terminal-signals (color)':
        skip = True            # drop the marker and the following source line
        continue
    if skip:
        skip = False
        if ln.startswith('source ') and 'claude-session-color.zsh' in ln:
            continue
    out.append(ln)
open(path, 'w').write('\n'.join(out) + '\n')
PY
  echo "✓ Removed color wrapper from $ZSHRC"
fi

if [ "$PURGE" -eq 1 ]; then
  rm -rf "$INSTALL_DIR" "$HOME/.claude/session-colors"
  echo "✓ Purged $INSTALL_DIR and ~/.claude/session-colors"
fi

echo "Done. Restart Claude Code and run 'source ~/.zshrc' (or open a new terminal)."
