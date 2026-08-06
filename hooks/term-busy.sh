#!/bin/sh
# Stop hook — keeps the "your turn" glyph honest.
#
# When a turn ends, Claude Code marks the tab ✳ ("finished — waiting for your
# next message"). That's misleading when the turn ended with work still running:
# a background shell (a `gh run watch`, a test suite, a deploy tail) or a
# background subagent. The session wakes itself up when that work finishes and
# keeps going, so switching to the tab right now gains you nothing. This hook
# detects both cases and marks the tab ⧗ ("still working") instead.
#
# Background shells are reported by Claude Code itself: the session state file
# (<config>/sessions/<pid>.json) carries `status` "shell" while a background bash
# task is alive — "busy" during the turn, "idle"/"waiting" otherwise. It only
# flips once the turn is over, i.e. after this hook has run, so that call is made
# by the deferred writer, which waits for exactly that. See term-defer.sh.
#
# The process table is scanned as well, as a fallback for when the state file
# can't be read: Claude Code runs every Bash tool call as a direct child of the
# `claude` process, wrapped in a recognizable shell-snapshot preamble, and a
# background call is simply one still alive when the turn ends. `claude` has
# other children (MCP servers, `caffeinate`, git helpers, and the shells running
# these very hooks), so candidates are filtered by that preamble and by ancestry.
#
# Subagents leave no child process, and don't flip `status` either (they run
# inside `claude`), so `term-agents.sh` tracks them as marker files instead; this
# hook counts the ones that are still alive.
#
# Emits nothing when no work is left, leaving Claude Code's native ✳ untouched —
# so the tab still reads as "your turn" in the normal case.
glyph="${TERM_BUSY_GLYPH:-⧗}"
payload="$(cat 2>/dev/null)"

