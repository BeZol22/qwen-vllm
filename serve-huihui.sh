#!/usr/bin/env bash
# Huihui-Qwen3.6-27B-abliterated NVFP4 (ModelOpt) + MTP on a Blackwell GPU (RTX 5090, SM120), native vLLM.
# DENSE hybrid 27B (~20GB NVFP4). Abliterated (uncensored). Vision tower IS present -> vision enabled to test.
set -euo pipefail

export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"

# CRITICAL: FlashInfer JIT-compiles the SM120 NVFP4 GEMM and needs CUDA >= 12.8 nvcc.
CUDA_HOME="$(dirname "$(dirname "$(find "$HOME/vllm-env" -name nvcc -path '*cu13*' -type f 2>/dev/null | head -1)")")"
export CUDA_HOME
export PATH="$CUDA_HOME/bin:$PATH"
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

source "$HOME/vllm-env/bin/activate"

MODEL="sakamakismile/Huihui-Qwen3.6-27B-abliterated-NVFP4-MTP"
# Use the model's own chat template if it ships one separately.
CHAT_TEMPLATE="$(ls "$HOME"/.cache/huggingface/hub/models--sakamakismile--Huihui-Qwen3.6-27B-abliterated-NVFP4-MTP/snapshots/*/chat_template.jinja 2>/dev/null | head -1 || true)"
CT_ARG=(); [ -n "$CHAT_TEMPLATE" ] && CT_ARG=(--chat-template "$CHAT_TEMPLATE")

exec vllm serve "$MODEL" \
  --host 0.0.0.0 --port 8000 \
  --tensor-parallel-size 1 \
  --safetensors-load-strategy prefetch \
  --performance-mode interactivity \
  --quantization modelopt \
  --speculative-config '{"method":"mtp","num_speculative_tokens":3}' \
  --kv-cache-dtype fp8_e4m3 \
  --gpu-memory-utilization 0.90 \
  --max-model-len 131072 \
  --max-num-seqs 1 \
  --max-num-batched-tokens 8192 \
  --enable-prefix-caching \
  --limit-mm-per-prompt '{"image":8,"video":0}' \
  --mm-processor-kwargs '{"max_pixels": 1003520}' \
  --reasoning-parser qwen3 \
  --default-chat-template-kwargs '{"enable_thinking": false}' \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_xml \
  "${CT_ARG[@]}" \
  --trust-remote-code
