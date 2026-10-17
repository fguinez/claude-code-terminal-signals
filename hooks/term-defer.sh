#!/bin/sh
# Detached title writer for term-busy.sh.
#
# Why this exists: a Stop hook cannot win the tab title. Claude Code writes its
# own ✳ ("finished — waiting for you") title when the turn ends, *after* it has
# processed the hook's output, so a `terminalSequence` returned from the Stop
# hook is emitted and then immediately overwritten. The ✦/✿ hooks don't hit this
# because they fire mid-turn, while Claude is blocked and not retitling.
#
# So the glyph is written after the native title lands, straight to the tty that
# owns the tab. `terminalSequence` is the documented mechanism and hooks have no
# tty of their own, hence the detour: term-busy.sh passes the tty it resolved
# from the owning `claude` process.
#
# Ordering is taken from Claude Code's own session state
# (<config>/sessions/<pid>.json), whose `status` reads "busy" while a turn is
# running: once it stops being busy the native title has been written and the
# glyph can go on top. If the turn has already resumed by then, nothing is
# written — a stale ⧗ over a working session would be worse than no glyph.
#
# That settled status is also the answer to "is there work left": Claude Code
# reports "shell" (rather than "idle"/"waiting") for as long as a background bash
# task is alive. Subagents don't show up there — they run inside `claude` — so
# TERM_DEFER_AGENTS=1 writes the glyph whatever the status says, while
# TERM_DEFER_SHELLS=1 (term-busy.sh's process scan) only decides when the state
# file can't be read at all.
#
# Shells left behind by subagents that have already finished, or started by Claude
# in an earlier turn, also keep the status at "shell", often for good (a dev
# server). When those are the only work left the tab gets TERM_DEFER_ORPHAN_GLYPH
# (◎) instead of ⧗; term-done.sh stays silent.
#
# Usage: term-defer.sh <tty path> <session json> <escape sequence>
[ $# -eq 3 ] || exit 0

TERM_DEFER_TTY="$1" TERM_DEFER_SESSION="$2" TERM_DEFER_SEQ="$3" python3 <<'PY' 2>/dev/null
import glob, json, os, re, shlex, subprocess, time

tty = os.environ['TERM_DEFER_TTY']
session = os.environ['TERM_DEFER_SESSION']
seq = os.environ['TERM_DEFER_SEQ']
agents = os.environ.get('TERM_DEFER_AGENTS', '1') == '1'
shells = os.environ.get('TERM_DEFER_SHELLS', '0') == '1'

# Time to wait for the turn to be reported finished, and the pause afterwards
# that lets Claude's native title land before ours goes over it.
WAIT = float(os.environ.get('TERM_DEFER_WAIT') or 6.0)
CUSHION = float(os.environ.get('TERM_DEFER_CUSHION') or 0.4)


def status():
    """'busy' while the turn runs; None when the field can't be read."""
    try:
        return json.load(open(session)).get('status')
    except Exception:
        return None


seen_status, settled = False, None
deadline = time.time() + WAIT
while time.time() < deadline:
    st = status()
    if st is not None:
        seen_status = True
        if st != 'busy':
            settled = st
            break
    time.sleep(0.1)
else:
    # Never stopped being busy. If the field is readable that means the session
    # is genuinely working again, so leave its title alone.
    if seen_status:
        raise SystemExit(0)

time.sleep(CUSHION)

# Last look: the user may have sent a new message during the cushion, or the
# background shell may have finished, which retires the ⧗ before it is written.
st = status()
if seen_status and st == 'busy':
    raise SystemExit(0)
st = st if st is not None else settled
work = agents or (st == 'shell' if seen_status else shells)

config = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.expanduser('~/.claude')
# term-busy.sh's tool-shell signature, minus `< /dev/null`: Claude Code drops that
# redirect when the command has a heredoc, and such a shell must still count.
SIGNATURE = ('shell-snapshots/snapshot-', 'pwd -P >|')
OURS = ('term-title.sh', 'term-perm.sh', 'term-busy.sh', 'term-agents.sh', 'term-done.sh')


def eval_command(cmd):
    """The command a tool shell runs: the `eval '<command>'` part of its argv."""
    start = cmd.find("eval '")
    end = cmd.rfind(' && pwd -P >|')
    if start < 0 or end < start:
        return None
    quoted = cmd[start + 5:end]
    if quoted.endswith(' < /dev/null'):
        quoted = quoted[:-len(' < /dev/null')]
    # macOS `ps` prints control characters inside argv as octal text (\012).
    quoted = re.sub(r'\\([0-3][0-7]{2})', lambda m: chr(int(m.group(1), 8)), quoted)
    try:
        return ''.join(shlex.split(quoted))
    except ValueError:
        return None


def background_commands(path):
    """Bash commands the transcript at `path` ran with run_in_background."""
    found = set()
    try:
        with open(path) as fh:
            for line in fh:
                if '"run_in_background":true' not in line:
                    continue
                try:
                    content = json.loads(line).get('message', {}).get('content')
                except Exception:
                    continue
                for item in content if isinstance(content, list) else []:
                    inp = item.get('input') or {}
                    if (item.get('type') == 'tool_use' and item.get('name') == 'Bash'
                            and inp.get('command') and inp.get('run_in_background')):
                        found.add(inp['command'])
    except OSError:
        pass
    return found


def main_commands(path):
    """Bash commands the main agent ran: (this turn's, background ones from earlier turns).

    A turn starts at the latest prompt the user typed; task notifications,
    subagent hand-backs and tool results don't count as prompts.
    """
    turn_start, runs = '', []
    try:
        with open(path) as fh:
            for line in fh:
                if '"name":"Bash"' not in line and '"type":"user"' not in line:
                    continue
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                ts = entry.get('timestamp') or ''
                content = entry.get('message', {}).get('content')
                if entry.get('type') == 'user':
                    origin = entry.get('origin')
                    if isinstance(origin, dict):
                        human = origin.get('kind') == 'human'
                    else:
                        # Older transcripts carry no `origin`: a typed prompt is
                        # plain text that isn't a harness <tag>.
                        text = content if isinstance(content, str) else ''.join(
                            i.get('text') or '' for i in content or []
                            if isinstance(i, dict) and i.get('type') == 'text')
                        human = (not entry.get('isMeta') and bool(text.strip())
                                 and not text.lstrip().startswith('<'))
                    if human and ts > turn_start:
                        turn_start = ts
                    continue
                for item in content if isinstance(content, list) else []:
                    inp = item.get('input') or {}
                    if (item.get('type') == 'tool_use' and item.get('name') == 'Bash'
                            and inp.get('command')):
                        runs.append((ts, inp['command'], bool(inp.get('run_in_background'))))
    except OSError:
        pass
    current = {c for ts, c, _ in runs if ts >= turn_start}
    earlier = {c for ts, c, bg in runs if bg and ts < turn_start}
    return current, earlier


def only_orphans():
    """True when every live tool shell is one nothing is waiting on.

    That is a shell started by a subagent that has finished (its term-agents.sh
    marker is gone), or one the main agent started in the background in an
    earlier turn: the user has prompted since, so Claude isn't idling on it.
    Shells are matched by argv; one the main agent ran this turn, or one that
    can't be attributed, still counts as real work.
    """
    try:
        data = json.loads(os.environ.get('TERM_SIGNALS_PAYLOAD') or '{}')
    except Exception:
        return False
    sid = data.get('session_id') or ''
    transcript = data.get('transcript_path') or ''
    owner = os.path.basename(session)[:-len('.json')]
    if not (sid and owner.isdigit()):
        return False
    out = subprocess.run(['ps', '-eww', '-o', 'pid=,ppid=,command='],
                         capture_output=True, text=True).stdout
    parents = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) >= 2:
            parents[parts[0]] = parts[1]
    # Never count the shell this script descends from, as term-busy.sh does.
    chain, pid = set(), str(os.getpid())
    while pid in parents and pid not in chain:
        chain.add(pid)
        pid = parents[pid]
    live = []
    for line in out.splitlines():
        parts = line.split(None, 2)
        if (len(parts) == 3 and parts[1] == owner and parts[0] not in chain
                and all(s in parts[2] for s in SIGNATURE)
                and not any(o in parts[2] for o in OURS)):
            live.append(eval_command(parts[2]))
    if not live or None in live:
        return False
    try:
        running = set(os.listdir(os.path.join(config, 'terminal-signals', 'agents', sid)))
    except OSError:
        running = set()
    roots = glob.glob(os.path.join(config, 'projects', '*', glob.escape(sid), 'subagents'))
    if transcript:
        roots.append(os.path.join(os.path.dirname(transcript), sid, 'subagents'))
    orphaned = set()
    for path in {p for r in roots
                 for p in glob.glob(os.path.join(glob.escape(r), '**', 'agent-*.jsonl'),
                                    recursive=True)}:
        if os.path.basename(path)[len('agent-'):-len('.jsonl')] not in running:
            orphaned |= background_commands(path)
    current, earlier = main_commands(transcript) if transcript else (set(), set())
    return all(c in (orphaned | earlier) and c not in current for c in live)


