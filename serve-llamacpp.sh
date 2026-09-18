#!/usr/bin/env bash
# DavidAU Qwen3.6-27B-NEO-CODE (GGUF Q4_K_M) + vision (mmproj) on a Blackwell GPU, llama.cpp.
# Replaces the vLLM/NVFP4 stack. No MTP (llama.cpp has none); vision preserved via --mmproj.
set -euo pipefail

# llama.cpp was built against the CUDA 13.3 toolkit shipped inside the venv; its libs must be on the path.
CU13="$HOME/vllm-env/lib/python3.12/site-packages/nvidia/cu13"
export LD_LIBRARY_PATH="$CU13/lib:${LD_LIBRARY_PATH:-}"

MODEL_DIR="$HOME/models/qwen3.6-27b-neo-code"

exec "$HOME/llama.cpp/build/bin/llama-server" \
  --model "$MODEL_DIR/Qwen3.6-27B-NEO-CODE-HERE-2T-OT-Q4_K_M.gguf" \
  --mmproj "$MODEL_DIR/mmproj-F16.gguf" \
  --host 0.0.0.0 --port 8000 \
  --alias qwen3.6-27b-neo-code \
  --n-gpu-layers 99 \
  --ctx-size 131072 \
  --flash-attn on \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --jinja
