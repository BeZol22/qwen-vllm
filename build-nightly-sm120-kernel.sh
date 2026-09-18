#!/usr/bin/env bash
# Rebuild ONLY vLLM's _C_stable_libtorch extension for SM120, carrying the
# linear-V-scale NVFP4 KV fix (sm120-nvfp4-linear-v-scales.patch).
#
# WHY ONLY THIS TARGET: the NVFP4 KV *writer* is a CUDA kernel that stores V
# scale factors in the SM100 trtllm-gen 4-token swizzled layout, while the
# FlashInfer FA2/XQA reader that consumer Blackwell must use needs them linear.
# That is not fixable from Python. But the kernel lives in the discrete
# _C_stable_libtorch CMake target (libtorch stable ABI, abi3), so we rebuild
# that one .so and drop it into the wheel install -- not all of vLLM.
#
# The fix itself needs no Python or op-schema change: the fork derives the flag
# in the kernel launcher from the device arch,
#     const bool swizzle_v_sf = get_device_prop()->major < 12;
# so SM100 keeps its swizzle and SM12x gets linear V scales.
#
# HOST RAM: this box has 31 GiB and an 8 GiB swapfile, and an uncapped CUDA
# build is exactly what OOM-killed it on 2026-09-18. Parallelism is capped two
# ways (MAX_JOBS and CMake's compile job pool) and the caller should still wrap
# this in a systemd scope with MemoryMax. Stop any running model first.
set -euo pipefail

VENV="$HOME/vllm-nightly-env"
SRC="${SRC:?set SRC to the patched vllm source tree}"
BUILD="${BUILD:-$SRC/build-sm120}"
JOBS="${JOBS:-4}"

CUDA_HOME="$VENV/lib/python3.12/site-packages/nvidia/cu13"
export CUDA_HOME
export PATH="$CUDA_HOME/bin:$VENV/bin:$PATH"
export MAX_JOBS="$JOBS"
export TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST:-12.0}"

PYEXE="$VENV/bin/python"
PYPATH="$("$PYEXE" -c 'import sys; print(":".join(p for p in sys.path if p))')"

echo "=== toolchain ==="
"$CUDA_HOME/bin/nvcc" --version | tail -2 | head -1
"$CUDA_HOME/bin/ptxas" --version | tail -2 | head -1
echo "arch list : $TORCH_CUDA_ARCH_LIST   jobs: $JOBS"

if [ ! -f "$BUILD/build.ninja" ] || [ "${RECONFIGURE:-0}" = "1" ]; then
  echo "=== configure ==="
  "$VENV/bin/cmake" -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DVLLM_TARGET_DEVICE=cuda \
    -DVLLM_PYTHON_EXECUTABLE="$PYEXE" \
    -DVLLM_PYTHON_PATH="$PYPATH" \
    -DCMAKE_CUDA_COMPILER="$CUDA_HOME/bin/nvcc" \
    -DTORCH_CUDA_ARCH_LIST="$TORCH_CUDA_ARCH_LIST" \
    -DNVCC_THREADS=1 \
    -DCMAKE_JOB_POOL_COMPILE:STRING=compile \
    -DCMAKE_JOB_POOLS:STRING="compile=$JOBS" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
else
  echo "=== reusing existing configure (RECONFIGURE=1 to redo) ==="
fi

echo "=== build _C_stable_libtorch ==="
"$VENV/bin/cmake" --build "$BUILD" --target _C_stable_libtorch -j "$JOBS"

echo
echo "=== result ==="
find "$BUILD" -name "_C_stable_libtorch*.so" -printf "%p  %s bytes\n"
echo
echo "Install with:  ./install-nightly-sm120-kernel.sh"
