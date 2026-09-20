---
name: gpu-memory-utilization-locked
description: vLLM --gpu-memory-utilization on this box is 0.95 for the headless 5090 (qwen38); 0.97 was tried and OOMs at inference time
metadata:
  node_type: memory
  type: feedback
  modified: 2026-09-18T15:20:00.000Z
---

`--gpu-memory-utilization` in `~/qwen-vllm/` launchers is a deliberate, measured constant, not a knob to nudge. It is **0.95** in `serve-qwen38.sh` as of 2026-09-18. The other launchers still say 0.90; ask before changing them.

**Why:** The 0.90 value was set when the desktop ran on the RTX 5090 and needed ~1 GB. On 2026-09-18 the display moved to the iGPU, the 5090 went headless (18 MiB used), and the user explicitly authorised raising it to 0.97 for the Qwen3.8 setup. 0.97 was measured and **rejected**: it starts cleanly but dies on the first real request with `torch.OutOfMemoryError: Tried to allocate 394.00 MiB ... 379.69 MiB is free`. 0.95 is the value that actually serves. A clean startup is NOT validation -- always send a real request. Critically, freeing that desktop VRAM did **not** by itself enlarge the KV pool: vLLM sets `requested_memory = total_memory * util` (`vllm/v1/worker/utils.py:408`) and then `available_kv = requested - (weights + activation peak)`, all measured inside the vLLM process, so another process's usage was never deducted. Utilization is the only lossless lever on context length.

**How to apply:** Do not change utilization to chase an OOM or squeeze context — re-measure instead. Lower `--max-num-batched-tokens` first (it sets the activation peak and comes straight out of the KV pool: at 0.97, 8192 -> 6.51 GiB pool, 2048 -> 7.66 GiB, 512 -> 7.86 GiB), then set `--max-model-len` from vLLM's own reported estimate with ~3% margin. See [[qwen38-context-ceiling-measured]].
