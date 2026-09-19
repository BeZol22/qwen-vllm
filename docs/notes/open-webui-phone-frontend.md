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

**Web search: ON (DuckDuckGo), and the env var is NOT how you change it.**
`ENABLE_WEB_SEARCH` defaults to False, so there is no web button out of the box.
The trap: `config.py` builds `DEFAULT_CONFIG` from the env and calls
`Config.seed_defaults()` -- *insert if absent*. After the first boot the values
live in the `config` key/value table in `webui.db` and **the DB wins forever**;
changing the env afterwards does nothing, silently, with no warning in the log.
Setting it in `serve-openwebui.sh` appeared to work and did not.

On an EXISTING install use Admin Panel -> Settings -> Web Search, or edit the DB
with the service stopped (values are JSON-encoded):

```sql
update config set value='true'          where key='web.search.enable';
update config set value='"duckduckgo"'  where key='web.search.engine';
update config set value='5'             where key='web.search.result_count';
```

DuckDuckGo is the only engine needing **no API key** (bundled `ddgs`); Brave,
Google PSE, Tavily, Serper etc. all want one, SearXNG wants another service.
URL fetching (`#https://...` in a message) uses `web.loader.engine`, empty =
the built-in fetcher, which needs nothing.

Retrieved pages are embedded and chunk-retrieved by default. With 166K of
context, `web.search.bypass_embedding_and_retrieval=true` would feed whole pages
instead -- better fidelity, but 5 full pages is easily tens of thousands of
tokens. Left off until measured.

**`ui.enable_signup` is false** after the first admin is created, so other family
phones CANNOT self-register until an admin flips it (Admin Panel -> Settings ->
General) or creates the users by hand. `ui.default_user_role` is `pending`, so
even with signup on, the admin must approve each new account -- which is the
right shape for a family LAN, but it does mean a new phone sees a "waiting for
approval" screen rather than a chat.

ufw needs its own rule for the new port:
`sudo ufw allow from 192.168.178.0/24 to any port 3000 proto tcp`.

**Privacy:** inference is 100% local, but Open WebUI makes OUTBOUND calls to
huggingface.co on first run for its RAG embedding model (`all-MiniLM-L6-v2`).
Outbound only; nothing becomes reachable from the internet.

## Settings changed from the defaults (2026-09-19)

All of these live in `webui.db`, NOT in the launcher (see the seeding trap above),
so they survive restarts but **are lost if the DB is deleted** -- another reason
`DATA_DIR` is worth backing up. Re-apply with `update config set value=... where
key=...`, values JSON-encoded, service stopped.

| key | value | why |
|---|---|---|
| `ui.enable_signup` | `true` | other phones can register; off again once an admin exists |
| `ui.default_user_role` | `pending` | admin approves each new account (left at default) |
| `ui.enable_community_sharing` | **`false`** | default ON uploads a whole chat to openwebui.com on one mis-tap |
| `task.tags.enable` | **`false`** | each message fired 3 background model calls; dropped 2 |
| `task.follow_up.enable` | **`false`** | as above; auto-titles kept, they earn their cost |
| `chat.context_compaction.enable` | `true` | was off, so a long chat hit the 166K wall and errored |
| `chat.context_compaction.token_threshold` | `120000` | default 80000 compacts needlessly early for a 166K window |
| `audio.stt.whisper_model` | `small` | `base` is weak outside English; `small` is ~3x CPU for a large accuracy gain |
| `web.search.enable` / `.engine` | `true` / `duckduckgo` | see above |

**Voice input already worked before any of this:** `audio.stt.engine=''` routes to
local faster-whisper, and TTS falls back to the browser's own voices, so an iPhone
dictates and speaks without the audio leaving the box.

