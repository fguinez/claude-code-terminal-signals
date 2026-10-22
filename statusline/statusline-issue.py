#!/usr/bin/env python3
"""Pick the issue, incident or card this session is about, for the statusline.

A session is almost always focused on one item (implement, QA, babysit or
monitor a Linear issue; work an incident.io incident), though others get
mentioned along the way. Each mention is scored by where it appears -- the
user's own prompts and writes to the tracker weigh far more than the model's
prose -- and the top score across all trackers wins once it clears a threshold.
Injected text (memory index, skill bodies, subagent reports) is not counted:
it quotes dozens of issues the session never touches.

Trackers are opt-in, each through its own env vars (see configured_trackers):
  Linear       CLAUDE_STATUSLINE_LINEAR_WORKSPACE + CLAUDE_STATUSLINE_LINEAR_TEAMS
  incident.io  CLAUDE_STATUSLINE_INCIDENT_IO_ORG
  Jira         CLAUDE_STATUSLINE_JIRA_SITE + CLAUDE_STATUSLINE_JIRA_PROJECTS
  Trello       CLAUDE_STATUSLINE_TRELLO=1

Reads the transcript incrementally, like statusline-prs.py.

Usage: statusline-issue.py <transcript_path> <session_id> [current_branch]
Output: "<key>\t<url>" for the winner, or nothing.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from urllib.parse import quote

CACHE_DIR = os.path.join(
    os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "statusline-cache"
)
CACHE_VERSION = 2
MIN_SCORE = 3.0

GH_RE = re.compile(r"(?:^|[\n;&|]|\$\()\s*(?:[A-Za-z_]\w*=\S*\s+)*gh\s+(?:pr|api)\b")
GH_WRITE_RE = re.compile(r"\bgh\s+pr\s+(?:create|edit)\b")
NEW_BRANCH_RE = re.compile(
    r"\bgit\b[^\n]*?\s(?:checkout\s+-[bB]|switch\s+-[cC]|worktree\s+add\b[^\n]*?\s-[bB])\s+(\S+)"
)
INJECTED_PREFIXES = ("<task-notification", "<local-command", "<system-reminder")
COMMAND_ARGS_RE = re.compile(r"<command-args>(.*?)</command-args>", re.DOTALL)
REMINDER_RE = re.compile(r"<system-reminder>.*?</system-reminder>", re.DOTALL)

# a tracker tool writes when its name carries one of these verbs and no read verb
# (save_issue, incident_update, addCommentToJiraIssue; not incident_update_list)
TOOL_WORD_RE = re.compile(r"[A-Z]?[a-z]+")
WRITE_VERBS = {
    "save", "create", "update", "edit", "delete", "add", "post", "change",
    "transition", "move", "archive", "assign", "attach", "resolve", "merge", "comment",
}
READ_VERBS = {"get", "list", "show", "search", "read", "fetch", "find", "query", "lookup"}

W_FIRST_PROMPT = 10.0
W_PROMPT = 4.0
W_SKILL_ARGS = 8.0
W_TRACKER_WRITE = 6.0
W_TRACKER_READ = 3.0
W_PR_WRITE = 5.0
W_NEW_BRANCH = 4.0
W_PR_OUTPUT = 2.0
W_TOOL_INPUT = 1.0
W_ASSISTANT = 0.5
W_CURRENT_BRANCH = 6.0


# example keys people type when describing a format, not an issue
PLACEHOLDER_NUMS = {"1", "123", "1234", "12345", "0000", "9999"}

# key -> [tracker name, url]
Hits = dict[str, list[str]]


class Tracker:
    """Where a tracker's keys show up in text, and the link each one opens.

    `prefixes` match KEY-123 keys; `patterns` are extra regexes (mostly links)
    whose named groups fill the `key` and `url` templates, as do the prefix
    match's `prefix` and `num`.
    """

    def __init__(
        self,
        name: str,
        url: str,
        *,
        prefixes: tuple[str, ...] | list[str] = (),
        patterns: tuple[str, ...] = (),
        key: str = "{prefix}-{num}",
        tools: tuple[str, ...] = (),
    ) -> None:
        self.name, self.url, self.key, self.tools = name, url, key, tools
        extra = [re.compile(p) for p in patterns]
        self.regexes = list(extra)
        self.regexes_i = list(extra)
        if prefixes:
            alt = "|".join(sorted(map(re.escape, prefixes), key=len, reverse=True))
            key_re = rf"(?<![A-Za-z0-9])(?P<prefix>{alt})-(?P<num>\d{{1,7}})(?![0-9])"
            # branch names carry the key lowercased (chore/con-1234-foo); outside a
            # branch lowercase matches are prose ("top-10"), so only after a slash
            branch_re = re.compile(rf"(?<=/)(?P<prefix>{alt})-(?P<num>\d{{1,7}})(?![0-9])", re.I)
            self.regexes += [re.compile(key_re), branch_re]
            self.regexes_i += [re.compile(key_re, re.I), branch_re]

    def owns_tool(self, tool_name: str) -> bool:
        lowered = tool_name.lower()
        return any(hint in lowered for hint in self.tools)

    def fingerprint(self) -> list:
        return [self.name, self.url, self.key, [r.pattern for r in self.regexes]]


def env_value(name: str) -> str:
    return os.environ.get(name, "").strip()


def configured_trackers() -> list[Tracker]:
    trackers = []

    workspace = env_value("CLAUDE_STATUSLINE_LINEAR_WORKSPACE")
    teams = env_value("CLAUDE_STATUSLINE_LINEAR_TEAMS").split()
    if workspace and teams:
        trackers.append(
            Tracker(
                "linear",
                f"https://linear.app/{quote(workspace, safe='')}/issue/{{key}}",
                prefixes=teams,
                tools=("linear",),
            )
        )

    org = env_value("CLAUDE_STATUSLINE_INCIDENT_IO_ORG")
    if org:
        # incidents are INC-<n> everywhere, and their links accept the bare number
        trackers.append(
            Tracker(
                "incident.io",
                f"https://app.incident.io/{quote(org, safe='')}/incidents/{{num}}",
                prefixes=("INC",),
                patterns=(rf"app\.incident\.io/{re.escape(org)}/incidents/(?P<num>\d{{1,7}})(?!\w)",),
                key="INC-{num}",
                tools=("incident_io", "incidentio"),
            )
        )

    site = re.sub(r"^https?://", "", env_value("CLAUDE_STATUSLINE_JIRA_SITE")).rstrip("/")
    projects = env_value("CLAUDE_STATUSLINE_JIRA_PROJECTS").split()
    if site and projects:
        trackers.append(
            Tracker(
                "jira",
                "https://" + site.replace("{", "{{").replace("}", "}}") + "/browse/{key}",
                prefixes=projects,
                tools=("jira",),
            )
        )

    if env_value("CLAUDE_STATUSLINE_TRELLO").lower() not in ("", "0", "false"):
        # cards have no KEY-123 form; only their links name them
        trackers.append(
            Tracker(
                "trello",
                "https://trello.com/c/{card}",
                patterns=(r"trello\.com/c/(?P<card>[A-Za-z0-9]{8})(?![A-Za-z0-9])",),
                key="{card}",
                tools=("trello",),
            )
        )

    return trackers


TRACKERS = configured_trackers()
# a cheap per-line filter: the trackers' regexes with their named groups dropped
_PREFILTER = "|".join(
    re.sub(r"\(\?P<\w+>", "(?:", r.pattern) for t in TRACKERS for r in t.regexes_i
)
PREFILTER_RE = re.compile(_PREFILTER.encode(), re.IGNORECASE) if _PREFILTER else None


def keys_in(text: str, ignore_case: bool = False) -> Hits:
    """Every tracker key in `text`; the first tracker to claim a key keeps it."""
    hits: Hits = {}
    for tracker in TRACKERS:
        for regex in tracker.regexes_i if ignore_case else tracker.regexes:
            for match in regex.finditer(text):
                fields = {k: v for k, v in match.groupdict().items() if v is not None}
                if fields.get("num") in PLACEHOLDER_NUMS:
                    continue
                if "prefix" in fields:
                    fields["prefix"] = fields["prefix"].upper()
                try:
                    key = tracker.key.format(**fields)
                    url = tracker.url.format(key=key, **fields)
                except (KeyError, IndexError, ValueError):
                    continue
                hits.setdefault(key, [tracker.name, url])
    return hits


def is_write_tool(tool_name: str) -> bool:
    words = {w.lower() for w in TOOL_WORD_RE.findall(tool_name.rsplit("__", 1)[-1])}
    return bool(words & WRITE_VERBS) and not words & READ_VERBS


def config_fingerprint() -> str:
    raw = json.dumps([t.fingerprint() for t in TRACKERS])
    return hashlib.sha1(raw.encode()).hexdigest()


def load_cache(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            cache = json.load(fh)
    except (OSError, ValueError):
        return {}
    # a tracker added or reconfigured since needs the whole transcript again
    if cache.get("version") != CACHE_VERSION or cache.get("trackers") != config_fingerprint():
        return {}
    return cache


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
        self.hits: Hits = cache.get("hits", {})
        self.seq: int = cache.get("seq", 0)
        self.prompts: int = cache.get("prompts", 0)
        self.pending: set[str] = set(cache.get("pending", []))

    def add(self, hits: Hits, weight: float) -> None:
        for key, hit in hits.items():
            self.seq += 1
            self.scores[key] = self.scores.get(key, 0.0) + weight
            self.last_seen[key] = self.seq
            self.hits[key] = hit

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
        owners = {t.name for t in TRACKERS if t.owns_tool(name)}
        if name == "Skill":
            self.add(keys_in(str(tool_input.get("args") or "")), W_SKILL_ARGS)
        elif owners:
            # a Linear write is about its Linear issue, not the incident it links
            hits = keys_in(raw)
            own = {k: h for k, h in hits.items() if h[0] in owners}
            self.add(own, W_TRACKER_WRITE if is_write_tool(name) else W_TRACKER_READ)
            self.add({k: h for k, h in hits.items() if k not in own}, W_TOOL_INPUT)
        elif isinstance(command, str):
            if GH_RE.search(command) and item.get("id"):
                self.pending.add(item["id"])
            if GH_WRITE_RE.search(command):
                self.add(keys_in(command), W_PR_WRITE)
            branch_hits = keys_in(" ".join(NEW_BRANCH_RE.findall(command)), ignore_case=True)
            self.add(branch_hits, W_NEW_BRANCH)
            self.add({k: h for k, h in keys_in(command).items() if k not in branch_hits}, W_TOOL_INPUT)
        else:
            self.add(keys_in(raw), W_TOOL_INPUT)

    def dump(self, offset: int) -> dict:
        if len(self.pending) > 200:
            self.pending = set()
        return {
            "version": CACHE_VERSION,
            "trackers": config_fingerprint(),
            "offset": offset,
            "scores": self.scores,
            "last_seen": self.last_seen,
            "hits": self.hits,
            "seq": self.seq,
            "prompts": self.prompts,
            "pending": sorted(self.pending),
        }


def main() -> int:
    if len(sys.argv) < 3 or PREFILTER_RE is None:
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
            if not PREFILTER_RE.search(raw) and b"gh " not in raw:
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
    hits = dict(scorer.hits)
    for key, hit in keys_in(branch, ignore_case=True).items():
        scores[key] = scores.get(key, 0.0) + W_CURRENT_BRANCH
        last_seen.setdefault(key, 0)
        hits.setdefault(key, hit)

    if not scores:
        return 0
    best = max(scores, key=lambda k: (scores[k], last_seen.get(k, 0)))
    if scores[best] >= MIN_SCORE:
        print(f"{best}\t{hits[best][1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
