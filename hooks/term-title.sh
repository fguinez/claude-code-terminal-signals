#!/bin/sh
# Emit a terminalSequence JSON that sets the tab title to: <glyph> <name>
#
# <name> mirrors Claude Code's native tab name: a manual /rename name if set,
# else the AI-generated conversation title (the "ai-title" entries in the
# transcript), else the folder name. This keeps the attention glyph showing the
# conversation name instead of falling back to the working directory's basename.
#
# Invoked on AskUserQuestion (PreToolUse) and via term-perm.sh (PermissionRequest).
# Those hooks deliver the event JSON on stdin. term-perm.sh consumes stdin itself,
# so it forwards the payload through TERM_TITLE_PAYLOAD.
#
# Usage: term-title.sh <glyph>
glyph="$1"
payload="${TERM_TITLE_PAYLOAD:-$(cat 2>/dev/null)}"

GLYPH="$glyph" PEON_PAYLOAD="$payload" python3 <<'PY'
import json, os, glob, re

glyph = os.environ.get('GLYPH', '')
raw = os.environ.get('PEON_PAYLOAD', '') or ''
try:
    data = json.loads(raw) if raw.strip() else {}
except Exception:
    data = {}

session_id = data.get('session_id') or data.get('conversation_id') or ''
cwd = data.get('cwd') or ''
if not cwd:
    roots = data.get('workspace_roots') or []
    cwd = roots[0] if roots else ''
transcript = data.get('transcript_path') or ''


def manual_name(sid):
    # Claude /rename writes the chosen name to ~/.claude/sessions/<pid>.json —
    # but so does Claude itself, marking its own cwd-derived label
    # nameSource="derived". Only an explicit rename outranks the AI title;
    # honouring a derived name shows "connections-d6" where the native tab shows
    # the conversation's real title.
    if not sid:
        return ''
    for f in glob.glob(os.path.expanduser('~/.claude/sessions/*.json')):
        try:
            d = json.load(open(f))
        except Exception:
            continue
        if d.get('sessionId') == sid:
            if d.get('nameSource') == 'derived':
                return ''
            return (d.get('name') or '').strip()
    return ''


def find_transcript(path, sid):
    if path and os.path.isfile(path):
        return path
    if sid:
        hits = glob.glob(os.path.expanduser('~/.claude/projects/*/%s.jsonl' % sid))
        if hits:
            return hits[0]
    return ''


def ai_title(path):
    # The conversation title lives in the transcript as {"type":"ai-title", ...}.
    # Keep the last occurrence — it's the most recent title.
    if not path or not os.path.isfile(path):
        return ''
    title = ''
    try:
        with open(path) as fh:
            for line in fh:
                if '"ai-title"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if d.get('type') == 'ai-title':
                    t = (d.get('aiTitle') or '').strip()
                    if t:
                        title = t
    except Exception:
        return ''
    return title


name = manual_name(session_id) or ai_title(find_transcript(transcript, session_id))
if not name:
    name = os.path.basename(cwd.rstrip('/')) if cwd else (
        os.environ.get('CLAUDE_TITLE') or os.path.basename(os.getcwd()))

name = re.sub(r'\s+', ' ', name).strip()
name = ''.join(ch for ch in name if ch >= ' ')[:60].strip() or 'claude'

seq = '\x1b]0;{} {}\x07'.format(glyph, name)
# TERM_TITLE_RAW: hand back the bare sequence instead of the hook-protocol JSON,
# for callers that write to a tty themselves (term-defer.sh).
if os.environ.get('TERM_TITLE_RAW'):
    print(seq, end='')
else:
    print(json.dumps({'terminalSequence': seq}))
PY
