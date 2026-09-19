#!/usr/bin/env bash
# Qwen3.8-27B NVFP4 (unsloth, compressed-tensors mixed-precision) + MTP + Vision
# on a Blackwell GPU (RTX 5090, SM120), native vLLM.
#
# Hybrid DENSE 27B: 64 layers, 48 x gated linear attention + 16 x full attention
# (every 4th). NVFP4 MLPs + FP8 attention/lm_head + BF16 vision tower  ->  ~22 GB.
set -euo pipefail

export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"

# CRITICAL: FlashInfer JIT-compiles the SM120 NVFP4 GEMM and needs CUDA >= 12.8 nvcc.
CUDA_HOME="$(dirname "$(dirname "$(find "$HOME/vllm-029-env" -name nvcc -path '*cu13*' -type f 2>/dev/null | head -1)")")"
export CUDA_HOME
export PATH="$CUDA_HOME/bin:$PATH"

# MANDATORY on a pip-only CUDA (no system toolkit, e.g. Arch/Omarchy). FlashInfer's
# generated build.ninja hardcodes  -L$cuda_home/lib64  -lcudart  -lcuda, but the pip
# wheels lay out "lib/" (not "lib64/") and ship only the SONAME libcudart.so.13 --
# no unversioned dev symlink. All 16 NVFP4 GEMM translation units then compile fine
# and the LINK fails with "/usr/bin/ld: cannot find -lcudart", which surfaces as
# "Ninja build failed" + engine-core death ~4 min into startup. A distro CUDA
# toolkit masks this by putting a linkable libcudart.so on ld's default path, which
# is why Ubuntu never hit it. -lcuda resolves from the driver (/usr/lib/libcuda.so)
# and needs nothing. These two symlinks live in site-packages, so pip reinstalling
# any nvidia-* wheel silently removes them -- recreate here, idempotently, rather
# than as a one-off manual step.
[ -e "$CUDA_HOME/lib64" ] || ln -sfn lib "$CUDA_HOME/lib64"
[ -e "$CUDA_HOME/lib/libcudart.so" ] || ln -sf libcudart.so.13 "$CUDA_HOME/lib/libcudart.so"
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

# ===== vLLM 0.29.0 variant of serve-qwen38.sh (validated 2026-09-19) =====
# REQUIRED on 0.29 + SM120: 0.29 enables the TRT-LLM XQA decode kernel on SM12x,
# which reads the KV cache in HND order, but the default layout stays NHD. Without
# this the model answers fluently WITHOUT SEEING THE PROMPT ("Hello! How can I help
# you today?" / "I I I I..."). Alternative fix: --attention-config.use_trtllm_attention=0.
export VLLM_KV_CACHE_LAYOUT=HND
# Unbounded FlashInfer JIT host-OOMs this 29 GB box.
export MAX_JOBS="${MAX_JOBS:-4}"
# max-model-len 166400 (104 x 1600): MEASURED on 0.29.0 -- pool 6.46 GiB, ceiling
# 172800 (0.22 gives 7.05 GiB / 196800). The ~24K loss pays for prefix caching
# (mamba_cache_mode=align): a repeated 159K-token prompt returns in 2 s vs ~60 s cold.
# Gate passed: verbatim 8/8, retrieval PASS at 31K/95K/149K/159K.
# Fresh installs need the CUDA toolchain aligned to 13.4.92 first (see notes).

# HOST-RAM GUARD for the FlashInfer JIT compile. Not a GPU setting -- this box has
# only 31 GiB of system RAM (30.3 GiB managed) and an 8 GiB swapfile.
# On 2026-09-18 17:50 a cold JIT build of fp4_gemm_cutlass_sm120 hard-crashed the
# machine: that op is 16 separate .cu translation units (half/bf16 x CUTLASS tile
# shapes), flashinfer's _get_num_workers() (jit/cpp_ext.py:344) returns None unless
# MAX_JOBS is set, so ninja got no -j and fanned out to all 16 threads of the
# 9800X3D. Each cicc peaked at ~1.6-1.8 GiB => ~26 GiB of anon memory, swap hit
# 76 kB free, and the kernel OOM-killer took VLLM::EngineCore. systemd then
# SIGKILLed the whole terminal scope (27.1 G peak), killing the editor session in
# it too. The GPU was never involved -- do NOT reach for utilization here.
# 4 workers x ~1.8 GiB ~= 7 GiB, which coexists with vLLM's own 10.4 GiB peak.
# Costs one-time startup latency on a cold cache only; the cache is per
# flashinfer-version + arch (~/.cache/flashinfer/<ver>/120f), so a flashinfer
# upgrade re-triggers it. FLASHINFER_NVCC_THREADS already defaults to 1, so
# nvcc does not multiply this further.
export MAX_JOBS="${MAX_JOBS:-4}"

