---
name: open-webui-phone-frontend
description: Open WebUI on :3000 is the phone/tablet front door to qwen38; runs in its own venv, 2.3 GiB RSS and zero VRAM, IPv4-only bind, auth ON so phones do not share one chat history
metadata:
  node_type: memory
  type: project
  modified: 2026-09-19T13:00:00.000Z
---

**Installed 2026-09-19** (Open WebUI 0.11.3, `~/open-webui-env`, ~7.6 GB) because
vLLM's raw OpenAI API is unusable on a phone. Any LAN device opens
`http://omarchy.local:3000` in Safari -- iOS resolves `.local` via Bonjour with no
setup -- and *Share -> Add to Home Screen* makes it behave like an app. No App
Store app and no per-phone endpoint configuration.

Runs as `open-webui.service` (user unit, enabled, `After=qwen38.service` but only
`Wants=` it, so the UI survives a backend restart). `restore.sh` picks it up
automatically on a rebuild since it copies `system/systemd/*.service`.

**Measured: 2.30 GiB RSS and ZERO VRAM.** `nvidia-smi` shows only
`VLLM::EngineCore`, so the UI never competes with the model for the 5090 -- which
matters, because [[gpu-memory-utilization-locked]] leaves only ~650 MiB of slack.

**Deliberate settings (see `serve-openwebui.sh` for the full reasoning):**
* `WEBUI_AUTH=True` -- the tempting `False` makes EVERY visitor the same user, so
  all phones would share one conversation history. First account = admin.
* `ENABLE_OLLAMA_API=False` -- otherwise it probes :11434 and every page load
  pays the timeout.
* `HOST=0.0.0.0` -- IPv4 only, exactly as qwen38, so no listener lands on this
  box's globally routable IPv6 ([[lan-serving-and-concurrency]]).
* `DATA_DIR=~/.local/share/open-webui` -- SQLite DB + uploads OUTSIDE the venv, so
  a reinstall cannot eat them. **This is the chat history and it is not in git --
  back it up.**

ufw needs its own rule for the new port:
`sudo ufw allow from 192.168.178.0/24 to any port 3000 proto tcp`.

**Privacy:** inference is 100% local, but Open WebUI makes OUTBOUND calls to
huggingface.co on first run for its RAG embedding model (`all-MiniLM-L6-v2`).
Outbound only; nothing becomes reachable from the internet.
