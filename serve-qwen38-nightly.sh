#!/usr/bin/env bash
# Qwen3.8-27B NVFP4 + MTP + Vision on the RTX 5090 (SM120) -- NIGHTLY env,
# NVFP4 KV CACHE, targeting the model's native 262144 context.
#
# This is the experimental twin of serve-qwen38.sh. Differences:
#   * ~/vllm-nightly-env (vLLM 0.29.1rc1.dev371+g1cdf1689e, flashinfer 0.6.18.post1)
#     instead of ~/vllm-env (0.22.1rc1.dev23, flashinfer 0.6.12.dev20260531).
#   * --kv-cache-dtype nvfp4 instead of fp8_e4m3, which is the whole point:
#     fp8 needs 9.13 GiB to reach 262144 against a ~7.9 GiB ceiling, so full
#     context is impossible at fp8 on 32 GB. NVFP4 KV is 18.00 KiB/token =>
#     ~4.50 GiB at 262144.
#   * Requires patch-nightly-sm120-nvfp4-kv.py to have been applied to the
#     nightly env (upstream still gates nvfp4 KV to SM100 trtllm-gen). The
#     patch is idempotent; re-run it after every pip upgrade of the nightly.
set -euo pipefail
#
# ############################################################################
# ## DO NOT USE FOR REAL WORK YET -- OUTPUT IS SUBTLY WRONG (2026-09-18).   ##
# ## It starts, serves the full 262144, and answers fluently, but it        ##
# ## CORRUPTS TOKENS. Measured: verbatim copy of a passphrase from a        ##
# ## 30-token prompt failed 7 of 8 times ("COBALT-LANTERN-3095" ->          ##
# ## "COBALT-3095", "QX7-..." -> "QX9-..."). Arithmetic and short answers   ##
# ## look fine, which is exactly what makes it dangerous.                   ##
# ##                                                                        ##
# ## ROOT CAUSE: the NVFP4 KV *writer* is a CUDA kernel and it stores the V ##
# ## scale factors in the SM100 trtllm-gen 4-token SWIZZLED layout, while   ##
# ## the FlashInfer FA2/XQA reader this path uses requires them LINEAR. K   ##
# ## scales are linear either way, which is why the gist survives and only  ##
# ## some tokens garble. The ch2lab fork solves it by adding a              ##
# ## `swizzle_v_sf` flag to reshape_and_cache_nvfp4 in                      ##
# ## csrc/libtorch_stable/nvfp4_kv_cache_kernels.cu. That is a KERNEL fix:  ##
# ## it cannot be done from Python, so patch-nightly-sm120-sm120-nvfp4-kv.py##
# ## (14 Python sites) is necessary but NOT sufficient.                     ##
# ##                                                                        ##
# ## NEXT STEP: rebuild the _C_stable_libtorch CMake target with that flag  ##
# ## plumbed through. It is a discrete target, so this does not require      ##
# ## building all of vLLM. Cap the build with MAX_JOBS (31 GiB of RAM).     ##
# ##                                                                        ##
# ## Until then use serve-qwen38.sh (fp8_e4m3, 190400, validated).          ##
# ############################################################################

export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"

VENV="$HOME/vllm-nightly-env"

# CRITICAL: FlashInfer JIT-compiles the SM120 NVFP4 GEMM and needs CUDA >= 12.8 nvcc.
CUDA_HOME="$(dirname "$(dirname "$(find "$VENV" -name nvcc -path '*cu13*' -type f 2>/dev/null | head -1)")")"
export CUDA_HOME
export PATH="$CUDA_HOME/bin:$PATH"
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

# HOST-RAM GUARD -- see the long note in serve-qwen38.sh. This box has 31 GiB of
# RAM and an 8 GiB swapfile. On 2026-09-18 17:50 an UNGUARDED hand-run of this
# very environment host-OOMed the machine: a cold JIT build of
# fp4_gemm_cutlass_sm120 is 16 .cu translation units, flashinfer passes ninja no
# -j unless MAX_JOBS is set, 16 x cicc @ ~1.7 GiB = ~26 GiB, and the kernel
# OOM-killer took the engine plus the whole terminal scope. The nightly env is
# the one that has no warm JIT cache, so it is the one that needs this most.
export MAX_JOBS="${MAX_JOBS:-4}"

