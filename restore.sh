#!/usr/bin/env bash
# Put the system-level pieces back after a fresh install. Safe to re-run.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- systemd units + desktop launchers --------------------------------------
mkdir -p ~/.config/systemd/user ~/Desktop
cp -v "$HERE"/system/systemd/*.service ~/.config/systemd/user/
cp -v "$HERE"/system/systemd/qwen38.service.bak-022 ~/.config/systemd/user/
# Desktop entries cannot expand variables, so the repo path is substituted here.
for d in "$HERE"/system/desktop/*.desktop; do
  sed "s|@REPO@|$HERE|g" "$d" > ~/Desktop/"$(basename "$d")"
  echo "wrote ~/Desktop/$(basename "$d")"
done
chmod +x ~/Desktop/*.desktop
systemctl --user daemon-reload

# --- OpenCode: provider wiring + the agent team -----------------------------
# The global config points OpenCode at the local vLLM and defaults to the
# orchestrator agent, so `opencode` works in ANY directory with no per-project
# setup. Never overwrite an existing one -- it may carry work settings.
mkdir -p ~/.config/opencode
if [ -e "$HOME/.config/opencode/opencode.json" ]; then
  echo "KEPT existing ~/.config/opencode/opencode.json"
  echo "     (merge $HERE/system/opencode-global/opencode.json by hand -- you need"
  echo "      the 'provider', 'model', 'small_model' and 'default_agent' keys)"
else
  cp -v "$HERE"/system/opencode-global/opencode.json ~/.config/opencode/opencode.json
fi
# default_agent=orchestrator above dangles unless the agents exist globally.
"$HERE"/opencode-agents/install.sh --global

# --- Claude Code project memory ---------------------------------------------
# Path is derived from where the repo lives, so it works from ~/qwen-vllm and
# from ~/Documents/qwen-vllm alike.
MEM="$HOME/.claude/projects/$(echo "$HERE" | tr '/' '-')/memory"
mkdir -p "$MEM" && cp -vn "$HERE"/docs/notes/*.md "$MEM/" 2>/dev/null || true

cat <<'MSG'

Done. Remaining steps that this script CANNOT do for you:

  1. venvs, if not built yet            -> REBUILD.md steps 3 + 8
  2. firewall (needs root)              -> REBUILD.md step 7
       sudo ufw allow from <LAN>/24 to any port 8000 proto tcp
       sudo ufw allow from <LAN>/24 to any port 3000 proto tcp
       sudo loginctl enable-linger "$USER"
  3. start the model                    -> systemctl --user enable --now qwen38
  4. start the web UI, create the admin account in a browser, THEN:
       systemctl --user stop open-webui
       ./configure-openwebui.py          # settings live in webui.db, not in git
       systemctl --user start open-webui
  5. VALIDATE -- a clean startup proves nothing:
       ./test-verbatim.py 8000   ./test-longctx.py 150000   ./test-vision.py
MSG
