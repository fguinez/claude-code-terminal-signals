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
# Usage: term-defer.sh <tty path> <session json> <escape sequence>
[ $# -eq 3 ] || exit 0

TERM_DEFER_TTY="$1" TERM_DEFER_SESSION="$2" TERM_DEFER_SEQ="$3" python3 <<'PY' 2>/dev/null
import json, os, time

tty = os.environ['TERM_DEFER_TTY']
session = os.environ['TERM_DEFER_SESSION']
seq = os.environ['TERM_DEFER_SEQ']

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


seen_status = False
deadline = time.time() + WAIT
while time.time() < deadline:
    st = status()
    if st is not None:
        seen_status = True
        if st != 'busy':
            break
    time.sleep(0.1)
else:
    # Never stopped being busy. If the field is readable that means the session
    # is genuinely working again, so leave its title alone.
    if seen_status:
        raise SystemExit(0)

time.sleep(CUSHION)

# Last check: the user may have sent a new message during the cushion.
if seen_status and status() == 'busy':
    raise SystemExit(0)

try:
    with open(tty, 'w') as fh:
        fh.write(seq)
except OSError:
    pass
PY