# NVFP4 KV MUST be head-major. "HND" is the legacy alias for the LBHNC layout
# (the resolver accepts NHD/HND as aliases for LBNHC/LBHNC). Without this the
# resolver picks LBNHC -- measured 2026-09-18, "Using LBNHC KV cache layout" --
# which is token-major and would SILENTLY CORRUPT an nvfp4 cache: each K/V side
# packs its [data | scale] regions inside that side's byte range, which is only
# coherent when a side's heads own one contiguous region per page. The patch
# asserts this at builder init, so a wrong layout fails loudly instead.
export VLLM_KV_CACHE_LAYOUT="${VLLM_KV_CACHE_LAYOUT:-HND}"

source "$VENV/bin/activate"

MODEL="unsloth/Qwen3.8-27B-NVFP4"
CHAT_TEMPLATE="$(ls "$HOME"/.cache/huggingface/hub/models--unsloth--Qwen3.8-27B-NVFP4/snapshots/*/chat_template.jinja 2>/dev/null | head -1)"
CT_ARG=(); [ -n "$CHAT_TEMPLATE" ] && CT_ARG=(--chat-template "$CHAT_TEMPLATE")

# --max-model-len 262144 -- THE MODEL'S FULL NATIVE CONTEXT, MEASURED SERVING.
#   2026-09-18, this exact config, util 0.95, --max-num-batched-tokens 2048:
#     GPU KV cache size: 300,980 tokens
#     Maximum concurrency for 262,144 tokens per request: 1.15x
#   So nvfp4 KV does not merely reach 262144, it clears it by ~15%. For contrast
#   fp8_e4m3 tops out at 190400 on this card (see serve-qwen38.sh) and vLLM puts
#   the fp8 cost of 262144 at 9.13 GiB against a ~7.9 GiB ceiling -- impossible.
#   Attention block size is forced to 2848 here (it was 1600 at fp8) so the
#   attention page is >= the mamba page, then the mamba page is padded 0.38%.
#   262144 is not a multiple of 2848 (= 92.045) and vLLM accepts it anyway,
#   allocating whole blocks; the pool figure above is the real constraint.
#   The 1.15x headroom is why this fits at all -- do not also raise
#   --max-num-seqs, which would divide it.
MAXLEN="${MAXLEN:-262144}"

# SPEC=0 disables MTP speculative decoding. Kept as a knob because spec decode
# is the prime suspect whenever output is plausible-but-wrong on this path: MTP-3
# verifies 4 tokens per step, and if verification is numerically wrong the engine
# accepts bad drafts (and premature EOS) instead of erroring. Toggle it before
# blaming the KV cache.
SPEC_ARG=()
if [ "${SPEC:-1}" != "0" ]; then
  SPEC_ARG=(--speculative-config '{"method":"mtp","num_speculative_tokens":3}')
fi

exec vllm serve "$MODEL" \
  --host 0.0.0.0 --port 8000 \
  --tensor-parallel-size 1 \
  --safetensors-load-strategy prefetch \
  --performance-mode interactivity \
  "${SPEC_ARG[@]}" \
  --kv-cache-dtype nvfp4 \
  --gpu-memory-utilization 0.95 \
  --max-model-len "$MAXLEN" \
  --max-num-seqs 1 \
  --max-num-batched-tokens 2048 \
  --limit-mm-per-prompt '{"image":8,"video":0}' \
  --mm-processor-kwargs '{"max_pixels": 1003520}' \
  --reasoning-parser qwen3 \
  --default-chat-template-kwargs '{"enable_thinking": true}' \
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":20,"repetition_penalty":1.0}' \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_xml \
  "${CT_ARG[@]}" \
  --trust-remote-code
