---
name: host-ram-is-the-other-ceiling
description: This box has only 31 GiB system RAM + 8 GiB swap, and an unbounded FlashInfer JIT compile (MAX_JOBS unset) host-OOMs it — a failure mode entirely separate from VRAM
metadata:
  node_type: memory
  type: project
  modified: 2026-09-18T18:00:00.000Z
---

Not every "we crashed" on this box is VRAM. The 9800X3D host has **31 GiB of RAM
(30.3 GiB managed) and an 8 GiB swapfile** against 16 CPU threads, and vLLM's own
host peak is ~10.4 GiB. That leaves very little headroom for anything that fans out
per-core.

**The 2026-09-18 17:50 crash:** a cold FlashInfer JIT build of
`fp4_gemm_cutlass_sm120` — 16 separate `.cu` translation units (half/bf16 x CUTLASS
tile shapes) — ran with no `-j` cap, because `flashinfer/jit/cpp_ext.py:_get_num_workers()`
returns `None` unless **`MAX_JOBS`** is set, so ninja used all 16 threads. Each `cicc`
peaked at ~1.6-1.8 GiB => ~26 GiB anon, swap down to 76 kB free, kernel OOM-killer
took `VLLM::EngineCore`. systemd then SIGKILLed the whole `ptyxis-spawn-*.scope`
(27.1 G RAM / 6 G swap peak), which killed the Claude Code process living in that
same terminal — that is why the session died too, and why it reads as a whole-box
crash rather than a server crash.

**Why:** the GPU was never involved. Reaching for `--gpu-memory-utilization` or
`--max-model-len` here is the wrong instinct and would cost context for nothing —
see [[gpu-memory-utilization-locked]] and [[qwen38-context-ceiling-measured]].
Diagnose with `journalctl -b 0 | grep -i "oom-kill"`, not `nvidia-smi`.

**How to apply:** `serve-qwen38.sh` now exports `MAX_JOBS="${MAX_JOBS:-4}"`
(~7 GiB of compilers, coexists with vLLM's 10.4 GiB). Two things this does NOT cover:
  * **There are two venvs.** `~/vllm-env` has flashinfer 0.6.12.dev20260531;
    `~/vllm-nightly-env` has 0.6.18.post1 and is what crashed. **No script in
    `~/qwen-vllm/` references the nightly env** — it gets launched by hand, so it has
    no `MAX_JOBS` guard. Export it manually, or give the nightly env its own launcher.
  * The JIT cache is keyed by flashinfer version + arch
    (`~/.cache/flashinfer/<ver>/120f`), so **every flashinfer upgrade re-arms this**.
    After the crash the cache held only `build.ninja` and a stale lock — zero `.o`
    files — so the compile restarts from scratch on the next launch.
Prefer launching models via `systemctl --user start qwen38`, not from the terminal
running your editor: in a systemd unit the OOM blast radius stops at the unit.
