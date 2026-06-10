#!/bin/sh
# Reads the PermissionRequest hook payload on stdin and picks the attention glyph:
#   AskUserQuestion (clarifying question) -> ✦
#   anything else (real permission prompt) -> ✿
# Then hands off to term-title.sh (resolved next to this script) to set the tab.
payload="$(cat)"
case "$payload" in
  *AskUserQuestion*) glyph="✦" ;;
  *) glyph="✿" ;;
esac

# Resolve term-title.sh relative to this script so the pair is install-location
# independent (works wherever you drop the repo).
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Forward the payload — term-title.sh needs it to resolve the conversation name,
# and stdin is already consumed here.
TERM_TITLE_PAYLOAD="$payload" exec sh "$DIR/term-title.sh" "$glyph"
