#!/usr/bin/env bash
# Claude Code statusline, styled after starship's catppuccin_frappe powerline
# preset. Segments are drawn as rounded pills, one per
# group, each group in its own hue family:
#   model     mauve    -> model display name (+ effort)
#   workspace peach    -> current directory (truncated like starship: last 3, "../")
#             yellow   -> git branch + dirty/ahead-behind indicator (git repos only)
#   tracking  blue     -> PRs this session created or acted on, as OSC 8 hyperlinks
#             sapphire -> the Linear issue this session is about, as an OSC 8 hyperlink
#   usage     greens   -> 5h window, 7d window, Fable weekly bucket (Fable models only)
#   context   maroon   -> context window consumed % + prompt-cache health
# The model/workspace/tracking groups sit on the left, usage/context on the
# right, and a surface-colored filler stretches the bar to the full width.
#
# The data is gathered once, then compose() renders it at increasing levels of
# compaction until the bar fits in $COLUMNS (see the "fit" section at the end).
set -u
# character counts below are visible widths, which needs a UTF-8 ctype
export LC_ALL=en_US.UTF-8

input="$(cat)"

# the helpers sit next to this script; caches go under the Claude config dir
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# --- catppuccin_frappe colors (R;G;B) ---
MAUVE="202;158;230"
PEACH="239;159;118"
YELLOW="229;200;144"
BLUE="140;170;238"
SAPPHIRE="133;193;220"
GREEN="166;209;137"
GREEN_DEEP="134;184;110"
GREEN_DEEPER="108;160;96"
MAROON="234;153;156"
SURFACE="65;69;89"
CRUST="35;38;52"

# group ids; groups from RIGHT_FROM on are right-aligned
G_MODEL=0 G_WORKSPACE=1 G_TRACKING=2 G_USAGE=3 G_CONTEXT=4
RIGHT_FROM=$G_USAGE

fg() { printf '\033[38;2;%sm' "$1"; }
bg() { printf '\033[48;2;%sm' "$1"; }
reset() { printf '\033[0m'; }

# --- red: model display name ---
model_name="$(printf '%s' "$input" | jq -r '.model.display_name // empty' 2>/dev/null)"
# drop any parenthetical the display name carries (e.g. "Opus 5 (1M context)")
model_name="${model_name%% (*}"
effort="$(printf '%s' "$input" | jq -r '.effort.level // empty' 2>/dev/null)"

