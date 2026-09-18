#!/usr/bin/env bash
# Build the ch2lab/vllm `sm120-nvfp4-kv-cache` fork's CUDA extensions IN PLACE,
# so the fork can be run via PYTHONPATH without installing anything.
#
# WHY: our port of the fork onto the nightly gets 3/8 on the verbatim battery
# (fp8 gets 8/8), and there are no further fork kernel changes left to copy. This
# builds the fork's OWN tree to discriminate between two hypotheses:
#   - fork scores 8/8  -> our port is incomplete; bisect against this reference.
#   - fork also fails  -> the approach does not work with this GPU/FlashInfer and
#                         nvfp4 full context is a dead end.
#
# CHEAP BECAUSE: the fork pins torch==2.13.0 / torchvision==0.28.0 and the
# nightly env has exactly those, so we reuse its dependency stack. Only `vllm`
# itself comes from the fork tree (via PYTHONPATH). The nightly install is NOT
# modified -- nothing is pip-installed here.
#
# Build in place, then run with:
#   PYTHONPATH=/home/bezol/vllm-pr-src <nightly-python> -m vllm.entrypoints.cli.main serve ...
set -euo pipefail

VENV="$HOME/vllm-nightly-env"
FORK="${FORK:-$HOME/vllm-pr-src}"
JOBS="${JOBS:-4}"

CUDA_HOME="$VENV/lib/python3.12/site-packages/nvidia/cu13"
export CUDA_HOME
export PATH="$CUDA_HOME/bin:$VENV/bin:$PATH"
export VLLM_TARGET_DEVICE=cuda
export TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST:-12.0}"
export MAX_JOBS="$JOBS"
export NVCC_THREADS=1
# The clone is a single squashed commit with no tags, so setuptools_scm cannot
# derive a version. The fork is a 2026-08-18 snapshot, i.e. ~0.29.0.
export SETUPTOOLS_SCM_PRETEND_VERSION="${SETUPTOOLS_SCM_PRETEND_VERSION:-0.29.0}"
# cmake 4 rejects the pre-3.5 minimums some FetchContent deps still declare.
export CMAKE_ARGS="${CMAKE_ARGS:--DCMAKE_POLICY_VERSION_MINIMUM=3.5}"
# No Rust toolchain on this box, and the fork's setup.py builds a PyO3 extension
# (_rust_tool_parser). It accepts a PRECOMPILED one instead when the .so is
# already sitting in vllm/ -- we borrow the nightly wheel's abi3 build, which is
# safe here because it is only the tool-call parser, nowhere near the nvfp4 path.
export VLLM_USE_PRECOMPILED_RUST=1

echo "=== fork   : $FORK"
echo "=== arch   : $TORCH_CUDA_ARCH_LIST   jobs: $JOBS"
"$CUDA_HOME/bin/nvcc" --version | tail -2 | head -1

cd "$FORK"
"$VENV/bin/python" setup.py build_ext --inplace

echo
echo "=== extensions placed in the fork tree ==="
find "$FORK/vllm" -maxdepth 1 -name "*.so" -printf "%f  %s bytes\n" | sort
