#!/bin/sh
# SubagentStart / SubagentStop hook — track background subagents for term-busy.sh.
#
# A subagent runs *inside* the `claude` process and spawns no child of its own, so
# the process scan in term-busy.sh cannot see it. These two events can: Claude
# builds both payloads with the **main** session's id (`session_id`) plus a stable
# `agent_id`, so one marker file per agent pairs Start↔Stop exactly, and the Stop
# hook of the same session finds them.
#
# Marker: <claude config dir>/terminal-signals/agents/<session_id>/<agent_id>
#
# Foreground subagents get a marker too, and remove it before the turn ends — by
# the time the main `Stop` fires, only background ones are left.
#
# Writes nothing to stdout and never fails: worst case a marker is missed and you
# get Claude's native ✳, which is today's behaviour.
payload="$(cat 2>/dev/null)"

TERM_SIGNALS_PAYLOAD="$payload" python3 <<'PY' 2>/dev/null
import json, os, re

raw = os.environ.get('TERM_SIGNALS_PAYLOAD') or ''
try:
    data = json.loads(raw) if raw.strip() else {}
except Exception:
    data = {}

event = data.get('hook_event_name') or ''
session = data.get('session_id') or ''
agent = data.get('agent_id') or ''
if not (session and agent):
    raise SystemExit(0)


def safe(value):
    return re.sub(r'[^A-Za-z0-9._-]', '', str(value))[:80]


config = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.expanduser('~/.claude')
session_dir = os.path.join(config, 'terminal-signals', 'agents', safe(session))
marker = os.path.join(session_dir, safe(agent))

if event == 'SubagentStart':
    os.makedirs(session_dir, exist_ok=True)
    open(marker, 'w').close()
else:
    try:
        os.unlink(marker)
    except OSError:
        pass
    try:
        os.rmdir(session_dir)   # tidy up after the session's last agent
    except OSError:
        pass
PY

exit 0
