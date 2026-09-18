#!/usr/bin/env bash
# Put the system-level pieces back after a fresh install. Safe to re-run.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p ~/.config/systemd/user ~/Desktop
cp -v "$HERE"/system/systemd/*.service ~/.config/systemd/user/
cp -v "$HERE"/system/systemd/qwen38.service.bak-022 ~/.config/systemd/user/
cp -v "$HERE"/system/desktop/*.desktop ~/Desktop/ && chmod +x ~/Desktop/*.desktop
systemctl --user daemon-reload
# Claude Code project memory (only meaningful if the repo lives at ~/qwen-vllm)
MEM="$HOME/.claude/projects/-home-${USER}-qwen-vllm/memory"
mkdir -p "$MEM" && cp -vn "$HERE"/docs/notes/*.md "$MEM/"
echo "Done. Next: REBUILD.md step 3 (venv) if not done, then: systemctl --user start qwen38"
