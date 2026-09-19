#!/usr/bin/env bash
# Qwen3.8-27B NVFP4 weights + TURBOQUANT KV cache, full native 262144 context,
# on the RTX 5090 -- running on the PRISTINE nightly wheel, no patches.
#
# WHY THIS INSTEAD OF nvfp4 KV: nvfp4 KV fits 262144 but produces CORRUPTED
# output on this card, and that was proven not to be our doing -- the ch2lab
# fork's own tree scores 2/8 on the verbatim battery (fp8 scores 8/8), with
# byte-identical failures on both its pinned flashinfer 0.6.16.post3 and
# 0.6.18.post1. TurboQuant is upstream, supported, and needs no source build:
# per vLLM's TurboQuant study turboquant_k8v4 is 24.25 KiB/token => ~6.06 GiB at
# 262144 with >98-99% quality recovery, which fits the ~7.9 GiB ceiling.
#
# MEASURED at startup: vLLM selects the TURBOQUANT backend, forces the attention
# block size to 2080 tokens (page-matching against the mamba state, vs 1600 at
# fp8 and 2848 at nvfp4) and resolves the LBNHC layout this backend requires.
#
# STATUS: NOT YET VALIDATED FOR OUTPUT CORRECTNESS. Gate it on the 8/8 verbatim
# battery and a deep retrieval before trusting it -- exactly what caught nvfp4.
set -euo pipefail

VENV="$HOME/vllm-nightly-env"
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"

CUDA_HOME="$VENV/lib/python3.12/site-packages/nvidia/cu13"
export CUDA_HOME
# Keep the system paths: TurboQuant is a TRITON backend and Triton shells out to
# a C compiler for its launcher stubs. Clobbering PATH hides /usr/bin/gcc and the
# engine dies with "Failed to find C compiler". Set CC/CXX explicitly too.
export PATH="$CUDA_HOME/bin:$VENV/bin:$PATH"
export CC="${CC:-/usr/bin/gcc}"
export CXX="${CXX:-/usr/bin/g++}"
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

# Host-RAM guard for JIT compiles -- see the long note in serve-qwen38.sh.
export MAX_JOBS="${MAX_JOBS:-4}"

source "$VENV/bin/activate"

MODEL="unsloth/Qwen3.8-27B-NVFP4"
CHAT_TEMPLATE="$(ls "$HOME"/.cache/huggingface/hub/models--unsloth--Qwen3.8-27B-NVFP4/snapshots/*/chat_template.jinja 2>/dev/null | head -1 || true)"
CT_ARG=(); [ -n "$CHAT_TEMPLATE" ] && CT_ARG=(--chat-template "$CHAT_TEMPLATE")

SPEC_ARG=()
if [ "${SPEC:-1}" != "0" ]; then
  SPEC_ARG=(--speculative-config '{"method":"mtp","num_speculative_tokens":3}')
fi

# KVDTYPE lets you compare the TurboQuant variants without editing the file:
#   turboquant_k8v4    24.25 KiB/tok  >98-99% recovery   <- default, safest
#   turboquant_4bit_nc 16.38 KiB/tok  ~96%, 1-4 pt drops
#   turboquant_3bit_nc / turboquant_k3v4_nc  cheaper, 8-20 pt drops. avoid.
exec vllm serve "$MODEL" \
  --host 0.0.0.0 --port 8000 \
  --tensor-parallel-size 1 \
  --safetensors-load-strategy prefetch \
  "${SPEC_ARG[@]}" \
  --kv-cache-dtype "${KVDTYPE:-turboquant_k8v4}" \
  --gpu-memory-utilization 0.95 \
  --max-model-len "${MAXLEN:-262144}" \
  --max-num-seqs 1 \
  --max-num-batched-tokens 2048 \
  --limit-mm-per-prompt '{"image":8,"video":0}' \
  --mm-processor-kwargs '{"max_pixels": 1003520}' \
  --reasoning-parser qwen3 \
  --default-chat-template-kwargs '{"enable_thinking": true}' \
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":20,"repetition_penalty":1.0}' \
  "${CT_ARG[@]}" \
  --trust-remote-code