# --- peach: directory, last N components with "../" prefix, capped at 31 chars ---
# Over the cap we drop one leading component at a time, down to the rightmost
# folder alone -- a long branch name matters more than a long path.
DIR_MAX=31
cwd="$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)"
dir_clean_parts=()
dir_display=""
if [ -n "$cwd" ]; then
  dir_display="$cwd"
  home="$HOME"
  case "$cwd" in
    "$home") dir_display="~" ;;
    "$home"/*) dir_display="~${cwd#$home}" ;;
  esac
  IFS='/' read -r -a parts <<<"$dir_display"
  for p in "${parts[@]}"; do
    [ -n "$p" ] && dir_clean_parts+=("$p")
  done
fi

# dir_label MAX_FOLDERS -> sets dir_text
dir_label() {
  local clean_parts=("${dir_clean_parts[@]+"${dir_clean_parts[@]}"}")
  local n=${#clean_parts[@]} keep tail_parts joined width
  keep=$n
  [ "$n" -eq 0 ] && clean_parts=("") && keep=1 && n=1
  [ "$keep" -gt "$1" ] && keep=$1
  while :; do
    tail_parts=("${clean_parts[@]: -keep}")
    joined="$(IFS=/; echo "${tail_parts[*]}")"
    width=${#joined}
    if [ "$keep" -lt "$n" ]; then
      # ASCII ".." rather than "…": the Nerd Font ellipsis overdraws its cell
      # and bleeds into the following slash
      dir_text="../${joined}"
      width=$((width + 3))
    else
      dir_text="$joined"
      case "$dir_display" in /*) dir_text="/$dir_text" ;; esac
      width=${#dir_text}
    fi
    [ "$width" -le "$DIR_MAX" ] && break
    [ "$keep" -le 1 ] && break
    keep=$((keep - 1))
  done
}

# --- yellow: git branch + dirty/ahead-behind indicator ---
branch="" dirty="" ahead_behind=""
if [ -n "$cwd" ] && git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)"
  if [ -z "$branch" ]; then
    branch="$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)"
  fi
  if [ -n "$branch" ]; then
    dirty=""
    if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
      dirty="*"
    fi
    ahead_behind=""
    upstream="$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
    if [ -n "$upstream" ]; then
      counts="$(git -C "$cwd" --no-optional-locks rev-list --left-right --count HEAD..."$upstream" 2>/dev/null)"
      ahead="$(echo "$counts" | awk '{print $1}')"
      behind="$(echo "$counts" | awk '{print $2}')"
      # the arrows overdraw their cell, so each gets a space before its count
      [ "${ahead:-0}" -gt 0 ] 2>/dev/null && ahead_behind="${ahead_behind}⇡ ${ahead}"
      [ "${behind:-0}" -gt 0 ] 2>/dev/null && ahead_behind="${ahead_behind:+${ahead_behind} }⇣ ${behind}"
    fi
  fi
fi

# --- blue: pull requests this session created or acted on ---
# Rendered as OSC 8 hyperlinks (cmd/ctrl-click in the terminal) so the segment
# costs a few characters instead of a full URL each.
PR_LIMIT="${CLAUDE_STATUSLINE_PR_LIMIT:-3}"
transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
repo_slug="$(printf '%s' "$input" | jq -r '.workspace.repo | if . then .owner + "/" + .name else empty end' 2>/dev/null)"

link() { printf '\033]8;;%s\a%s\033]8;;\a' "$1" "$2"; }
short_repo() { [ "${#1}" -le 16 ] && printf '%s' "$1" || printf '%s…' "${1:0:15}"; }

pr_slugs=() pr_nums=()
if [ "$PR_LIMIT" -gt 0 ] 2>/dev/null && [ -n "$transcript" ] && [ -f "$transcript" ]; then
  pr_rows="$(python3 "$SCRIPT_DIR/statusline-prs.py" "$transcript" "$session_id" "$repo_slug" 2>/dev/null | tail -n "$PR_LIMIT")"
  while IFS=$'\t' read -r slug num; do
    [ -n "$num" ] || continue
    pr_slugs+=("$slug")
    pr_nums+=("$num")
  done <<<"$pr_rows"
fi

# pr_label WITH_REPO MAX_PRS -> sets pr_text (with links) and pr_width (visible)
pr_label() {
  local with_repo="$1" max="$2" n=${#pr_nums[@]} start same_repo=1 i slug label plain=""
  pr_text=""
  start=$(( n > max ? n - max : 0 ))
  for slug in "${pr_slugs[@]}"; do
    [ "$slug" = "${pr_slugs[0]}" ] || same_repo=0
  done
  if [ "$with_repo" -eq 1 ] && [ "$same_repo" -eq 1 ]; then
    pr_text="$(short_repo "${pr_slugs[0]##*/}")"
    plain="$pr_text"
  fi
  for ((i = start; i < n; i++)); do
    label="#${pr_nums[$i]}"
    [ "$with_repo" -eq 1 ] && [ "$same_repo" -eq 0 ] && label="$(short_repo "${pr_slugs[$i]##*/}")#${pr_nums[$i]}"
    [ -n "$plain" ] && pr_text="${pr_text} " && plain="${plain} "
    pr_text="${pr_text}$(link "https://github.com/${pr_slugs[$i]}/pull/${pr_nums[$i]}" "$label")"
    plain="${plain}${label}"
  done
  pr_width=${#plain}
}

# --- sapphire: the Linear issue this session is about ---
# One issue at most: a session implements, QAs or babysits a single issue even
# when others come up along the way. statusline-issue.py scores the mentions.
# Off unless both the workspace slug and its team keys are set.
LINEAR_WORKSPACE="${CLAUDE_STATUSLINE_LINEAR_WORKSPACE:-}"
issue_key=""
if [ -n "$LINEAR_WORKSPACE" ] && [ -n "$transcript" ] && [ -f "$transcript" ]; then
  issue_key="$(python3 "$SCRIPT_DIR/statusline-issue.py" "$transcript" "$session_id" "$branch" 2>/dev/null | head -n 1)"
fi

# --- green / teal: time left in the 5h and 7d windows + usage consumed ---
# .rate_limits is absent on some plans and before the first API response, so
# the last values any session saw are cached and shown until live data arrives;
# a window is dropped once its resets_at has passed.
RL_CACHE="$CLAUDE_DIR/statusline-cache/rate-limits.json"
mkdir -p "${RL_CACHE%/*}" 2>/dev/null

# remaining time until an epoch-seconds instant, compacted: 45m / 3h / 2d5h;
# with a second arg of 1, days are rounded up instead: 1d17h -> <2d
time_left() {
  awk -v r="$1" -v n="$(date +%s)" -v coarse="${2:-0}" 'BEGIN{
    d = r - n
    if (d < 0) d = 0
    if (d < 3600) { printf "%dm", int((d + 59) / 60); exit }
    if (d < 86400) { printf "%dh", int(d / 3600 + 0.5); exit }
    days = int(d / 86400)
    h = int((d % 86400) / 3600 + 0.5)
    if (h == 24) { days++; h = 0 }
    if (h > 0 && coarse) { printf "<%dd", days + 1; exit }
    if (h > 0) printf "%dd%dh", days, h; else printf "%dd", days
  }' 2>/dev/null
}