**NEVER set `USE_CUDA_DOCKER=true`.** `env.py` keeps `DEVICE_TYPE='cpu'` unless it
is set; with it, `routers/audio.py` puts faster-whisper on `cuda` and the RAG
embedder follows. qwen38 runs at utilization 0.95 with ~650 MiB spare
([[gpu-memory-utilization-locked]]), so either model landing on the 5090 OOMs the
LLM server -- and the error surfaces in vLLM, not here, which makes it a horrible
thing to debug. Confirm isolation with
`nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader`:
it must list ONLY `VLLM::EngineCore`.

## Only the admin could see the model (fixed 2026-09-19)

A newly registered family member logged in to an **empty model picker** and could
not chat at all. Not a connection problem -- `utils/models.py:get_filtered_models`
drops any model lacking a row in the `model` table, for non-admins, by design:

```python
elif user.role == "admin":
    # No DB entry means no access control configured yet;
    # only admins can see unconfigured models.
    filtered_models.append(model)
```

Models served from a connection have **no such row** until an admin opens
Admin Panel -> Settings -> Models and sets that model's access, so the default
state of a fresh install is admin-only.

Fixed with `BYPASS_MODEL_ACCESS_CONTROL=True` in `serve-openwebui.sh` rather than
per-model access grants in the UI, because it is a plain env var (`env.py`, not a
PersistentConfig) -- declarative, in git, applies to a fresh rebuild, and immune to
the seed-once DB trap that made the web-search setting a no-op. Safe here: one
model, one household, everyone reaching :3000 is already inside the ufw LAN scope
with an approved account. Use per-model grants instead if this box ever serves a
model that should not be universally readable.

Verified by calling `get_filtered_models` with a `role="user"` user and a model
carrying no DB row: `VISIBLE`.

## The JWT key lives in the CWD

`open_webui/__init__.py` does `KEY_FILE = Path.cwd() / ".webui_secret_key"` and
auto-generates the JWT signing key there on first start. Started from a different
directory it mints a DIFFERENT key, invalidating every session token and logging
every phone out with no error in any log. The unit now pins `WorkingDirectory=%h`
and the script `cd "$HOME"` so a manual run cannot drift.

**`~/.webui_secret_key` is a backup item**, alongside `DATA_DIR`: lose it and
everyone is logged out.

## "nem tudok keresgélni" -- web search on by default (2026-09-19)

Enabling `web.search.enable` is only half of it. The model still answered *"sajnos
közvetlenül az interneten nem tudok keresgélni"* because web search is gated on a
**per-request** `features.web_search` flag that the frontend only sets when the
user switches the toggle on for that message. Everything else was already open:

| gate | source | state |
|---|---|---|
| `web.search.enable` | DB config | true |
| `features.web_search` permission | `user.permissions` | true for normal users |
| `is_builtin_tool_enabled('web_search')` | model row `meta.builtinTools` | **defaults True** with no row |
| `get_model_capability('web_search')` | model row `meta.capabilities` | **defaults True** with no row |
| `features.get('web_search')` | the per-message toggle | **was the only blocker** |

Fixed by persisting the setting the toggle writes, `webSearch: "always"`, in
`ui.default_interface_settings` (so new accounts inherit it) **and** in each
existing user's `settings.ui`. Both are DB state, so both are lost with `DATA_DIR`.

**"always" does NOT mean a search on every message.** `middleware.py` forces the
RAG search path only when `params.function_calling == 'legacy'`:

```python
# Skip forced RAG web search when native FC is enabled - model can use web_search tool
if metadata.get("params", {}).get("function_calling") == "legacy":
```

`function_calling` defaults to `null`, which is not `'legacy'`, so the native path
runs instead: `search_web` and `fetch_url` are handed to the model as **tools** and
it calls them when it judges they are needed. That is why this is cheap enough to
leave on -- a "hello" costs nothing. It works here because qwen38 serves with
`--enable-auto-tool-choice --tool-call-parser qwen3_xml` and parallel tool calls
are known good on 0.29 ([[production-is-vllm-029-opencode-pipeline]]).

Phones must **reload the page** to pick up changed settings.