def orphan_title():
    """term-title.sh's sequence with the orphan glyph, for the same payload."""
    return subprocess.run(
        ['sh', os.environ.get('TERM_DEFER_TITLE') or '',
         os.environ.get('TERM_DEFER_ORPHAN_GLYPH') or '◎'],
        env=dict(os.environ, TERM_TITLE_RAW='1',
                 TERM_TITLE_PAYLOAD=os.environ.get('TERM_SIGNALS_PAYLOAD') or ''),
        capture_output=True, text=True).stdout


orphans = False
if work and not agents and st == 'shell':
    try:
        orphan_seq = only_orphans() and orphan_title()
    except Exception:
        orphan_seq = ''   # attribution is best effort; never lose the ⧗ over it
    # Attribution reads whole transcripts; the turn may have resumed meanwhile.
    if status() not in ('shell', None):
        raise SystemExit(0)
    if orphan_seq:
        orphans, seq = True, orphan_seq

# Mirrors term-busy.sh's trace: `touch ~/.claude/terminal-signals.debug`.
if os.path.exists(os.path.join(config, 'terminal-signals.debug')):
    with open(os.path.join(config, 'terminal-signals.log'), 'a') as fh:
        fh.write('defer owner=%s status=%s agents=%s shells=%s orphans=%s wrote=%s\n'
                 % (os.path.basename(session)[:-len('.json')], st, agents, shells,
                    orphans, work))

if not work:
    raise SystemExit(0)

try:
    with open(tty, 'w') as fh:
        fh.write(seq)
except OSError:
    pass
PY
