#!/usr/bin/env bash
# Install the agent team into a project (default) or globally.
#   ./install.sh /path/to/project          -> <project>/.opencode/agents/
#   ./install.sh --global                  -> ~/.config/opencode/agents/
#   ./install.sh /path/to/project home     -> also copy providers/opencode.home.json
#                                             to <project>/opencode.json (never overwrites)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-}"; PROVIDER="${2:-}"
[ -n "$TARGET" ] || { sed -n '2,6p' "$0"; exit 1; }

if [ "$TARGET" = "--global" ]; then
  DEST="$HOME/.config/opencode/agents"
else
  [ -d "$TARGET" ] || { echo "No such directory: $TARGET"; exit 1; }
  DEST="$TARGET/.opencode/agents"
  GI="$TARGET/.gitignore"
  grep -qxF ".pipeline/" "$GI" 2>/dev/null || echo ".pipeline/" >> "$GI"
fi
mkdir -p "$DEST"
cp -v "$HERE"/agents/*.md "$DEST/"

# OpenCode globs BOTH spellings -- `{agent,agents}/**/*.md` -- and on a name clash
# the PLURAL copy wins (measured on v2.0.10). `agents/` is also what the docs say,
# so that is where we install; but an older singular copy left beside it is now
# silently dead, which reads exactly like "my edit did nothing".
SIBLING="$(dirname "$DEST")/agent"
if [ -d "$SIBLING" ]; then
  for f in "$HERE"/agents/*.md; do
    b="$(basename "$f")"
    if [ -e "$SIBLING/$b" ]; then
      echo "SHADOWED: $SIBLING/$b is now dead -- $DEST/$b wins. Delete it."
    fi
  done
fi

if [ -n "$PROVIDER" ] && [ "$TARGET" != "--global" ]; then
  SRC="$HERE/providers/opencode.$PROVIDER.json"
  [ -f "$SRC" ] || SRC="$HERE/providers/opencode.$PROVIDER.example.json"
  [ -f "$SRC" ] || { echo "No provider file for '$PROVIDER'"; exit 1; }
  if [ -e "$TARGET/opencode.json" ]; then
    echo "KEPT existing $TARGET/opencode.json (merge $SRC by hand)"
  else
    cp -v "$SRC" "$TARGET/opencode.json"
  fi
fi
echo "Done. Start opencode in the project and pick the 'orchestrator' agent (Tab)."
