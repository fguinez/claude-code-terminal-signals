# claude-code-terminal-signals

Tell your [Claude Code](https://claude.com/claude-code) sessions apart at a glance — straight from the terminal tab bar.

Two small, independent features:

1. **Attention glyphs** — when a session is waiting on *you*, its tab gets a glyph prefix so you can spot it across a sea of tabs, alongside the **conversation name** (not the folder):
   - `✦ <name>` — Claude is asking a clarifying question (`AskUserQuestion`)
   - `✿ <name>` — Claude is waiting for you to approve a tool/permission
2. **Unique bar color per session** — every new interactive `claude` session opens with a different `/color`, so tabs are visually distinct at a glance.

## Demo

![Four Claude Code terminal tabs, each in a different session color, each prefixed by a state glyph: ⠋ working, ✳ finished, ✦ clarifying question, ✿ permission prompt — with the conversation name as the label](docs/tab-states.svg)

*Two sessions need you (`✦`, `✿`) and two don't (`⠋`, `✳`) — and each is a different color. You can tell which is which without opening any of them.*

> Mockup illustrating the states. To drop in a real recording, save a GIF/PNG to `docs/` and point this `![...]()` at it.

### Tab states at a glance

By default, Claude Code already labels the tab with the conversation's AI-generated title and animates a working/idle indicator — so you can tell sessions apart by *what they're about*, not just by folder. This repo extends that to the two states where Claude is **blocked on you**:

| Prefix | State | Source |
| --- | --- | --- |
| `⠋` — moving braille dot (animated) | Working / generating | Claude Code (built-in) |
| `✳` | Finished — idle, waiting for your next message | Claude Code (built-in) |
| `✦` | Asking a clarifying question (`AskUserQuestion`) | **this repo** |
| `✿` | Waiting for you to approve a permission | **this repo** |

All four show alongside the **conversation name**. This repo only emits `✦` / `✿`, via an **OSC 0** title escape returned from a hook (`{"terminalSequence":"]0;…"}`). The working (moving dot) and finished (`✳`) indicators are Claude Code's built-in tab status, set through its **own** title mechanism (process-level / OSC 2) — a different path than the hook's, which is why they coexist. Those native glyphs aren't officially documented and may vary by version/terminal; they're listed here only so the full vocabulary lives in one place. The per-session color (feature 2) is independent of all of these.

---

## Why

When you run several Claude Code sessions in split terminals/tabs, they all look the same and you can't tell which one is blocked on your input. Claude's native tab title shows the conversation name + a working spinner — but the moment a session asks a question or requests permission, there was no at-a-glance cue, and some title hooks would even fall back to showing the *folder* name. This fixes both: a clear glyph when a session needs you, with its real conversation name, plus a distinct color per session.

---

## Requirements

- **Claude Code** (`claude` CLI).
- **python3** — used by the title hook (JSON parsing) and the installer.
- **zsh** — required only for the per-session color feature. The attention-glyph hooks are shell-agnostic.
- macOS or Linux. (The glyphs use OSC title escapes supported by iTerm2, Terminal.app, the VS Code integrated terminal, Warp, etc.)

---

## Install

```sh
git clone https://github.com/fguinez/claude-code-terminal-signals.git
cd claude-code-terminal-signals
./install.sh
```

Then:
- Restart Claude Code (or start a new session) so the hooks load.
- `source ~/.zshrc` (or open a new terminal) to enable per-session colors.

Options:

```sh
./install.sh --no-color     # only the attention glyphs (hooks)
./install.sh --no-hooks     # only the per-session color wrapper
./install.sh --dir PATH     # custom install dir (default: ~/.claude/terminal-signals)
```

The installer is **idempotent** and **non-destructive**: it backs up `settings.json` before editing and only touches the hook entries it owns (anything referencing `term-title.sh` / `term-perm.sh`), so it won't disturb other hooks you have (e.g. [peon-ping](https://github.com/PeonPing/peon-ping)).

### Manual install

If you'd rather wire it up yourself:

1. Copy `hooks/term-title.sh` and `hooks/term-perm.sh` somewhere (keep them **together** — `term-perm.sh` calls `term-title.sh` from its own directory). Make them executable.
2. Add these entries to `~/.claude/settings.json` (merge into existing `hooks`):

   ```json
   {
     "hooks": {
       "PreToolUse": [
         { "matcher": "AskUserQuestion",
           "hooks": [{ "type": "command", "command": "sh \"/ABS/PATH/term-title.sh\" \"✦\"" }] }
       ],
       "PermissionRequest": [
         { "hooks": [{ "type": "command", "command": "sh \"/ABS/PATH/term-perm.sh\"" }] }
       ]
     }
   }
   ```
3. For colors, source the wrapper from `~/.zshrc`:

   ```zsh
   source "/ABS/PATH/shell/claude-session-color.zsh"
   ```

---

## How it works

### Attention glyphs

Claude Code lets a hook return a `terminalSequence` that it writes to the terminal. On the two events where Claude is blocked on you:

- **`AskUserQuestion` (PreToolUse)** → `term-title.sh` emits `✦ <name>`.
- **`PermissionRequest`** → `term-perm.sh` picks the glyph (`✦` for an `AskUserQuestion`, `✿` for a real permission prompt) and hands off to `term-title.sh`.

`<name>` is resolved the same way Claude names the tab natively, in priority order:

1. A manual `/rename` (stored in `~/.claude/sessions/<pid>.json`).
2. The AI-generated conversation title (`{"type":"ai-title",...}` entries in the session transcript), located via `transcript_path` or by `session_id`.
3. The working directory's folder name (last-resort fallback).

This is the key fix over a naive title hook: questions/permissions show the **conversation name**, not the folder.

### Unique bar color per session

`shell/claude-session-color.zsh` defines a `claude()` wrapper. On an **interactive** launch it:

- reaps lock dirs under `~/.claude/session-colors/` whose owning PID is dead,
- picks a random color with no live lock (palette: `red blue green yellow purple orange pink cyan`), takes an atomic `mkdir` lock,
- launches the real binary with `claude "/color <color>"` (Claude auto-runs the slash command on startup), and releases the lock on exit.

It passes straight through (no color) when headless (`-p`/`--print`), when there's no TTY, or when you already gave your own prompt — so it never clobbers your input. If all 8 colors are taken, it repeats one at random.

> Note: `/color` is in-memory only (Claude doesn't persist it to disk), so the color is reassigned on each launch. There's no `--color` flag; the slash-command-on-startup trick is the supported path.

---

## Uninstall

```sh
./uninstall.sh            # remove hooks + color wrapper (keeps installed files)
./uninstall.sh --purge    # also delete the install dir and color lock dir
```

---

## Customizing

- **Glyphs:** edit the `✦`/`✿` characters in `term-perm.sh` (and the `"✦"` argument in your `settings.json` `PreToolUse` entry). Any single grapheme works.
- **Color palette / count:** edit the `colors=(...)` array in `claude-session-color.zsh`. Only the colors Claude's `/color` accepts are valid: `red, blue, green, yellow, purple, orange, pink, cyan, default` (`magenta` is **not** valid).
- **Title length:** the hook caps the name at 60 chars; tweak in `term-title.sh`.

---

## Compatibility notes

- The color wrapper is **zsh-only**. Bash users would need to port the `claude()` function (the lock logic is portable; the array/glob syntax is zsh-specific).
- Plays nicely alongside [peon-ping](https://github.com/PeonPing/peon-ping) (sounds + working/ready status). The installer front-loads its hook entries so the attention glyph wins over other title-writing hooks for those two events.

## License

MIT — see [LICENSE](LICENSE).
