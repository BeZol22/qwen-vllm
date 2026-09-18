---
name: qwen38-context-ceiling-measured
description: Measured KV-cache ceiling for Qwen3.8-27B-NVFP4 on the RTX 5090 — 190400 tokens at fp8/util 0.95, and why the native 262144 cannot fit
metadata:
  node_type: memory
  type: project
  modified: 2026-09-18T15:20:00.000Z
---

Measured 2026-09-18 by probing `vllm serve` with an impossible `--max-model-len` and reading its own reported estimate. At `--gpu-memory-utilization 0.97` (which starts but OOMs in service -- see [[gpu-memory-utilization-locked]]), `--kv-cache-dtype fp8_e4m3`, `--max-num-seqs 1`, MTP-3:

| --max-num-batched-tokens | KV pool | estimated max length |
|---|---|---|
| 8192 | 6.51 GiB | 180800 |
| 2048 | 7.66 GiB | 216000 |
| 512  | 7.86 GiB | 222400 |

At the **0.95** actually in use, with batched-tokens 2048: pool 7.05 GiB, estimated ceiling 196800. `serve-qwen38.sh` runs `--max-model-len 190400` (119 blocks, ~3% margin), up from 110592 -- a 72% increase.

Verified serving: a 177,955-token prompt prefilled in 63 s and the engine stayed alive. But VRAM at that depth was 31,998 / 32,607 MiB, i.e. **only 114 MiB free**. Text-only works; this has not been proven safe with images in the prompt, and the model is vision-capable with `--limit-mm-per-prompt image:8`.

Two facts that break naive arithmetic: vLLM forces the **attention block size to 1600 tokens** on this hybrid so attention pages match the linear-attention (mamba) page size, so real cost is ~36.5 KiB/token rather than the 32.00 KiB/token the geometry implies; and `max-model-len` should stay a multiple of 1600.

**The native 262144 cannot fit at fp8 on 32 GB** — vLLM puts its need at 9.13 GiB against a hard ceiling of 7.86 GiB. Reaching it requires a lossy KV dtype (`turboquant_k8v4` or `turboquant_4bit_nc`). `--kv-cache-dtype nvfp4` would be ideal (18.00 KiB/token, 4.50 GiB at 262144) but is gated on `is_device_capability_family(100)` via trtllm-gen; this card is SM 12.0. See [[gpu-memory-utilization-locked]].

## Nightly 0.29.1 is a REGRESSION for context (measured 2026-09-18)

Same settings both sides (util 0.95, batched-tokens 2048, fp8_e4m3, MTP-3, max-num-seqs 1):

| | vLLM 0.22.1 (`~/vllm-env`, daily driver) | nightly 0.29.1rc1.dev371 (`~/vllm-nightly-env`) |
|---|---|---|
| KV pool | 7.05 GiB | **6.50 GiB** |
| estimated ceiling | 196800 | **174400** |
| 262144 would need | 9.13 GiB | **9.29 GiB** |
| attention block size | 1600 | 1600 |

Upgrading costs ~22,400 tokens of window. Per-token cost rose because the nightly
ENABLES prefix caching for this hybrid (`mamba_cache_mode='align'`, logged at
startup) where 0.22 reported `enable_prefix_caching=False` -- so linear-attention
state is now cached per block instead of being a flat per-sequence cost.

So the nightly trade is: **prefix caching across requests, paid for with 22K tokens
of context.** Possibly worth it for a sequential agentic loop that re-sends a
growing prefix; it is NOT a free upgrade, and it is a seven-version jump.

Driver note: all the nvfp4 corruption experiments in [[qwen38-nvfp4-full-context-port]]
ran on driver **595.71.05**. The box is now on **610.57.04** (installed by the DKMS
rebuild that caused [[secureboot-mok-blocks-nvidia-dkms]]), which those notes said
was the needed upgrade -- so the "dead end" verdict has an untested confound again.

Untested diagnostic knobs, all verified to exist in the nightly: `nvfp4_4over6`
(second nvfp4 variant, never tried), `--enforce-eager`, `--attention-config.
disable_flashinfer_q_quantization`, `--kv-cache-dtype-skip-layers`, `--mamba-block-size`.
Leading untested hypothesis: FlashInfer advertises
`get_supported_kernel_block_sizes() == [16, 32, 64]`, but `platforms/interface.py:916`
raises `cache_config.block_size` to meet the mamba page size with no reference to that
list -- 1600 at fp8, 2848 under nvfp4. fp8 survives (per-tensor scales); nvfp4 carries
per-16-element block scale factors whose layout is tied to page geometry.
