#!/usr/bin/env python3
"""Pick the git repo this session is working in, for the statusline.

A session started in a multi-root workspace folder rarely works in the repo
that folder belongs to: it reaches the real ones through `git -C`, `cd`, edits
by absolute path and worktrees. Each such touch scores its repo, older scores
decay, and the top one wins -- so a one-off lookup in another repo does not
steal the segment, but moving on to a new repo does after a few touches.

Shell variables are followed (`WT=...; git -C "$WT"`): the Bash tool keeps no
shell state, so sessions redeclare them, and the last value seen is kept.

Reads the transcript incrementally, like statusline-prs.py.

Usage: statusline-repo.py <transcript_path> <session_id> [project_dir]
Output: "<toplevel><TAB><repo name>", or nothing. For a linked worktree the
name is the main repo's.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys

CACHE_DIR = os.path.join(
    os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "statusline-cache"
)
CACHE_VERSION = 1
HOME = os.path.expanduser("~")

DECAY = 0.85
MIN_SCORE = 0.1
W_WRITE = 3.0
W_CD = 2.0
W_READ = 1.0
W_FILE_READ = 0.5

WRITE_TOOLS = {"Edit", "Write", "NotebookEdit", "MultiEdit"}
READ_TOOLS = {"Read", "Grep", "Glob"}
# git subcommands that change the repo, as opposed to looking at it
GIT_WRITES = {
    "add", "am", "checkout", "cherry-pick", "commit", "merge", "pull", "push",
    "rebase", "reset", "restore", "revert", "rm", "stash", "switch", "worktree",
}

ASSIGN_RE = re.compile(r"(?:^|[\s;&|(])(?:export\s+)?([A-Za-z_]\w*)=(\"[^\"]*\"|'[^']*'|[^\s;&|)]+)")
VAR_RE = re.compile(r"\$\{([A-Za-z_]\w*)\}|\$([A-Za-z_]\w*)")
HEREDOC_RE = re.compile(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n.*?\n\s*\2(?=\n|$)", re.DOTALL)
OPERATORS = {";", "&", "&&", "|", "||", "\n", "(", ")", ";;", "|&"}


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


def repo_of(path: str) -> tuple[str, str] | None:
    """(toplevel, repo name) of the repo holding path, found by walking up to .git."""
    path = os.path.normpath(path)
    while path and not os.path.isdir(path):
        parent = os.path.dirname(path)
        if parent == path:
            return None
        path = parent
    while True:
        dot_git = os.path.join(path, ".git")
        if os.path.isdir(dot_git):
            return path, os.path.basename(path)
        if os.path.isfile(dot_git):
            # a linked worktree: "gitdir: <main>/.git/worktrees/<name>"
            try:
                with open(dot_git, encoding="utf-8") as fh:
                    gitdir = fh.read().strip().removeprefix("gitdir:").strip()
            except OSError:
                return path, os.path.basename(path)
            # submodules keep theirs under <super>/.git/modules/<name>
            marker = f"{os.sep}worktrees{os.sep}"
            if marker not in gitdir:
                return path, os.path.basename(path)
            common = gitdir.split(marker)[0]
            if os.path.basename(common) == ".git":
                common = os.path.dirname(common)
            return path, os.path.basename(common)
        parent = os.path.dirname(path)
        if parent == path or path == HOME:
            return None
        path = parent


def segments(command: str) -> list[list[str]]:
    """Split a shell command into simple commands, respecting quotes."""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()\n")
    lexer.whitespace = " \t\r"
    lexer.commenters = "#"
    out: list[list[str]] = [[]]
    try:
        for token in lexer:
            if token in OPERATORS or set(token) <= set(";&|()\n"):
                out.append([])
            else:
                out[-1].append(token)
    except ValueError:
        pass
    return [words for words in out if words]


class Tracker:
    def __init__(self, cache: dict, project_dir: str) -> None:
        self.scores: dict[str, float] = cache.get("scores", {})
        self.names: dict[str, str] = cache.get("names", {})
        self.vars: dict[str, str] = cache.get("vars", {})
        self.last_cwd: str | None = cache.get("last_cwd")
        self.project_dir = project_dir.rstrip("/")
        self.cwd = self.last_cwd or project_dir

    def touch(self, path: str, weight: float) -> None:
        if not path or "$" in path:
            return
        if not os.path.isabs(path):
            path = os.path.join(self.cwd, path)
        found = repo_of(path)
        if not found:
            return
        top, name = found
        for key in self.scores:
            self.scores[key] *= DECAY
        self.scores[top] = self.scores.get(top, 0.0) + weight
        self.names[top] = name

    def expand(self, text: str) -> str:
        text = VAR_RE.sub(lambda m: self.vars.get(m.group(1) or m.group(2), m.group(0)), text)
        return re.sub(r"(?<![\w/])~(?=/|\s|$|\"|')", HOME, text).replace("$HOME", HOME)

    def command(self, command: str) -> None:
        for name, value in ASSIGN_RE.findall(command):
            value = self.expand(value.strip("\"'"))
            if "/" in value:
                self.vars[name] = value
        if "HOME" not in self.vars:
            self.vars["HOME"] = HOME
        for words in segments(self.expand(HEREDOC_RE.sub("", command))):
            while words and re.match(r"^[A-Za-z_]\w*=", words[0]):
                words = words[1:]
            if words:
                self.segment(words)

    def segment(self, words: list[str]) -> None:
        head = words[0]
        if head in ("cd", "pushd") and len(words) > 1:
            self.touch(words[1], W_CD)
        elif head == "git" and "-C" in words:
            i = words.index("-C")
            if i + 1 < len(words):
                rest = [w for w in words[i + 2 :] if not w.startswith("-")]
                sub = rest[0] if rest else ""
                self.touch(words[i + 1], W_WRITE if sub in GIT_WRITES else W_READ)
        for i, word in enumerate(words[:-1]):
            if word in ("--directory", "--project") and head in ("uv", "make"):
                self.touch(words[i + 1], W_READ)
        for word in words:
            if word.startswith(("--directory=", "--project=")) and head in ("uv", "make"):
                self.touch(word.split("=", 1)[1], W_READ)
        if head == "git" and "worktree" in words and "add" in words:
            # git worktree add [-b name] <path> [commit]
            after = words[words.index("add") + 1 :]
            positional = []
            skip = False
            for word in after:
                if skip:
                    skip = False
                elif word in ("-b", "-B", "--reason"):
                    skip = True
                elif not word.startswith("-"):
                    positional.append(word)
            if positional:
                self.touch(positional[0], W_WRITE)

    def tool_use(self, item: dict) -> None:
        name = item.get("name") or ""
        tool_input = item.get("input") or {}
        if not isinstance(tool_input, dict):
            return
        if name == "Bash" and isinstance(tool_input.get("command"), str):
            self.command(tool_input["command"])
        elif name in WRITE_TOOLS:
            self.touch(str(tool_input.get("file_path") or tool_input.get("notebook_path") or ""), W_WRITE)
        elif name in READ_TOOLS:
            path = str(tool_input.get("file_path") or tool_input.get("path") or "")
            # the workspace folder's own rules and docs get read in every session
            if path and not (path + "/").startswith(self.project_dir + "/"):
                self.touch(path, W_FILE_READ)

    def entry(self, entry: dict) -> None:
        cwd = entry.get("cwd")
        if isinstance(cwd, str) and cwd:
            # the session moved: a persisted `cd` or a worktree it entered
            if self.last_cwd and cwd != self.last_cwd:
                self.cwd = cwd
                self.touch(cwd, W_CD)
            self.last_cwd = cwd
            self.cwd = cwd
        if entry.get("type") != "assistant":
            return
        content = (entry.get("message") or {}).get("content")
        if not isinstance(content, list):
            return
        for item in content:
            if isinstance(item, dict) and item.get("type") == "tool_use":
                self.tool_use(item)

    def dump(self, offset: int) -> dict:
        scores = {k: v for k, v in self.scores.items() if v >= MIN_SCORE / 10}
        return {
            "version": CACHE_VERSION,
            "offset": offset,
            "scores": scores,
            "names": {k: self.names[k] for k in scores if k in self.names},
            "vars": dict(list(self.vars.items())[-50:]),
            "last_cwd": self.last_cwd,
        }


def main() -> int:
    if len(sys.argv) < 3:
        return 0
    transcript, session_id = sys.argv[1], sys.argv[2]
    project_dir = sys.argv[3] if len(sys.argv) > 3 else ""

    try:
        size = os.path.getsize(transcript)
    except OSError:
        return 0

    cache_path = os.path.join(CACHE_DIR, f"repo-{session_id}.json")
    cache = load_cache(cache_path)
    offset = cache.get("offset", 0)
    if offset > size:
        cache, offset = {}, 0
    tracker = Tracker(cache, project_dir)

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
            if b'"cwd"' not in raw:
                continue
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            if entry.get("isSidechain"):
                continue
            tracker.entry(entry)
        save_cache(cache_path, tracker.dump(offset))

    # a worktree removed since (babysit cleans up) no longer counts
    live = {k: v for k, v in tracker.scores.items() if v >= MIN_SCORE and os.path.isdir(k)}
    if not live:
        return 0
    best = max(live, key=live.__getitem__)
    print(f"{best}\t{tracker.names.get(best, os.path.basename(best))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
