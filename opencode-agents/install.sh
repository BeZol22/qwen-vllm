#!/usr/bin/env bash
# Install the agent team GLOBALLY (macOS / Linux; on Windows use install.ps1).
#   ./install.sh --global                  -> ~/.config/opencode/{agents,commands}/
#   ./install.sh --global home             -> also copy providers/opencode.home.json
#                                             to ~/.config/opencode/opencode.json (never overwrites)
#   ./install.sh --global home ~/tickets   -> workspace root (default: ~/Documents/opencode)
# OpenCode is opened in a ticket workspace - one folder per ticket, outside every
# repository - so agents installed into a project would never be found, and nothing
# of the pipeline belongs in a project anyway.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-}"; PROVIDER="${2:-}"; WSROOT="${3:-$HOME/Documents/opencode}"
[ -n "$TARGET" ] || { sed -n '2,9p' "$0"; exit 1; }
if [ "$TARGET" != "--global" ]; then
  echo "Per-project install was removed: the agents now expect to be started in a ticket"
  echo "workspace, not in the repository. Use:  ./install.sh --global [provider] [workspace-root]"
  exit 1
fi

CONF="$HOME/.config/opencode"
DEST="$CONF/agents"
mkdir -p "$DEST" "$CONF/commands"
cp -v "$HERE"/agents/*.md "$DEST/"
cp -v "$HERE"/commands/*.md "$CONF/commands/"

# OpenCode globs BOTH spellings -- `{agent,agents}/**/*.md` -- and on a name clash
# the PLURAL copy wins (measured on v2.0.10). `agents/` is also what the docs say,
# so that is where we install; but an older singular copy left beside it is now
# silently dead, which reads exactly like "my edit did nothing".
SIBLING="$CONF/agent"
if [ -d "$SIBLING" ]; then
  for f in "$HERE"/agents/*.md; do
    b="$(basename "$f")"
    if [ -e "$SIBLING/$b" ]; then
      echo "SHADOWED: $SIBLING/$b is now dead -- $DEST/$b wins. Delete it."
    fi
  done
fi

if [ -n "$PROVIDER" ]; then
  SRC="$HERE/providers/opencode.$PROVIDER.json"
  [ -f "$SRC" ] || SRC="$HERE/providers/opencode.$PROVIDER.example.json"
  [ -f "$SRC" ] || { echo "No provider file for '$PROVIDER'"; exit 1; }
  if [ -e "$CONF/opencode.json" ] || [ -e "$CONF/opencode.jsonc" ]; then
    echo "KEPT existing config in $CONF (merge $SRC by hand)"
  else
    cp -v "$SRC" "$CONF/opencode.json"
  fi
fi

# The ticket workspaces. new-ticket.ps1 runs under PowerShell 7 (`pwsh`) here; without
# it, make the folder by hand: copy TICKET.template.md to <root>/<KEY>-<title>/TICKET.md
# and list the repository paths under "## Code".
mkdir -p "$WSROOT"
cp -v "$HERE/new-ticket.ps1" "$WSROOT/"
[ -e "$WSROOT/TICKET.template.md" ] || cp -v "$HERE/TICKET.template.md" "$WSROOT/"
echo "Done. Per ticket: create a folder under $WSROOT (new-ticket.ps1), start opencode IN it,"
echo "fill in TICKET.md or run /intake, then /ticket. See WORK-SETUP.md."
