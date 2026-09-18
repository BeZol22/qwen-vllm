---
name: nightly-cuda-toolchain-must-be-coherent
description: The pip CUDA stack in ANY vLLM venv here must be all-one-version (13.4.92) or FlashInfer JIT fails; three mutually-constraining components, and 13.0 is NOT an option on this glibc
metadata:
  node_type: memory
  type: project
  modified: 2026-09-18T18:30:00.000Z
---

FlashInfer JIT in `~/vllm-nightly-env` compiles only when the pip CUDA components
are **all the same version**. As of 2026-09-18 that version is **13.4.92**, set
explicitly with:

```
pip install --no-deps 'nvidia-cuda-nvcc==13.4.92' 'nvidia-nvvm==13.4.92' \
  'nvidia-cuda-crt==13.4.92' 'nvidia-cuda-runtime==13.4.92' 'nvidia-cuda-nvrtc==13.4.92'
```

**Why:** three constraints pull against each other, and partial alignment just
trades one error for another. All three must hold at once:
  1. `nvvm`/cicc emits a PTX ISA that `bin/ptxas` must accept. nvvm 13.4 emits
     `.version 9.4`; ptxas 13.0 caps at 9.0 -> `ptxas fatal: Unsupported .version 9.4`.
  2. FlashInfer's **bundled** CCCL (`flashinfer/data/cccl/libcudacxx/.../__cccl/cuda_toolkit.h`)
     hard-errors unless nvcc's major.minor **equals** `CUDART_VERSION` from
     `nvidia-cuda-runtime`'s headers -> "CUDA compiler and CUDA toolkit headers
     are incompatible". So bumping nvcc alone is not enough; the runtime headers
     must move with it (13.4.92 -> `CUDART_VERSION 13040`).
  3. **13.0.88 `nvidia-cuda-crt` does not work on this box at all**, independent of
     vLLM: its `crt/math_functions.h` conflicts with this system's glibc headers
     ("exception specification is incompatible with that of previous function
     `rsqrt`", `/usr/include/x86_64-linux-gnu/bits/mathcalls.h:206`). 13.4.92 fixed
     it. So "downgrade everything to 13.0" is a dead end -- only align UP.

The env's own `cuda-toolkit==13.0.3.0` meta-package pins the 13.0.88/13.0.96 set,
which is **misleading**: following those pins reproduces failure 3. Ignore it.

**How to apply:** after any `pip install`/upgrade in the nightly env, re-check with
`nvcc --version`, `ptxas --version` and
`grep '^#define CUDART_VERSION' .../nvidia/cu13/include/cuda_runtime_api.h`
(13040 = 13.4) before blaming vLLM. Fastest end-to-end check, which exercises all
three constraints in one shot:
```
printf '#include <cuda/std/__cccl/cuda_toolkit.h>\n__global__ void k(){}\n' > /tmp/g.cu
.../nvidia/cu13/bin/nvcc -c -gencode=arch=compute_120f,code=sm_120f \
  -I.../flashinfer/data/cccl/libcudacxx/include -std=c++17 /tmp/g.cu -o /tmp/g.o
```
Cap the compile with `MAX_JOBS` regardless -- see [[host-ram-is-the-other-ceiling]].
Context for why this env exists: [[qwen38-nvfp4-full-context-port]].

**2026-09-18: `~/vllm-nightly-env` was REMOVED** (user request, 8.1 GB reclaimed).
The three constraints above are NOT specific to that env -- they are properties of
this box's glibc and of FlashInfer's bundled CCCL, so they apply to every new vLLM
venv created here, including `~/vllm-029-env`. Re-run the one-shot check after any
fresh install before blaming vLLM. ENV REMOVED, LESSON KEPT.
