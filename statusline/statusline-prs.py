#!/usr/bin/env python3
"""Extract the pull requests this session created or acted on, for the statusline.

Only PRs reached through a `gh` command (or its output) count -- a blanket grep
over the transcript also matches every PR merely quoted in a doc or a memory.

Reads the transcript incrementally: each run resumes from the byte offset of the
previous one, so the statusline pays the full scan only once per session.

Usage: statusline-prs.py <transcript_path> <session_id> [default_owner/repo]
Output: one "owner/repo<TAB>number" per line, least recently used first.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time

CACHE_DIR = os.path.join(
    os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "statusline-cache"
)
CACHE_VERSION = 2
MAX_PRS = 12

URL_RE = re.compile(r"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/(\d+)")
API_RE = re.compile(r"\brepos/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pulls/(\d+)")
# `gh` must sit where a command starts: a transcript is full of prose and
# regexes that merely mention "gh pr", and those are not PRs this session touched.
GH_PR_RE = re.compile(
    r"(?:^|[\n;&|]|\$\()\s*(?:[A-Za-z_]\w*=\S*\s+)*gh\s+(?:pr|api)\b"
)
REPO_FLAG_RE = re.compile(r"(?:-R|--repo)[=\s]+([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)")
BARE_NUM_RE = re.compile(
    r"\bgh\s+pr\s+(?:view|checks|edit|comment|merge|close|reopen|ready|diff|review)\s+#?(\d+)\b"
)


def load_cache(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            cache = json.load(fh)
    except (OSError, ValueError):
        return {}
    if cache.get("version") != CACHE_VERSION:
        return {}
    return cache


def prune_cache(directory: str) -> None:
    """Drop caches of sessions nobody has opened in a month."""
    cutoff = time.time() - 30 * 86400
    try:
        entries = os.scandir(directory)
    except OSError:
        return
    with entries:
        for entry in entries:
            try:
                if entry.is_file() and entry.stat().st_mtime < cutoff:
                    os.unlink(entry.path)
            except OSError:
                pass


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
    """Collect every string reachable from a tool_result content payload."""
    if isinstance(node, str):
        out.append(node)
    elif isinstance(node, list):
        for item in node:
            iter_text(item, out)
    elif isinstance(node, dict):
        for key in ("text", "content", "stdout", "stderr"):
            if key in node:
                iter_text(node[key], out)


def refs_in(
    text: str, fallback_repo: str | None
) -> tuple[list[str], str | None, list[str]]:
    """PR slugs found in one command or its output, plus the repo they imply.

    `gh pr view 174` carries no repo -- the Bash tool's cwd does, and that is not
    in the transcript. The repo of the last PR the session touched is a far better
    guess than the session's cwd, which in a multi-root workspace is rarely the
    repo being worked on. Bare numbers seen before any repo is known come back
    unresolved, for the caller to attach once one is.
    """
    refs = [f"{o}/{r}#{n}" for o, r, n in URL_RE.findall(text)]
    refs += [f"{o}/{r}#{n}" for o, r, n in API_RE.findall(text)]
    flagged = REPO_FLAG_RE.search(text)
    repo = flagged.group(1) if flagged else (refs[-1].split("#")[0] if refs else None)
    if repo or fallback_repo:
        refs += [f"{repo or fallback_repo}#{n}" for n in BARE_NUM_RE.findall(text)]
        return refs, repo, []
    return refs, repo, BARE_NUM_RE.findall(text)


def main() -> int:
    if len(sys.argv) < 3:
        return 0
    transcript, session_id = sys.argv[1], sys.argv[2]
    default_repo = sys.argv[3] if len(sys.argv) > 3 else None

    try:
        size = os.path.getsize(transcript)
    except OSError:
        return 0

    cache_path = os.path.join(CACHE_DIR, f"prs-{session_id}.json")
    cache = load_cache(cache_path)
    offset = cache.get("offset", 0)
    # A shrunk transcript means it was rewritten (compaction, rollback): rescan.
    if offset > size:
        cache, offset = {}, 0
    if not cache:
        prune_cache(CACHE_DIR)
    pending = set(cache.get("pending", []))
    prs: dict[str, int] = cache.get("prs", {})
    seq = cache.get("seq", 0)
    last_repo = cache.get("last_repo")
    orphans: list[list] = cache.get("orphans", [])

    if offset < size:
        try:
            with open(transcript, "rb") as fh:
                fh.seek(offset)
                chunk = fh.read()
        except OSError:
            return 0
        cut = chunk.rfind(b"\n")
        if cut == -1:
            chunk = b""
        else:
            offset += cut + 1
            chunk = chunk[: cut + 1]

        for raw in chunk.splitlines():
            if b"gh pr" not in raw and b"/pull/" not in raw and b"/pulls/" not in raw:
                continue
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            content = (entry.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for item in content:
                if not isinstance(item, dict):
                    continue
                kind = item.get("type")
                texts: list[str] = []
                if kind == "tool_use":
                    command = (item.get("input") or {}).get("command")
                    if not isinstance(command, str) or not GH_PR_RE.search(command):
                        continue
                    if item.get("id"):
                        pending.add(item["id"])
                    texts = [command]
                elif kind == "tool_result":
                    if item.get("tool_use_id") not in pending:
                        continue
                    pending.discard(item["tool_use_id"])
                    iter_text(item.get("content"), texts)
                else:
                    continue
                found, repo, orphaned = refs_in("\n".join(texts), last_repo)
                for slug in found:
                    seq += 1
                    prs[slug] = seq
                for num in orphaned:
                    seq += 1
                    orphans.append([seq, num])
                if repo or (found and not last_repo):
                    last_repo = repo or found[-1].split("#")[0]
                    for oseq, num in orphans:
                        prs.setdefault(f"{last_repo}#{num}", oseq)
                    orphans = []

        if len(prs) > MAX_PRS:
            keep = sorted(prs.items(), key=lambda kv: kv[1])[-MAX_PRS:]
            prs = dict(keep)
        # Unmatched ids pile up when a gh command's result is never parsed.
        if len(pending) > 200:
            pending = set()
        save_cache(
            cache_path,
            {
                "version": CACHE_VERSION,
                "offset": offset,
                "pending": sorted(pending),
                "prs": prs,
                "seq": seq,
                "last_repo": last_repo,
                "orphans": orphans,
            },
        )

    rendered = dict(prs)
    if default_repo and "/" in default_repo:
        for oseq, num in orphans:
            rendered.setdefault(f"{default_repo}#{num}", oseq)

    for key, _ in sorted(rendered.items(), key=lambda kv: kv[1]):
        slug, _, num = key.partition("#")
        print(f"{slug}\t{num}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
