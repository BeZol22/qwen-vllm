---
name: pip-cuda-is-not-self-sufficient
description: FlashInfer's JIT links against -L$CUDA_HOME/lib64 -lcudart, which the pip CUDA wheels do not provide; on a box with no distro CUDA toolkit (Arch/Omarchy) the NVFP4 GEMM compiles but fails to LINK and the engine dies ~4 min into startup
metadata:
  node_type: memory
  type: project
  modified: 2026-09-19T12:00:00.000Z
---

**`~/vllm-029-env` is NOT self-sufficient.** REBUILD.md step 3 implies pip alone
gives a working CUDA toolchain. It does not: FlashInfer's generated `build.ninja`
ends with

```
ldflags = -shared -L$cuda_home/lib64 -L$cuda_home/lib64/stubs -lcudart -lcuda
```

and the pip wheels lay out **`lib/`, not `lib64/`**, shipping only the SONAME
`libcudart.so.13` plus `libcudart_static.a` -- there is **no unversioned
`libcudart.so`**, which is exactly what `ld -lcudart` resolves against.

**Symptom (Omarchy, 2026-09-19):** all 16 NVFP4 GEMM translation units compile
fine, then the single link step fails with `/usr/bin/ld: cannot find -lcudart` ->
`ninja: build stopped` -> `RuntimeError: Ninja build failed` -> `Engine core
initialization failed`, about **4 minutes into startup**, after the model is
already loaded. systemd restarts and does it again. Easy to misread as a
FlashInfer/vLLM bug; it is neither.

**Why Ubuntu never hit it:** a distro CUDA toolkit puts a linkable
`libcudart.so` on `ld`'s default search path, so the bogus `-L.../lib64` simply
falls through and the link succeeds anyway. Omarchy has no system CUDA at all
(`/opt/cuda` absent). `-lcuda` is fine on both: it comes from the driver
(`/usr/lib/libcuda.so -> libcuda.so.1`), not from a toolkit.

**Fix -- two symlinks, now created by `serve-qwen38-029.sh` itself:**

```bash
ln -sfn lib "$CUDA_HOME/lib64"
ln -sf libcudart.so.13 "$CUDA_HOME/lib/libcudart.so"
```

They live in `site-packages`, so **any `pip install` of an `nvidia-*` wheel
silently deletes them** and startup breaks again weeks later with no memory of
the cause. That is why they are recreated idempotently in the launcher instead of
being a one-off manual step. Verified by deleting both and restarting: the script
restores them and the service comes up.

`-L$cuda_home/lib64/stubs` pointing at a directory that does not exist is only a
linker warning, not an error -- no stub dir is needed.

**Lesson:** "pip install vllm" does not mean the box has a linkable CUDA. A JIT
that compiles is not a JIT that links, and this one only fails after the slow part
has already succeeded. See also [[nightly-cuda-toolchain-must-be-coherent]] for
the separate mixed-version trap in the same toolchain.
