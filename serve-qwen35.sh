#!/usr/bin/env bash
# Qwen3.6-35B-A3B NVFP4 (NVIDIA ModelOpt) + MTP + Vision on a Blackwell GPU (RTX 5090, SM120), native vLLM.
# MoE model: 35B total / 3B active. NVFP4 weights ~19GB.
set -euo pipefail

export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"

# CRITICAL: FlashInfer JIT-compiles the SM120 NVFP4 GEMM and needs CUDA >= 12.8 nvcc.
# Use the CUDA 13.3 toolchain shipped inside the venv (auto-detected).
CUDA_HOME="$(dirname "$(dirname "$(find "$HOME/vllm-env" -name nvcc -path '*cu13*' -type f 2>/dev/null | head -1)")")"
export CUDA_HOME
export PATH="$CUDA_HOME/bin:$PATH"

# Reclaim fragmented VRAM so graph capture doesn't OOM (also enlarges usable KV cache).
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

source "$HOME/vllm-env/bin/activate"

# NOTE: NVIDIA ships this as ModelOpt NVFP4 -> --quantization modelopt
#       (the Peutlefaire/berkerdooo 27B checkpoints were compressed-tensors instead).
#       MoE + MTP: pin the speculative MoE path to triton (NVIDIA's recommended combo).
exec vllm serve nvidia/Qwen3.6-35B-A3B-NVFP4 \
  --host 0.0.0.0 --port 8000 \
  --tensor-parallel-size 1 \
  --safetensors-load-strategy prefetch \
  --performance-mode interactivity \
  --quantization modelopt \
  --speculative-config '{"method":"mtp","num_speculative_tokens":3,"moe_backend":"triton"}' \
  --kv-cache-dtype fp8_e4m3 \
  --gpu-memory-utilization 0.90 \
  --max-model-len 125000 \
  --max-num-seqs 3 \
  --max-num-batched-tokens 8192 \
  --enable-prefix-caching \
  --limit-mm-per-prompt '{"image":8,"video":0}' \
  --mm-processor-kwargs '{"max_pixels": 1003520}' \
  --reasoning-parser qwen3 \
  --default-chat-template-kwargs '{"enable_thinking": false}' \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --trust-remote-code
