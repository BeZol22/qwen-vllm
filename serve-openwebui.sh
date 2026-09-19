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

# --- web search + URL fetching ---------------------------------------------
# Both ship DISABLED in Open WebUI (ENABLE_WEB_SEARCH defaults to False), which is
# why the UI has no web button out of the box.
#
# !! THESE ENV VARS ONLY APPLY TO A FRESH INSTALL. !!
# config.py builds a DEFAULT_CONFIG dict from these variables and then calls
# Config.seed_defaults() -- "seed" meaning *insert if the key is absent*. After the
# very first boot the values live in `config` (key/value) in webui.db and the DB
# WINS FOREVER; editing the env here afterwards changes nothing, silently. That is
# how this was first "enabled" with no effect on 2026-09-19.
# To change it on an EXISTING install, use Admin Panel -> Settings -> Web Search,
# or edit the DB directly (stop the service first):
#   update config set value='true'         where key='web.search.enable';
#   update config set value='"duckduckgo"' where key='web.search.engine';
# Values are JSON-encoded, so the quotes above are part of the stored string. DuckDuckGo needs NO API key -- it
# goes through the bundled `ddgs` library -- so it is the only engine here that
# works with zero accounts and zero secrets. The alternatives (Brave, Google PSE,
# Tavily, Serper...) all want a key; SearXNG wants another service to host.
export ENABLE_WEB_SEARCH=True
export WEB_SEARCH_ENGINE=duckduckgo
# 3 is the default; 5 is still comfortable inside a 160K context window.
export WEB_SEARCH_RESULT_COUNT="${WEB_SEARCH_RESULT_COUNT:-5}"
# Let the model write its own search query from the conversation instead of
# pasting the raw user message into the engine.
export ENABLE_SEARCH_QUERY_GENERATION=True
# NOTE the retrieved pages are EMBEDDED and chunk-retrieved by default rather than
# pasted in whole. With 166K of context you can instead feed full pages by setting
# BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL=True -- better fidelity, but 5 full
# pages can be tens of thousands of tokens, so it is off until measured.
#
# PRIVACY: this is the one part of the stack that leaves the house. Inference
# stays local; a web search sends the QUERY to DuckDuckGo and then fetches the
# result pages from this box's IP. Outbound only -- it changes nothing about what
# can reach the server from outside.

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

# --- GPU ISOLATION: do NOT set USE_CUDA_DOCKER=true -------------------------
# env.py leaves DEVICE_TYPE='cpu' unless USE_CUDA_DOCKER=true, and routers/audio.py
# then sends faster-whisper to 'cuda' when it is. The RAG embedder follows the same
# switch. On this box that is a loaded gun: qwen38 runs at --gpu-memory-utilization
# 0.95 with roughly 650 MiB of VRAM to spare, so a Whisper or embedding model
# landing on the 5090 would OOM the LLM server -- and the symptom would appear in
# vLLM, not here. Whisper on CPU costs seconds for a phone dictation; leave it.
# Verify with: nvidia-smi --query-compute-apps=... should list ONLY VLLM::EngineCore.

source "$HOME/open-webui-env/bin/activate"
exec open-webui serve --host "$HOST" --port "$PORT"
