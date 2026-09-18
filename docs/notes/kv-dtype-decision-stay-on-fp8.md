---
name: kv-dtype-decision-stay-on-fp8
description: DECIDED 2026-09-18 — stay on fp8/190400; do not re-litigate NVFP4 or TurboQuant KV without a new reason
metadata:
  node_type: memory
  type: feedback
  modified: 2026-09-18T23:45:00.000Z
---

The user's decision, after a full evening of measurement: **stay on
`serve-qwen38.sh` as it is** — fp8_e4m3, `--max-model-len 190400`, util 0.95,
batched-tokens 2048, MTP-3 + CUDA graphs, on the stable `~/vllm-env` (vLLM 0.22).
Validated 8/8 on the verbatim battery and correct retrieval from 177,943 tokens.

**Why:** both alternatives to a bigger window came with costs the extra context did
not justify for agentic coding that rarely exceeds 190K.

| option | window | verdict |
|---|---|---|
| **fp8 (kept)** | 190,400 | exact, MTP + CUDA graphs |
| turboquant_k8v4 | ~228,096 pinned | +20%, but lossy (~99%) AND forced `--enforce-eager` |
| nvfp4 | — | DEAD: corrupts at 31K, below fp8's window ([[qwen38-nvfp4-full-context-port]]) |

**How to apply:** do not propose a KV-dtype change again unless something material
changes (a vLLM release fixing the TurboQuant workspace bug below, a QAT KV
checkpoint, or more VRAM). The measurement is done; re-running it is waste.

**Worth keeping from the exercise:**
* `--kv-cache-memory-bytes` is MANDATORY for any large window here. Three separate
  times vLLM sized the KV pool to ALL free VRAM and then OOMed in activations
  mid-prefill (fp8 at util 0.97; nvfp4 at 262144; k8v4 at 253440 which died at
  150K with 239 MiB free). Pinning ~6.25 GiB leaves ~1.1-1.7 GiB for activations.
* **vLLM 0.22 TurboQuant bug: MTP + CUDA graphs together breaks the FIRST request** —
  `AssertionError: Workspace is locked but allocation from
  'turboquant_attn.py:879:_decode_attention' requires 0.76 MB, current size is 0.00 MB`.
  Cause: `_init_reorder_batch_threshold(1, supports_spec_as_decode=False)` means MTP
  steps are classified as prefill, so `_decode_attention` is never reached during
  warmup and the workspace locks at 0. Dropping EITHER MTP or CUDA graphs fixes it
  (all three escapes scored 8/8). Report upstream if it persists in a later release.
* k8v4 ceiling measured on vLLM 0.22 at util 0.95 / batched 2048: **261,888**
  (7.11 GiB, block size 2112 = 124 blocks) — i.e. it does reach ~native 262144,
  but only unpinned, which is the configuration that OOMs.
* k8v4 correctness as far as it was tested: battery 8/8, and PASS at 31,383 and
  95,154 — notably clearing the 31K depth where nvfp4 failed. Depths above 96K were
  never completed before the decision to stop. So k8v4 is UNPROVEN, not rejected.
