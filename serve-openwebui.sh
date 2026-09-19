#!/usr/bin/env bash
# Open WebUI -- the phone/tablet front door to the local Qwen server.
#
# WHY THIS EXISTS: vLLM serves a raw OpenAI-compatible API, which is fine for
# OpenCode and curl but useless on a phone. This puts a chat UI in front of it so
# any device on the LAN just opens a URL in Safari ("Add to Home Screen" makes it
# behave like an app). It is a CLIENT of qwen38.service, not a replacement.
set -euo pipefail

# --- talk to the local vLLM, and ONLY that ---------------------------------
# Open WebUI defaults to hunting for Ollama on :11434 and to OpenAI's cloud API.
# Both are wrong here and the Ollama probe costs a slow timeout on every page
# load, so disable it explicitly rather than leaving it to time out.
export ENABLE_OLLAMA_API=False
export OPENAI_API_BASE_URL="http://127.0.0.1:8000/v1"
export OPENAI_API_KEY="not-needed"        # vLLM runs without auth on the LAN

# --- bind -------------------------------------------------------------------
# IPv4 ONLY, exactly as qwen38 does, and for the same reason: this box has a
# globally routable IPv6 and IPv6 has no NAT, so binding :: would put a listener
# on a public address. 0.0.0.0 keeps the only listener on an RFC1918 address
# behind NAT. See REBUILD.md "Keep --host 0.0.0.0".
export HOST=0.0.0.0
export PORT="${PORT:-3000}"

# --- auth -------------------------------------------------------------------
# WEBUI_AUTH stays ON. The first account created becomes the admin, and on a
# family LAN that is the difference between "my chats" and "everyone's chats".
# Do NOT set WEBUI_AUTH=False to skip the login screen -- it makes every visitor
# the same user and shares all conversation history between phones.
export WEBUI_AUTH=True
# Keep the SQLite DB and uploads out of the venv so a reinstall cannot eat them.
export DATA_DIR="${DATA_DIR:-$HOME/.local/share/open-webui}"
mkdir -p "$DATA_DIR"

source "$HOME/open-webui-env/bin/activate"
exec open-webui serve --host "$HOST" --port "$PORT"
