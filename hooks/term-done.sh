#!/bin/sh
# Gate for "finished" hooks (peon-ping's done sound) — fires only on a real ✳.
#
# A turn can end while work is still running: a background shell or a background
# subagent. term-busy.sh marks that tab ⧗ instead of ✳, but sound hooks attached
# to Stop don't know about it and play "done" anyway — sometimes several times per
# task, once per turn that ends waiting on background work. This wraps such a hook
# and only runs it when no work is left, using the same two signals:
#
#   - background shells: Claude Code's session state (<config>/sessions/<pid>.json)
#     reads `status` "shell" while one is alive. It flips from "busy" only after
#     the turn is over, i.e. after Stop hooks start, so this waits for it like
#     term-defer.sh does. Run the hook `async` so the wait costs nothing.
#   - background subagents: marker files written by term-agents.sh.
#
# Only Stop and the idle_prompt Notification are gated; any other event is passed
# straight through. When the session state can't be found the hook runs as usual,
# erring toward a sound rather than silence.
#
# Usage: term-done.sh <command> [args...]   (the hook payload is forwarded on stdin)
[ $# -ge 1 ] || exit 0
payload="$(cat 2>/dev/null)"

verdict=$(TERM_SIGNALS_PAYLOAD="$payload" python3 <<'PY' 2>/dev/null
import glob, json, os, time

WAIT = float(os.environ.get('TERM_DEFER_WAIT') or 6.0)
CUSHION = float(os.environ.get('TERM_DEFER_CUSHION') or 0.4)
# Same liveness rules as term-busy.sh: a subagent whose transcript went quiet is
# treated as gone, and a marker with no transcript at all expires after TTL.
LIVENESS = 15 * 60
TTL = 4 * 60 * 60

CONFIG = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.expanduser('~/.claude')

try:
    data = json.loads(os.environ.get('TERM_SIGNALS_PAYLOAD') or '{}')
except Exception:
    data = {}

event = data.get('hook_event_name') or ''
gated = event == 'Stop' or (event == 'Notification'
                            and data.get('notification_type') == 'idle_prompt')
session = data.get('session_id') or ''
if not (gated and session):
    print('run')
    raise SystemExit(0)


def state_file():
    # A crashed `claude` can leave a file with the same sessionId behind, so only
    # trust one whose pid (the file name) is still alive.
    for path in glob.glob(os.path.join(CONFIG, 'sessions', '*.json')):
        try:
            if json.load(open(path)).get('sessionId') != session:
                continue
            os.kill(int(os.path.basename(path)[:-len('.json')]), 0)
            return path
        except Exception:
            continue
    return None


def status(path):
    try:
        return json.load(open(path)).get('status')
    except Exception:
        return None


def live_agents(transcript):
    root = os.path.join(CONFIG, 'terminal-signals', 'agents', session)
    try:
        markers = os.listdir(root)
    except OSError:
        return []
    roots = glob.glob(os.path.join(CONFIG, 'projects', '*', session, 'subagents'))
    if transcript:
        roots.append(os.path.join(os.path.dirname(transcript), session, 'subagents'))
    now, alive = time.time(), []
    for agent in markers:
        hits = []
        for r in roots:
            hits += glob.glob(os.path.join(r, 'agent-%s.jsonl' % agent))
            hits += glob.glob(os.path.join(r, '*', 'agent-%s.jsonl' % agent))
        try:
            age = now - os.path.getmtime(os.path.join(root, agent))
            quiet = now - max(os.path.getmtime(h) for h in hits) if hits else None
        except OSError:
            continue
        if (quiet < LIVENESS) if quiet is not None else (age < TTL):
            alive.append(agent)
    return alive


path = state_file()
st = None
if path:
    deadline = time.time() + WAIT
    while time.time() < deadline:
        st = status(path)
        if st != 'busy':
            break
        time.sleep(0.1)
    else:
        # Still busy: the session is working again, so this was not the end.
        print('skip busy')
        raise SystemExit(0)
    time.sleep(CUSHION)
    st = status(path)

agents = live_agents(data.get('transcript_path') or '')
owner = os.path.basename(path or '')[:-len('.json')] or '?'
if st in ('busy', 'shell') or agents:
    print('skip owner=%s status=%s agents=%d' % (owner, st, len(agents)))
else:
    print('run owner=%s status=%s' % (owner, st))
PY
)

# Mirrors term-busy.sh's trace: `touch ~/.claude/terminal-signals.debug`.
CONFIG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[ -e "$CONFIG/terminal-signals.debug" ] && \
  echo "done ${verdict:-run (no verdict)}" >> "$CONFIG/terminal-signals.log"

case "$verdict" in skip*) exit 0 ;; esac
printf '%s' "$payload" | exec "$@"