running=$(TERM_SIGNALS_PAYLOAD="$payload" python3 <<'PY'
import glob, json, os, subprocess, time

MAX_HOPS = 16
# Every Bash tool call, foreground or background, looks like:
#   /bin/zsh -c source ~/.claude/shell-snapshots/snapshot-… && … &&
#     eval '<command>' < /dev/null && pwd -P >| /tmp/claude-<hash>-cwd
SIGNATURE = ('shell-snapshots/snapshot-', '< /dev/null', 'pwd -P >|')
# These hooks reach the same shell; never count them as work still running.
OURS = ('term-title.sh', 'term-perm.sh', 'term-busy.sh', 'term-agents.sh')
# A live subagent appends to its own transcript constantly. If that file has gone
# quiet, treat the agent as gone even if its marker survived (a missed
# SubagentStop, an interrupt) — erring toward the native ✳ rather than a ⧗ that
# never clears. LIVENESS is the quiet period tolerated; TTL bounds a marker whose
# transcript can't be found at all, and prunes it for good.
LIVENESS = 15 * 60
TTL = 4 * 60 * 60

CONFIG = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.expanduser('~/.claude')

try:
    data = json.loads(os.environ.get('TERM_SIGNALS_PAYLOAD') or '{}')
except Exception:
    data = {}


def process_table():
    out = subprocess.run(['ps', '-eww', '-o', 'pid=,ppid=,command='],
                         capture_output=True, text=True).stdout
    table = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            table[int(parts[0])] = (int(parts[1]), parts[2])
    return table


def session_state(pid):
    """Contents of the state file `claude` keeps for itself, if any."""
    try:
        with open(os.path.join(CONFIG, 'sessions', '%d.json' % pid)) as fh:
            return json.load(fh)
    except Exception:
        return None


def is_owner(pid, cmd, session):
    """Is this ancestor the `claude` process the tab belongs to?

    The state file is the reliable test — it names the session outright. argv is
    only the fallback, and is matched case-insensitively: on a case-insensitive
    filesystem `CLAUDE` also starts Claude Code (bypassing any `claude` shell
    wrapper), and such a session used to go unrecognised and stay stuck on ✳.
    """
    state = session_state(pid)
    if state is not None and (state.get('sessionId') == session or not session):
        return True
    head = cmd.split(None, 1)[0] if cmd else ''
    return os.path.basename(head).lower() == 'claude'


def is_tool_shell(cmd):
    return all(s in cmd for s in SIGNATURE) and not any(o in cmd for o in OURS)


def background_shells(session):
    """Tool shells of the owning `claude` that outlived the turn."""
    table = process_table()
    # Walk up to the owning `claude`, remembering the chain — the hook itself
    # runs inside one of its child shells and must not count as leftover work.
    chain, pid, owner = set(), os.getpid(), None
    for _ in range(MAX_HOPS):
        chain.add(pid)
        parent = table.get(pid, (0, ''))[0]
        if parent <= 1:
            break
        if is_owner(parent, table.get(parent, (0, ''))[1], session):
            owner = parent
            break
        pid = parent
    if owner is None:
        return None, []
    return owner, sorted(p for p, (ppid, cmd) in table.items()
                         if ppid == owner and p not in chain and is_tool_shell(cmd))


def agent_transcripts(session, transcript, agent):
    """Locate agent-<id>.jsonl under <projects>/<session>/subagents[/<sub>]."""
    roots = []
    if transcript:
        roots.append(os.path.join(os.path.dirname(transcript), session, 'subagents'))
    roots += glob.glob(os.path.join(CONFIG, 'projects', '*', session, 'subagents'))
    hits = []
    for root in roots:
        hits += glob.glob(os.path.join(root, 'agent-%s.jsonl' % agent))
        hits += glob.glob(os.path.join(root, '*', 'agent-%s.jsonl' % agent))
    return hits


def live_agents(session, transcript):
    """Markers left by term-agents.sh whose subagent still looks alive."""
    root = os.path.join(CONFIG, 'terminal-signals', 'agents', session)
    try:
        markers = os.listdir(root)
    except OSError:
        return []
    now, alive = time.time(), []
    for agent in markers:
        marker = os.path.join(root, agent)
        try:
            age = now - os.path.getmtime(marker)
            hits = agent_transcripts(session, transcript, agent)
            quiet = now - max(os.path.getmtime(h) for h in hits) if hits else None
        except OSError:
            continue
        if (quiet < LIVENESS) if quiet is not None else (age < TTL):
            alive.append(agent)
        elif age > TTL:
            try:
                os.unlink(marker)
            except OSError:
                pass
    return sorted(alive)


session = data.get('session_id') or ''
owner, shells = background_shells(session)
agents = live_agents(session, data.get('transcript_path') or '') if session else []
print('%d %d %s' % (len(agents), len(shells), owner or 0))

# `touch ~/.claude/terminal-signals.debug` to trace what the hook saw — a Stop
# hook is otherwise invisible, and hooks only reload on a fresh session.
if os.path.exists(os.path.join(CONFIG, 'terminal-signals.debug')):
    with open(os.path.join(CONFIG, 'terminal-signals.log'), 'a') as fh:
        fh.write('owner=%s shells=%s agents=%s\n' % (owner, shells, agents))
PY
)

# The python above prints "<live subagents> <background shells> <owning claude pid>".
set -- ${running:-0 0 0}
agents=$1
shells=$2
owner=$3
[ "$owner" != "0" ] || exit 0

# Resolve the sibling scripts next to this one so the set stays install-location
# independent, and forward the payload — stdin is already consumed here.
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONFIG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Build the raw escape sequence rather than the hook-protocol JSON: it is written
# to the tty later, by term-defer.sh, not returned to Claude Code.
seq=$(TERM_TITLE_RAW=1 TERM_TITLE_PAYLOAD="$payload" sh "$DIR/term-title.sh" "$glyph")
[ -n "$seq" ] || exit 0

# The owning `claude` holds the tty the tab belongs to; hooks get no tty of their own.
tty=$(ps -o tty= -p "$owner" 2>/dev/null | tr -d ' ')
case "$tty" in ''|'??'|'?') exit 0 ;; esac
[ -w "/dev/$tty" ] || exit 0

# Handed over even when nothing was found: `status` in the state file only turns
# "shell" after this hook returns, so the deferred writer gets the last word.
# Subagents are invisible to that field and decide on their own; the shell count
# is only a fallback for when the state file can't be read.
TERM_DEFER_AGENTS=$([ "$agents" -gt 0 ] && echo 1 || echo 0) \
TERM_DEFER_SHELLS=$([ "$shells" -gt 0 ] && echo 1 || echo 0) \
  nohup sh "$DIR/term-defer.sh" "/dev/$tty" "$CONFIG/sessions/$owner.json" "$seq" \
  >/dev/null 2>&1 &
exit 0
