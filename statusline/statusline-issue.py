#!/usr/bin/env python3
"""Pick the Linear issue this session is about, for the statusline.

A session is almost always focused on one issue (implement, QA, babysit or
monitor it), though others get mentioned along the way. Each mention is scored
by where it appears -- the user's own prompts and writes to Linear weigh far more
than the model's prose -- and the top score wins once it clears a threshold.
Injected text (memory index, skill bodies, subagent reports) is not counted:
it quotes dozens of issues the session never touches.

Reads the transcript incrementally, like statusline-prs.py.

Usage: statusline-issue.py <transcript_path> <session_id> [current_branch]
Output: the issue key (e.g. CON-1234), or nothing.
"""

from __future__ import annotations

import json
import os
import re
import sys

CACHE_DIR = os.path.join(
    os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "statusline-cache"
)
CACHE_VERSION = 1
MIN_SCORE = 3.0

# Space-separated Linear team keys of the workspace (e.g. "ENG OPS"); a generic
# [A-Z]+-\d+ also matches UTF-8, INC-123 (incident.io) and the like.
TEAM_KEYS = os.environ.get("CLAUDE_STATUSLINE_LINEAR_TEAMS", "").split()
# with no keys configured nothing can match; the placeholder keeps the regex valid
_KEYS_ALT = "|".join(sorted(TEAM_KEYS, key=len, reverse=True)) or "(?!)"
KEY_RE = re.compile(rf"(?<![A-Za-z0-9])({_KEYS_ALT})-(\d{{1,6}})(?![0-9])")
KEY_RE_I = re.compile(KEY_RE.pattern, re.IGNORECASE)
# branch names carry the key lowercased (chore/con-1234-foo); outside a branch
# lowercase matches are prose ("top-10"), so only take them after a slash
BRANCH_KEY_RE = re.compile(rf"(?<=/)({_KEYS_ALT})-(\d{{1,6}})(?![0-9])", re.IGNORECASE)
KEY_BYTES_RE = re.compile(KEY_RE_I.pattern.encode(), re.IGNORECASE)

GH_RE = re.compile(r"(?:^|[\n;&|]|\$\()\s*(?:[A-Za-z_]\w*=\S*\s+)*gh\s+(?:pr|api)\b")
GH_WRITE_RE = re.compile(r"\bgh\s+pr\s+(?:create|edit)\b")
NEW_BRANCH_RE = re.compile(
    r"\bgit\b[^\n]*?\s(?:checkout\s+-[bB]|switch\s+-[cC]|worktree\s+add\b[^\n]*?\s-[bB])\s+(\S+)"
)
INJECTED_PREFIXES = ("<task-notification", "<local-command", "<system-reminder")
COMMAND_ARGS_RE = re.compile(r"<command-args>(.*?)</command-args>", re.DOTALL)
REMINDER_RE = re.compile(r"<system-reminder>.*?</system-reminder>", re.DOTALL)

W_FIRST_PROMPT = 10.0
W_PROMPT = 4.0
W_SKILL_ARGS = 8.0
W_LINEAR_WRITE = 6.0
W_LINEAR_READ = 3.0
W_PR_WRITE = 5.0
W_NEW_BRANCH = 4.0
W_PR_OUTPUT = 2.0
W_TOOL_INPUT = 1.0
W_ASSISTANT = 0.5
W_CURRENT_BRANCH = 6.0


# example keys people type when describing a format, not an issue
PLACEHOLDER_NUMS = {"1", "123", "1234", "12345", "0000", "9999"}


def keys_in(text: str, ignore_case: bool = False) -> set[str]:
    found = (KEY_RE_I if ignore_case else KEY_RE).findall(text)
    found += BRANCH_KEY_RE.findall(text)
    return {f"{team.upper()}-{num}" for team, num in found if num not in PLACEHOLDER_NUMS}


