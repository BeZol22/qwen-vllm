---
name: vllm-029-breaks-this-model
description: vLLM 0.29 on the RTX 5090 REQUIRES VLLM_KV_CACHE_LAYOUT=HND or the model answers without seeing the prompt; with it, 0.29.0 is fully validated (166400 ctx + prefix caching)
metadata:
  node_type: memory
  type: project
  modified: 2026-09-19T01:00:00.000Z
---

**vLLM 0.29.0 WORKS with `unsloth/Qwen3.8-27B-NVFP4` -- but only with
`export VLLM_KV_CACHE_LAYOUT=HND`** (or `--attention-config.use_trtllm_attention=0`).
An earlier version of this note wrongly declared 0.29.0 broken; the user insisted it
should work and was right.

**Root cause:** 0.29 newly enables the TRT-LLM XQA decode kernel on SM12x
(`supports_trtllm_attention(is_prefill=False)` -> True), which reads KV in HND
order, while the default layout stays NHD. Decode then reads scrambled KV. Symptom
is NOT a crash: fluent output that ignores the prompt (`"Hello! How can I help you
today?"` with MTP, `"I'm I I I I..."` without, or empty content). Reproduces on
fp8, so it is not a KV-dtype issue. Both fixes score 8/8. The nightly run that
passed earlier had HND exported by accident of script lineage -- that diff was the clue.

**Validated 2026-09-19 (`~/vllm-029-env`, HND, fp8, util 0.95, batched 2048, MTP-3
+ CUDA graphs):** pool 6.46 GiB, ceiling 172800, served at 166400 (104 x 1600);
verbatim 8/8; retrieval PASS at 31,383 / 95,154 / 148,949 / 159,302; **prefix
caching works -- repeating the 159K prompt took 2 s vs ~60 s cold.**
Launcher: `~/qwen-vllm/serve-qwen38-029.sh` (NOT wired into systemd; `qwen38`
still runs 0.22 via `serve-qwen38.sh` until the user chooses to switch).

**The trade vs 0.22:** 166,400 + prefix caching vs 190,400 without. The ~24K
regression is REAL on stable (same as the nightly) and comes from
`mamba_cache_mode='align'`. Untested: `--no-enable-prefix-caching` on 0.29 might
recover the window.

**TurboQuant k8v4 on 0.29.0 -- tested 2026-09-19, NO improvement over 0.22:**
* It rejects `VLLM_KV_CACHE_LAYOUT=HND` (`valid layouts: ['LBNHC']`); use
  `--attention-config.use_trtllm_attention=0` and leave the layout unset.
* **MTP + CUDA graphs is STILL broken, and now SILENTLY**: 0.22 crashed with the
  workspace assertion; 0.29.0 serves and then corrupts decode -- first token right
  (`'MAR'`), then `MARMARMAR...` / `I I I I` / `Hello! How can I help you today?`.
  Battery: MTP+graphs 0/8; no-MTP+graphs 8/8; no-MTP+eager 8/8; MTP+eager 8/8.
  The earlier claim here that 0.29 "fixes" the bug was WRONG.
* Measured capacity (util 0.95, batched 2048): 6.83 GiB available, ceiling 242880,
  block 2112 -- LOWER than 0.22's 261888. An unpinned-minus-0.6-GiB pool at 217536
  still OOMed in activations at ~190K (`Tried to allocate 340 MiB`), so pin harder.
* So k8v4 needs eager-or-no-MTP on BOTH versions; the user already declined that
  trade ([[kv-dtype-decision-stay-on-fp8]]). Nothing new to offer until upstream
  fixes TurboQuant + spec decode under CUDA graphs.

**Lesson:** before declaring a version broken, diff against any run on the same
line that worked. And keep gating on `test-verbatim.py` -- a smoke test passes the
NHD bug.