source "$HOME/vllm-029-env/bin/activate"

MODEL="unsloth/Qwen3.8-27B-NVFP4"
# Use the model's own chat template if it ships one separately.
# The "|| true" is LOAD-BEARING on a fresh install: with an empty HF cache this
# glob matches nothing, ls exits 2, pipefail propagates it and set -e kills the
# script BEFORE vllm serve runs -- so the model can never auto-download and the
# unit just logs "status=2/INVALIDARGUMENT" with no output. Cost an Omarchy
# rebuild on 2026-09-19; invisible on any box whose cache is already warm.
CHAT_TEMPLATE="$(ls "$HOME"/.cache/huggingface/hub/models--unsloth--Qwen3.8-27B-NVFP4/snapshots/*/chat_template.jinja 2>/dev/null | head -1 || true)"
CT_ARG=(); [ -n "$CHAT_TEMPLATE" ] && CT_ARG=(--chat-template "$CHAT_TEMPLATE")

# NOTE vs. the 3.6 scripts:
#   * NO --quantization flag: this checkpoint is compressed-tensors "mixed-precision"
#     (nvfp4-pack-quantized MLPs + float-quantized attn), auto-detected. Forcing
#     modelopt here would fail.
#   * NO --enable-prefix-caching: left to vLLM's default so it can decide what the
#     hybrid linear-attention state supports instead of hard-failing on the flag.
#   * --gpu-memory-utilization 0.95. RAISED from 0.90 on 2026-09-18, after the
#     desktop moved to the iGPU and the 5090 became headless (nvidia-smi: 18 MiB
#     used). 0.90 existed only to leave the desktop its ~1 GB; that reason is gone.
#     0.97 WAS TRIED AND FAILED. It starts cleanly (7.66 GiB pool, ceiling 216000,
#     CUDA graphs captured) and then dies on the FIRST real request with
#     "torch.OutOfMemoryError: Tried to allocate 394.00 MiB ... 379.69 MiB is free".
#     Startup profiling does not cover everything inference later allocates, so a
#     successful start is NOT validation -- always send a real request.
#     0.95 IS STILL TIGHT, measured not estimated: in service at 178K context
#     nvidia-smi reads 31998/32607 MiB, i.e. ~114 MiB actually free. vLLM's own
#     budget (0.95 * 31.84 = 30.25 GiB) undercounts real usage by ~1 GiB of CUDA
#     context + allocator reserve, which is exactly why 0.97 died. Validated at
#     this setting: 177,943-token retrieval answered correctly (63 s prefill),
#     single-image and 8-image 1024x768 vision requests both pass, engine stable.
#     If anything ever OOMs here, step to 0.94 and re-measure -- do not go up.
#     NOTE the old "free VRAM grows the KV pool" intuition is WRONG: vLLM computes
#     requested_memory = total_memory * util (worker/utils.py:408) and then
#     available_kv = requested - (weights + activation peak), all measured INSIDE
#     the vLLM process. Another process's 1 GB was never deducted from the pool,
#     so freeing it added nothing until util itself went up. Util is the only
#     lossless lever. CUDA-graph memory is profiled inside this budget since
#     v0.21.0 (vLLM logs 0.97 as "equivalent to 0.9672" without that profiling),
#     so 0.97 is not as tight as it looks. Above ~0.97 you are eating the slack
#     that absorbs profiling variance.
#   * --max-num-seqs 1: single-user agentic coding from one client, which is a
#     strictly sequential loop, so concurrency never exceeds 1. Each extra slot
#     would reserve ~152 MiB of per-sequence linear-attention recurrent state
#     (48 layers x 48 v-heads x 128 x 128 fp32 + conv state) that is allocated
#     whether used or not. Raise to 2+ only if you run parallel agents.
#   * --max-num-batched-tokens 2048 (was 8192): this is the chunked-prefill chunk
#     size, and it sets the profiled activation peak, which comes straight out of
#     the KV pool. MEASURED at util 0.97, fp8:
#         8192 -> 6.51 GiB pool, ceiling 180800
#         2048 -> 7.66 GiB pool, ceiling 216000   <-- knee of the curve
#          512 -> 7.86 GiB pool, ceiling 222400
#     So 8192->2048 buys +1.15 GiB / +35K tokens for free; 2048->512 buys only
#     +0.20 GiB for 4x more prefill chunks. 2048 is the knee of the curve.
#     Cost is prefill latency only, never quality.
#   * --max-model-len 190400 (186K): MEASURED 2026-09-18, not guessed. At util
#     0.95 with --max-num-batched-tokens 2048 this box yields 7.05 GiB of KV
#     cache and vLLM reports an estimated max length of 196800. 190400 is 119
#     blocks, leaving ~3% margin for profiling variance.
#     (Was 110592 at util 0.90 / batched-tokens 8192. This is +72% context.)
#     Block size here is 1600 tokens, NOT 16: vLLM logs "Setting attention block
#     size to 1600 tokens to ensure that attention page size is >= mamba page
#     size" for this hybrid, then pads the mamba page by 0.25% to match. That
#     page quantisation is why real cost is ~36.5 KiB/token rather than the
#     32.00 KiB/token the geometry implies (16 full-attn layers x 4 kv heads x
#     2 x head_dim 256 x 1 byte). Keep max-model-len a multiple of 1600.
#     The full native 262144 does NOT fit at fp8 and never will on 32 GB: vLLM
#     puts its need at 9.13 GiB against a hard ceiling of 7.86 GiB (util 0.97,
#     batched-tokens 512). Reaching 262144 requires a lossy KV dtype -- see the
#     kv-cache-dtype note below.
#   * KV cache scales are baked into the checkpoint (kv_cache_scheme fp8) -> fp8_e4m3.
#     fp8_e4m3 is the quality-neutral choice and stays. Options for more context,
#     all lossy, per vLLM's own TurboQuant study (vllm.ai/blog/2026-05-11-turboquant)
#     and slot sizes computed from TurboQuantConfig at head_dim 256:
#       turboquant_k8v4    24.25 KiB/tok  262144 = 6.06 GiB  >98-99% recovery
#       turboquant_4bit_nc 16.38 KiB/tok  262144 = 4.09 GiB  ~96%, 1-4 pt drops
#       turboquant_k3v4_nc 14.38 KiB/tok  262144 = 3.59 GiB  8-20 pt drops. avoid.
#     Note vLLM's automatic boundary protection (first/last 2 attention layers kept
#     unquantized) is DISABLED for this model: get_boundary_skip_layers() returns []
#     when model_config.is_hybrid. To protect layers manually use
#     --kv-cache-dtype-skip-layers with full-attention indices 3,7,11,...,63, but
#     skipped layers fall back to "auto" = bf16 = 4 KiB/token/layer, i.e. ~1 GiB per
#     protected layer at 262144. Rarely worth it.
#     --kv-cache-dtype nvfp4 exists and would be the best of both (18.00 KiB/tok,
#     262144 = 4.50 GiB, fp8 block scales per 16 elements) but is UNUSABLE here:
#     FlashInfer is the only backend that lists it and it needs the trtllm-gen
#     kernels, which supports_trtllm_attention() gates on
#     is_device_capability_family(100). This card is SM 12.0 -> False.
#   * THINKING MODE IS ON (enable_thinking: true). The 3.6 scripts disable it.
#     The template puts <think> in the *prompt*, so only </think> comes back in the
#     output; the qwen3 reasoning parser knows this Qwen3.5 convention and splits
#     it into `reasoning_content` vs `content` for you.
#     Per-request override:  chat_template_kwargs: {"enable_thinking": false}
#     Thinking depth:        chat_template_kwargs: {"reasoning_effort": "low"}
#                            (xhigh = template default, then medium, low)
#   * Qwen's recommended thinking-mode sampling defaults are set server-side via
#     --override-generation-config. presence_penalty=0.0 is not settable there,
#     but 0.0 is already vLLM's default. min_p is likewise omitted: vLLM warns
#     "min_p and logit_bias parameters won't work with speculative decoding" and
#     the recommended value (0.0) is a no-op anyway.
#     NOTE these are DEFAULTS ONLY: a client that sends its own temperature/top_p
#     in the request overrides them.
exec vllm serve "$MODEL" \
  --host 0.0.0.0 --port 8000 \
  --tensor-parallel-size 1 \
  --safetensors-load-strategy prefetch \
  --performance-mode interactivity \
  --speculative-config '{"method":"mtp","num_speculative_tokens":3}' \
  --kv-cache-dtype fp8_e4m3 \
  --gpu-memory-utilization 0.95 \
  --max-model-len 166400 \
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