def load_cache(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            cache = json.load(fh)
    except (OSError, ValueError):
        return {}
    return cache if cache.get("version") == CACHE_VERSION else {}


def save_cache(path: str, cache: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(cache, fh)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def iter_text(node, out: list[str]) -> None:
    if isinstance(node, str):
        out.append(node)
    elif isinstance(node, list):
        for item in node:
            iter_text(item, out)
    elif isinstance(node, dict):
        for key in ("text", "content", "stdout", "stderr"):
            if key in node:
                iter_text(node[key], out)


def prompt_text(content) -> str | None:
    """The words the user typed, or None for injected or tool-result entries."""
    if isinstance(content, str):
        parts = [content]
    elif isinstance(content, list):
        if any(isinstance(c, dict) and c.get("type") == "tool_result" for c in content):
            return None
        parts = [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"]
    else:
        return None
    text = REMINDER_RE.sub("", "\n".join(parts)).strip()
    if "<command-name>" in text:
        args = COMMAND_ARGS_RE.search(text)
        return args.group(1) if args else ""
    if not text or text.startswith(INJECTED_PREFIXES):
        return None
    return text


class Scorer:
    def __init__(self, cache: dict) -> None:
        self.scores: dict[str, float] = cache.get("scores", {})
        self.last_seen: dict[str, int] = cache.get("last_seen", {})
        self.seq: int = cache.get("seq", 0)
        self.prompts: int = cache.get("prompts", 0)
        self.pending: set[str] = set(cache.get("pending", []))

    def add(self, keys: set[str], weight: float) -> None:
        for key in keys:
            self.seq += 1
            self.scores[key] = self.scores.get(key, 0.0) + weight
            self.last_seen[key] = self.seq

    def user_entry(self, entry: dict, content) -> None:
        if entry.get("isMeta") or entry.get("isCompactSummary"):
            return
        if isinstance(content, list):
            for item in content:
                if isinstance(item, dict) and item.get("type") == "tool_result":
                    self.tool_result(item)
        text = prompt_text(content)
        if text is None:
            return
        self.prompts += 1
        self.add(keys_in(text), W_FIRST_PROMPT if self.prompts == 1 else W_PROMPT)

    def tool_result(self, item: dict) -> None:
        if item.get("tool_use_id") not in self.pending:
            return
        self.pending.discard(item["tool_use_id"])
        texts: list[str] = []
        iter_text(item.get("content"), texts)
        self.add(keys_in("\n".join(texts)), W_PR_OUTPUT)

    def assistant_entry(self, content) -> None:
        if not isinstance(content, list):
            return
        for item in content:
            if not isinstance(item, dict):
                continue
            if item.get("type") == "text":
                self.add(keys_in(item.get("text", "")), W_ASSISTANT)
            elif item.get("type") == "tool_use":
                self.tool_use(item)

    def tool_use(self, item: dict) -> None:
        name = item.get("name") or ""
        tool_input = item.get("input") or {}
        command = tool_input.get("command") if isinstance(tool_input, dict) else None
        raw = json.dumps(tool_input, ensure_ascii=False)
        if name == "Skill":
            self.add(keys_in(str(tool_input.get("args") or "")), W_SKILL_ARGS)
        elif "linear" in name.lower():
            write = re.search(r"__(?:save|create|update|delete)_", name) is not None
            self.add(keys_in(raw), W_LINEAR_WRITE if write else W_LINEAR_READ)
        elif isinstance(command, str):
            if GH_RE.search(command) and item.get("id"):
                self.pending.add(item["id"])
            if GH_WRITE_RE.search(command):
                self.add(keys_in(command), W_PR_WRITE)
            branches = " ".join(NEW_BRANCH_RE.findall(command))
            self.add(keys_in(branches, ignore_case=True), W_NEW_BRANCH)
            self.add(keys_in(command) - keys_in(branches, ignore_case=True), W_TOOL_INPUT)
        else:
            self.add(keys_in(raw), W_TOOL_INPUT)

    def dump(self, offset: int) -> dict:
        if len(self.pending) > 200:
            self.pending = set()
        return {
            "version": CACHE_VERSION,
            "offset": offset,
            "scores": self.scores,
            "last_seen": self.last_seen,
            "seq": self.seq,
            "prompts": self.prompts,
            "pending": sorted(self.pending),
        }


def main() -> int:
    if len(sys.argv) < 3 or not TEAM_KEYS:
        return 0
    transcript, session_id = sys.argv[1], sys.argv[2]
    branch = sys.argv[3] if len(sys.argv) > 3 else ""

    try:
        size = os.path.getsize(transcript)
    except OSError:
        return 0

    cache_path = os.path.join(CACHE_DIR, f"issue-{session_id}.json")
    cache = load_cache(cache_path)
    offset = cache.get("offset", 0)
    if offset > size:
        cache, offset = {}, 0
    scorer = Scorer(cache)

    if offset < size:
        try:
            with open(transcript, "rb") as fh:
                fh.seek(offset)
                chunk = fh.read()
        except OSError:
            return 0
        cut = chunk.rfind(b"\n")
        chunk = b"" if cut == -1 else chunk[: cut + 1]
        offset += len(chunk)

        for raw in chunk.splitlines():
            # gh commands matter even without a key: their output may carry one
            if not KEY_BYTES_RE.search(raw) and b"gh " not in raw:
                continue
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            if entry.get("isSidechain"):
                continue
            content = (entry.get("message") or {}).get("content")
            if entry.get("type") == "user":
                scorer.user_entry(entry, content)
            elif entry.get("type") == "assistant":
                scorer.assistant_entry(content)
        save_cache(cache_path, scorer.dump(offset))

    scores = dict(scorer.scores)
    last_seen = dict(scorer.last_seen)
    for key in keys_in(branch, ignore_case=True):
        scores[key] = scores.get(key, 0.0) + W_CURRENT_BRANCH
        last_seen.setdefault(key, 0)
    if not scores:
        return 0
    best = max(scores, key=lambda k: (scores[k], last_seen.get(k, 0)))
    if scores[best] >= MIN_SCORE:
        print(best)
    return 0


if __name__ == "__main__":
    sys.exit(main())
