#!/usr/bin/env bash
# Serve Qwen3.8 with nvfp4 KV from the ch2lab FORK's own tree (built in place by
# build-fork-sm120.sh), using the nightly env only for dependencies.
#
# This is a DISCRIMINATING EXPERIMENT, not a daily driver: our port of the fork
# onto the nightly scores 3/8 on the verbatim battery where fp8 scores 8/8. If
# the fork's own tree scores 8/8, the fault is in our port. If it also fails,
# nvfp4 full context does not work on this GPU/FlashInfer combination.
#
# Nothing is installed: `import vllm` resolves to the fork via PYTHONPATH, while
# torch/flashinfer/etc. come from the nightly env (the fork pins torch==2.13.0,
# which is exactly what the nightly has). The nightly install is untouched.
#
# Tool-call flags are deliberately omitted: the fork's PyO3 parser was borrowed
# prebuilt from the nightly wheel, and tools are irrelevant to the battery.
set -euo pipefail

VENV="$HOME/vllm-nightly-env"
FORK="${FORK:-$HOME/vllm-pr-src}"

export PYTHONPATH="$FORK${PYTHONPATH:+:$PYTHONPATH}"
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"

CUDA_HOME="$VENV/lib/python3.12/site-packages/nvidia/cu13"
export CUDA_HOME
export PATH="$CUDA_HOME/bin:$VENV/bin:$PATH"
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

# Host-RAM guard for any FlashInfer JIT compile -- see serve-qwen38.sh.
export MAX_JOBS="${MAX_JOBS:-4}"
# NVFP4 KV must be head-major. The fork resolves this itself, but pin it so the
# experiment cannot be confounded by layout selection.
export VLLM_KV_CACHE_LAYOUT="${VLLM_KV_CACHE_LAYOUT:-HND}"

MODEL="unsloth/Qwen3.8-27B-NVFP4"
CHAT_TEMPLATE="$(ls "$HOME"/.cache/huggingface/hub/models--unsloth--Qwen3.8-27B-NVFP4/snapshots/*/chat_template.jinja 2>/dev/null | head -1 || true)"
CT_ARG=(); [ -n "$CHAT_TEMPLATE" ] && CT_ARG=(--chat-template "$CHAT_TEMPLATE")

SPEC_ARG=()
if [ "${SPEC:-1}" != "0" ]; then
  SPEC_ARG=(--speculative-config '{"method":"mtp","num_speculative_tokens":3}')
fi

exec "$VENV/bin/python" -m vllm.entrypoints.cli.main serve "$MODEL" \
  --host 0.0.0.0 --port 8000 \
  --tensor-parallel-size 1 \
  "${SPEC_ARG[@]}" \
  --kv-cache-dtype nvfp4 \
  --gpu-memory-utilization 0.95 \
  --max-model-len "${MAXLEN:-262144}" \
  --max-num-seqs 1 \
  --max-num-batched-tokens 2048 \
  --limit-mm-per-prompt '{"image":0,"video":0}' \
  --reasoning-parser qwen3 \
  --default-chat-template-kwargs '{"enable_thinking": true}' \
  "${CT_ARG[@]}" \
  --trust-remote-code
