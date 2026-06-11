# === claude-code-terminal-signals: unique bar color per session ===
# Wraps `claude` so every new interactive session takes a distinct /color bar.
# Picks a random color that no live session holds (tracked via lock dirs under
# ~/.claude/session-colors); if all 8 are taken, repeats one at random. The lock
# is released on exit, and orphans (dead PIDs) are reaped on the next launch.
#
# Passes straight through to claude (no color) when:
#   - headless (-p/--print),
#   - there's no TTY (IDE, pipes, automation),
#   - you already gave your own prompt/positional arg (so it isn't clobbered).
#
# Requires zsh. Calls the real binary via `command claude` to avoid recursion.
claude() {
  local a headless=0 has_prompt=0
  for a in "$@"; do
    case $a in
      -p|--print) headless=1 ;;
      -*) ;;
      *) has_prompt=1 ;;
    esac
  done
  # On exit, reset the tab title to the shell name (e.g. "zsh") so the tab looks
  # like a freshly opened terminal again. Skipped when headless or there's no TTY.
  local interactive=0 _orig=${SHELL:t}
  [[ -n $_orig ]] || _orig=${ZSH_NAME:-zsh}
  (( ! headless )) && [[ -t 1 ]] && interactive=1

  if (( headless )) || (( has_prompt )) || [[ ! -t 1 ]]; then
    command claude "$@"
    (( interactive )) && printf '\033]0;%s\007' "$_orig"
    return
  fi

  local dir="$HOME/.claude/session-colors"
  mkdir -p "$dir"
  local colors=(red blue green yellow purple orange pink cyan)

  # Release locks held by dead processes.
  local d
  for d in "$dir"/*.lock(N/); do
    kill -0 "$(<"$d/pid" 2>/dev/null)" 2>/dev/null || rm -rf "$d"
  done

  # Free colors (no active lock).
  local free=() c
  for c in $colors; do [[ -d "$dir/$c.lock" ]] || free+=($c); done

  # Assign: a free one at random (with lock), or if all taken, repeat at random.
  local color="" owns_lock=0
  if (( ${#free} )); then
    color=${free[ RANDOM % ${#free} + 1 ]}
    if mkdir "$dir/$color.lock" 2>/dev/null; then
      print $$ > "$dir/$color.lock/pid"; owns_lock=1
    else
      color=""
    fi
  else
    color=${colors[ RANDOM % ${#colors} + 1 ]}
  fi

  # Launch (real binary via 'command'); release our lock on return.
  if [[ -n $color ]]; then
    command claude "/color $color" "$@"
  else
    command claude "$@"
  fi
  (( owns_lock )) && rm -rf "$dir/$color.lock"
  (( interactive )) && printf '\033]0;%s\007' "$_orig"
}
# === end claude-code-terminal-signals color ===