add_window_segment() {
  local color="$1" prefix="$2" used="$3" reset="$4" fallback="$5" coarse="$6"
  [ -n "$used" ] || return 0
  local used_pct window_label
  used_pct="$(printf '%.0f' "$used" 2>/dev/null)" || return 0
  [ -n "$used_pct" ] || return 0
  window_label="$fallback"
  if [ -n "$reset" ]; then
    window_label="$(time_left "$reset" "$coarse")"
    [ -n "$window_label" ] || window_label="$fallback"
  fi
  add_seg "$color" "${prefix}${window_label} ${used_pct}%"
}

rate_limits="$(printf '%s' "$input" | jq -c '.rate_limits | select(.five_hour or .seven_day)' 2>/dev/null)"
if [ -n "$rate_limits" ]; then
  printf '%s' "$rate_limits" >"$RL_CACHE.$$" 2>/dev/null && mv -f "$RL_CACHE.$$" "$RL_CACHE" 2>/dev/null
elif [ -f "$RL_CACHE" ]; then
  rate_limits="$(cat "$RL_CACHE" 2>/dev/null)"
fi
# "|"-joined: read collapses consecutive tabs, which would shift empty fields
IFS='|' read -r five_hour_used five_hour_reset seven_day_used seven_day_reset <<<"$(
  printf '%s' "$rate_limits" | jq -r --argjson now "$(date +%s)" '
    def win(w): (w | select(. != null and (.resets_at // 0) > $now)
                   | [.used_percentage // "", .resets_at // ""]) // ["", ""];
    win(.five_hour) + win(.seven_day) | join("|")' 2>/dev/null)"

# --- mauve: Fable weekly bucket, only while a Fable model is selected ---
# The per-model weekly window never reaches the statusline payload -- it is a
# /usage-only field -- so read the copy Claude Code caches in ~/.claude.json
# (or $CLAUDE_CONFIG_DIR/.claude.json).
# The cache is refreshed as a side effect of normal use; a stale one is dropped
# rather than shown, since a frozen "100%" reads as fact.
case "${model_id:=$(printf '%s' "$input" | jq -r '.model.id // empty' 2>/dev/null)}${model_name}" in
  *[Ff]able*)
    fable="$(jq -r --argjson max_age 21600 '
      .cachedUsageUtilization
      | select((.fetchedAtMs // 0) > 0 and (now - .fetchedAtMs / 1000) < $max_age)
      | (.utilization.limits // [])
      | map(select(.scope.model.display_name == "Fable" and .percent != null))
      | first
      | select(. != null)
      | [ (.percent | round),
          (.severity // ""),
          ((.resets_at // "")
            | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")
            | if test("Z$") then fromdateiso8601 else 0 end) ]
      | @tsv' "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" 2>/dev/null)"
    ;;
esac
fable_label() {
  local coarse="$1" sd_reset drift
  fb_text=""
  [ -n "${fable:-}" ] || return 0
  IFS=$'\t' read -r fb_pct fb_sev fb_reset <<<"$fable"
  fb_text="fable ${fb_pct}%"
  # at the wall the number stops moving, so flag it the way cw flags 200k
  [ "$fb_sev" = "critical" ] && fb_text="${fb_text}!"
  # both weekly buckets normally reset together; only spell the time out
  # when this one has drifted away from the 7d segment's
  sd_reset="${seven_day_reset%%.*}"
  if [ "${fb_reset:-0}" -gt 0 ] 2>/dev/null; then
    drift=$(( fb_reset - ${sd_reset:-0} ))
    [ "$drift" -lt 0 ] && drift=$(( -drift ))
    [ "$drift" -gt 60 ] && fb_text="fable $(time_left "$fb_reset" "$coarse") ${fb_text#fable }"
  fi
}

# --- lavender: context window consumed % + prompt-cache health ---
# Measured against the auto-compact window (what actually triggers compaction),
# not the model's raw limit -- the payload's used_percentage uses the latter.
cw_text="" cw_short=""
cw_tokens="$(printf '%s' "$input" | jq -r '.context_window.total_input_tokens // empty' 2>/dev/null)"
cw_limit="${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}"
[ -z "$cw_limit" ] && cw_limit="$(jq -r '.autoCompactWindow // empty' "$CLAUDE_DIR/settings.json" 2>/dev/null)"
[ -z "$cw_limit" ] && cw_limit="$(printf '%s' "$input" | jq -r '.context_window.context_window_size // empty' 2>/dev/null)"
if [ -n "$cw_tokens" ] && [ "$cw_tokens" -gt 0 ] 2>/dev/null && [ "$cw_limit" -gt 0 ] 2>/dev/null; then
  used_rounded="$(awk -v t="$cw_tokens" -v l="$cw_limit" 'BEGIN{printf "%.0f", t*100/l}')"
  # past 200k the 1M-window sessions start paying the long-context premium
  cw_alert=""
  [ "$cw_tokens" -gt 200000 ] 2>/dev/null && cw_alert="!"

  # prompt-cache health: on a 1M-window session a miss re-sends the whole
  # context, so the number that matters is the hit ratio while warm and the
  # token bill of the next request while cold.
  # .prompt_cache is absent before the first API response and on older clients;
  # caching_observed=false means nothing has been cached yet -- stay quiet.
  cache_text=""
  pc="$(printf '%s' "$input" | jq -r '
    .prompt_cache
    | select(. != null and .caching_observed == true)
    | [ (.warm // false | tostring),
        ((.hit_ratio // 0) * 100 | round),
        (.recache_tokens_if_cold // 0),
        (.expires_at // 0),
        (.ttl // "1h") ]
    | @tsv' 2>/dev/null)"
  if [ -n "$pc" ]; then
    IFS=$'\t' read -r pc_warm pc_hit pc_recache pc_expires pc_ttl <<<"$pc"
    if [ "$pc_warm" = "true" ]; then
      cache_text=" ${pc_hit}%"
      # flag an imminent expiry: past it the next turn pays a full recache.
      # warn in the last ~third of the TTL, else a 5m cache warns permanently
      warn_s=600
      [ "$pc_ttl" = "5m" ] && warn_s=120
      if [ "${pc_expires:-0}" -gt 0 ] 2>/dev/null; then
        left_s=$(( pc_expires - $(date +%s) ))
        if [ "$left_s" -gt 0 ] && [ "$left_s" -lt "$warn_s" ]; then
          cache_text="${cache_text}·$(time_left "$pc_expires")"
        fi
      fi
    else
      cache_text=" $(awk -v t="${pc_recache:-0}" 'BEGIN{ if (t >= 1000) printf "%.0fk", t/1000; else printf "%d", t }')"
    fi
    cache_text=" (${cache_text})"
  fi

  [ -n "$used_rounded" ] && cw_text="cw ${used_rounded}%${cw_alert}${cache_text}"
  [ -n "$used_rounded" ] && cw_short="cw ${used_rounded}%${cw_alert}"
fi

# --- fit: compose at increasing compaction until the bar fits $COLUMNS ---
# Claude Code passes the terminal width as $COLUMNS; without it nothing is
# trimmed. Each level keeps the previous ones' savings and adds one more:
#   1 PR repo names dropped        7 only the newest PR
#   2 dir down to 2 folders        8 groups merged, one pill per side
#   3 dir down to 1 folder         9 dir segment dropped
#   4 day counts rounded up (<2d) 10 PR segment dropped
#   5 effort abbreviated (h, me)  11 effort dropped
#   6 branch name capped at 20    12 Linear issue dropped
#                                 13 both halves in one pill
#                                 14 cw cache health dropped
FIT_MAX_LEVEL=14
# Claude Code pads the line 2 columns on the left and clips it ~3 short of
# $COLUMNS; 4 leaves the same 2-column gap on the right
STATUSLINE_MARGIN="${CLAUDE_STATUSLINE_MARGIN:-4}"

# Ordered "group|color|text" segments plus their visible widths (text may carry
# OSC 8 escapes, so widths are tracked separately). The group is $cur_group.
segments=() seg_widths=()
cur_group=0
merged=0
add_seg() {
  segments+=("$cur_group|$1|$2")
  seg_widths+=("${3:-${#2}}")
}

short_effort() {
  case "$1" in
    low) echo l ;; medium) echo me ;; high) echo h ;; xhigh) echo x ;; max) echo ma ;;
    *) echo "$1" ;;
  esac
}

compose() {
  local lvl="$1" coarse=0 label e b
  segments=() seg_widths=()
  [ "$lvl" -ge 4 ] && coarse=1
  merged=0
  [ "$lvl" -ge 8 ] && merged=1
  [ "$lvl" -ge 13 ] && merged=2

  cur_group=$G_MODEL
  if [ -n "$model_name" ]; then
    label="$model_name"
    e="$effort"
    [ "$lvl" -ge 5 ] && e="$(short_effort "$e")"
    [ "$lvl" -ge 11 ] && e=""
    [ -n "$e" ] && label="$model_name ($e)"
    add_seg "$MAUVE" "$label"
  fi

  cur_group=$G_WORKSPACE
  if [ -n "$cwd" ] && [ "$lvl" -lt 9 ]; then
    local folders=3
    [ "$lvl" -ge 2 ] && folders=2
    [ "$lvl" -ge 3 ] && folders=1
    dir_label "$folders"
    add_seg "$PEACH" " ${dir_text}"
  fi

  if [ -n "$branch" ]; then
    b="$branch"
    # ASCII ".." for the same reason as the dir segment
    [ "$lvl" -ge 6 ] && [ "${#b}" -gt 20 ] && b="${b:0:18}.."
    label=" ${b}"
    [ -n "$dirty" ] && label="${label} ${dirty}"
    [ -n "$ahead_behind" ] && label="${label} ${ahead_behind}"
    add_seg "$YELLOW" "$label"
  fi

  cur_group=$G_TRACKING
  if [ "${#pr_nums[@]}" -gt 0 ] && [ "$lvl" -lt 10 ]; then
    local with_repo=1 max="${#pr_nums[@]}"
    [ "$lvl" -ge 1 ] && with_repo=0
    [ "$lvl" -ge 7 ] && max=1
    pr_label "$with_repo" "$max"
    add_seg "$BLUE" "$pr_text" "$pr_width"
  fi

  if [ -n "$issue_key" ] && [ "$lvl" -lt 12 ]; then
    add_seg "$SAPPHIRE" "$(link "https://linear.app/${LINEAR_WORKSPACE}/issue/${issue_key}" "$issue_key")" "${#issue_key}"
  fi

  cur_group=$G_USAGE
  add_window_segment "$GREEN" "" "$five_hour_used" "$five_hour_reset" "5h" "$coarse"
  add_window_segment "$GREEN_DEEP" "w " "$seven_day_used" "$seven_day_reset" "7d" "$coarse"

  fable_label "$coarse"
  [ -n "$fb_text" ] && add_seg "$GREEN_DEEPER" "$fb_text"

  cur_group=$G_CONTEXT
  if [ "$lvl" -ge 14 ]; then
    [ -n "$cw_short" ] && add_seg "$MAROON" "$cw_short"
  else
    [ -n "$cw_text" ] && add_seg "$MAROON" "$cw_text"
  fi
}

# pill_break PREV_GROUP GROUP -> whether a new pill starts between the two;
# merged=1 keeps only the split between the left and right halves, merged=2
# none at all
pill_break() {
  [ "$1" != "$2" ] || return 1
  [ "$merged" -eq 0 ] && return 0
  [ "$merged" -eq 2 ] && return 1
  [ "$1" -lt "$RIGHT_FROM" ] && [ "$2" -ge "$RIGHT_FROM" ]
}

# Minimum bar width: per segment " text ", one column between segments (an
# arrow inside a group, a filler gap between groups), the two outer caps, and
# a right + left cap at every pill boundary.
bar_width() {
  local w=1 x i g prev=""
  for i in "${!seg_widths[@]}"; do
    x="${seg_widths[$i]}"
    g="${segments[$i]%%|*}"
    w=$(( w + x + 3 ))
    [ -n "$prev" ] && pill_break "$prev" "$g" && w=$(( w + 2 ))
    prev="$g"
  done
  echo "$w"
}

level=0
budget=0
compose 0
if [ "${COLUMNS:-0}" -gt 0 ] 2>/dev/null; then
  budget=$(( COLUMNS - STATUSLINE_MARGIN ))
  while [ "$(bar_width)" -gt "$budget" ] && [ "$level" -lt "$FIT_MAX_LEVEL" ]; do
    level=$(( level + 1 ))
    compose "$level"
  done
fi

# --- render powerline ---
count=${#segments[@]}
if [ "$count" -eq 0 ]; then
  exit 0
fi

SEP=$'\356\202\260'
# U+E0B6 / U+E0B4, the half-circles that round each group's edges
CAP_LEFT=$'\356\202\266'
CAP_RIGHT=$'\356\202\264'

# cap GLYPH FG_COLOR BG_COLOR (empty BG = terminal background)
cap() {
  printf '%s' "$(fg "$2")"
  [ -n "$3" ] && printf '%s' "$(bg "$3")"
  printf '%s%s' "$1" "$(reset)"
}
filler() { [ "$1" -gt 0 ] && printf '%s%*s%s' "$(bg "$SURFACE")" "$1" "" "$(reset)"; }

# Columns left over go to the gap between the left and right halves; with only
# one half present, they become a filler run before or after it.
extra=0
[ "$budget" -gt 0 ] && extra=$(( budget - $(bar_width) ))
[ "$extra" -lt 0 ] && extra=0
first_group="${segments[0]%%|*}"
last_group="${segments[$((count - 1))]%%|*}"
lead=0 trail=0
if [ "$extra" -ge 2 ]; then
  [ "$first_group" -ge "$RIGHT_FROM" ] && lead=$extra
  { [ "$last_group" -lt "$RIGHT_FROM" ] || [ "$merged" -eq 2 ]; } && trail=$extra
fi

outer_bg=""
if [ "$lead" -gt 0 ]; then
  cap "$CAP_LEFT" "$SURFACE" ""
  filler $(( lead - 1 ))
  outer_bg="$SURFACE"
fi

prev_group="" prev_color=""
for i in "${!segments[@]}"; do
  group="${segments[$i]%%|*}"
  rest="${segments[$i]#*|}"
  color="${rest%%|*}"
  text="${rest#*|}"
  if [ -z "$prev_group" ]; then
    cap "$CAP_LEFT" "$color" "$outer_bg"
  elif pill_break "$prev_group" "$group"; then
    gap=1
    [ "$prev_group" -lt "$RIGHT_FROM" ] && [ "$group" -ge "$RIGHT_FROM" ] && gap=$(( 1 + extra ))
    cap "$CAP_RIGHT" "$prev_color" "$SURFACE"
    filler "$gap"
    cap "$CAP_LEFT" "$color" "$SURFACE"
  else
    printf '%s%s%s%s' "$(fg "$prev_color")" "$(bg "$color")" "$SEP" "$(reset)"
  fi
  printf '%s%s %s %s' "$(bg "$color")" "$(fg "$CRUST")" "$text" "$(reset)"
  prev_group="$group" prev_color="$color"
done

if [ "$trail" -gt 0 ]; then
  cap "$CAP_RIGHT" "$prev_color" "$SURFACE"
  filler $(( trail - 1 ))
  cap "$CAP_RIGHT" "$SURFACE" ""
else
  cap "$CAP_RIGHT" "$prev_color" ""
fi
printf '\n'
