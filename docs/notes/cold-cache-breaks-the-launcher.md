---
name: cold-cache-breaks-the-launcher
description: The chat-template probe (ls | head under set -euo pipefail) exits 2 on an empty HF cache and kills every serve script BEFORE vllm serve runs, so the model can never auto-download; fixed with || true
metadata:
  node_type: memory
  type: project
  modified: 2026-09-19T12:00:00.000Z
---

**REBUILD.md step 4 said "first start downloads the model". It could not.** Every
`serve-*.sh` probed for the model's chat template like this:

```bash
CHAT_TEMPLATE="$(ls "$HOME"/.cache/.../snapshots/*/chat_template.jinja 2>/dev/null | head -1)"
```

On an empty HF cache the glob matches nothing, **`ls` exits 2**, `pipefail`
propagates that through `head`, and `set -e` kills the script **before
`vllm serve` is ever reached** -- so the download that was supposed to happen on
first start never starts.

**Symptom:** `qwen38.service` logs exactly three lines and nothing else:

```
Started Qwen3.8-27B NVFP4 + MTP + Vision (vLLM 0.29.0, RTX 5090).
qwen38.service: Main process exited, code=exited, status=2/INVALIDARGUMENT
qwen38.service: Failed with result 'exit-code'.
```

No traceback, no vLLM output, no hint that the cause is a missing *chat template*
rather than a missing *GPU*, *venv* or *driver*. `bash -x` on the script is what
finds it.

**Fix:** `... | head -1 || true)` in all six serve scripts. The `|| true` is
load-bearing -- do not "simplify" it away.

**Why it was never seen on Ubuntu:** that box was upgraded in place and always had
a warm `~/.cache/huggingface`, so the glob always matched. The bug is invisible on
every machine except a genuinely fresh one, which is the exact machine REBUILD.md
exists to serve. First caught on the Omarchy rebuild, 2026-09-19.

**Lesson:** a rebuild guide is only tested by an actual rebuild. Same class of gap
as [[pip-cuda-is-not-self-sufficient]]: both were latent for months and both only
fire on step 1 of a clean install.
