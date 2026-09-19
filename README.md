# qwen-vllm

Local OpenAI-compatible LLM server on an **RTX 5090**: `unsloth/Qwen3.8-27B-NVFP4` on
**vLLM 0.29.0** - fp8 KV cache, 166,400-token context, prefix caching, MTP speculative
decoding, vision, tool calling - plus an **OpenCode multi-agent coding pipeline**.

| start here | |
|---|---|
| [`REBUILD.md`](REBUILD.md) | fresh-Ubuntu-to-working-server, step by step, with every trap we hit |
| [`serve-qwen38-029.sh`](serve-qwen38-029.sh) | the production launcher (what `qwen38.service` runs) |
| [`opencode-agents/`](opencode-agents/) | orchestrator + planner / coder / reviewer / refactorer template |
| [`docs/notes/`](docs/notes/) | the measurements and dead ends behind every number (start with `MEMORY.md`) |

## Layout
- `serve-openwebui.sh` - chat UI on :3000 for phones/tablets (client of qwen38, no GPU).
- `serve-*.sh` - launchers. `serve-qwen38-029.sh` = production; `serve-qwen38.sh` = previous
  vLLM 0.22 setup (190,400 ctx, but broken parallel tool calls); others are older models.
- `serve-qwen38-windows.ps1` - the **Windows** path: native `llama-server` on unsloth GGUFs
  (UD-Q5_K_M + mmproj) with a ggml-org DFlash drafter, instead of vLLM, because vLLM needs
  WSL2 and this box has no system RAM to spare. Serves OpenCode over the LAN at ~1-2 GB host
  RAM. `$env:QWEN_SPEC` picks the drafter: `dflash` (default) / `mtp` / `none`. See
  [`docs/notes/windows-native-llamacpp.md`](docs/notes/windows-native-llamacpp.md).
- `bench-drafters.py` - DFlash vs MTP vs none on this box: decode tok/s and acceptance at
  512/4K/32K depth, plus **greedy losslessness** against the no-drafter baseline. Manages its
  own server on :8001, so it does not disturb production.
- `start-model.sh` / `stop-model.sh` - desktop-button wrappers around the systemd units.
- `test-verbatim.py`, `test-longctx.py`, `test-vision.py` - correctness gates. Run them after
  ANY change to vLLM version, KV dtype, driver or flags; a clean startup proves nothing.
- `test-agentic.py` - the Windows path's two big risks: XML tool calling at depth (to 92K
  tokens) and the Playwright shape (image -> tool call -> tool result -> tool call). Needs a
  running server; start the launcher first so it tests the production config.
- `system/` - systemd units, desktop launchers, `pip freeze` of both envs. `restore.sh` installs them.
- `docs/legacy-qwen36-setup.md` - the original Qwen3.6 setup guide (historical; its
  "utilization 0.90 is fixed" rule is superseded, see `docs/notes/`).
- `*nvfp4*`, `*fork*`, `*nightly*`, `*.patch` - the abandoned NVFP4-KV port. Kept for the
  record; they reference a deleted venv and are not expected to run.
