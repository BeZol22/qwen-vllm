---
name: qwen38-nvfp4-full-context-port
description: SM120 NVFP4-KV port for Qwen3.8 at 262144 — STILL A DEAD END on driver 610.57.04: short prompts are clean 8/8 but deep retrieval corrupts INTERMITTENTLY (fails at 31K, passes at 218K)
metadata:
  node_type: memory
  type: project
  modified: 2026-09-18T18:40:00.000Z
---

Goal: run `unsloth/Qwen3.8-27B-NVFP4` at its **native 262144** context on the
RTX 5090, which fp8 KV cannot do (fp8 tops out at 190400 --
[[qwen38-context-ceiling-measured]]). Route: `--kv-cache-dtype nvfp4`, porting
`ch2lab/vllm` branch `sm120-nvfp4-kv-cache` (commit 8275b36, 2026-08-18, cloned
at `~/vllm-pr-src`) onto the much newer `~/vllm-nightly-env`
(vLLM 0.29.1rc1.dev371+g1cdf1689e).

**Capacity is SOLVED and measured (2026-09-18):** with the port applied it serves
262144 and reports `GPU KV cache size: 300,980 tokens, Maximum concurrency 1.15x`
(404,895 / 1.54x with MTP off). So nvfp4 clears full context by ~15%.

**Correctness is NOT solved -- do not use it for real work.** It starts, serves,
and answers fluently but **corrupts tokens**: verbatim copy of a passphrase from a
~30-token prompt failed 7/8 (`COBALT-LANTERN-3095` -> `COBALT-3095`,
`QX7-VELLUM-...` -> `QX9-VELLUM-...`; the middle segment of hyphenated strings
drops). Arithmetic and one-word answers look fine, which is what makes it
dangerous. Ruled out by experiment: speculative decoding (identical 1/8 with
`SPEC=0`) and KV layout (resolved layout is correctly LBHNC/HND).

**The controlling evidence is the fp8 A/B.** Same model, weights, prompts,
sampling, chat template and harness, only `--kv-cache-dtype` differs:

| KV dtype | verbatim battery | deep retrieval |
|---|---|---|
| `fp8_e4m3` (190400) | **8/8 exact** | **PASS** from 179,718 tokens |
| `nvfp4` (262144) MTP on | 1/8 | corrupted at 247,595 |
| `nvfp4` (262144) MTP off | 1/8 | -- |

So the corruption is attributable to the nvfp4 KV path alone, and
`serve-qwen38.sh` (fp8) is positively validated as uncorrupted, not merely
assumed. Run this A/B before trusting ANY future change to a KV dtype here --
the short verbatim battery is cheap (~30-token prompts, seconds) and it caught
what a 247K retrieval test called a near-pass.

**Kernel fix applied 2026-09-18 and it was NOT sufficient: 1/8 -> 3/8, fp8 is
8/8.** The V-scale swizzle was a real bug but not the only one. Corruption
persists even on a **30-token single-chunk prefill**, so the remaining fault is in
the core nvfp4 read path (FA2 prefill / XQA decode), not in chunking or long
context. Confirmed there are no further fork kernel changes to port: the other
differing csrc files (`cache_kernels.cu`, `nvfp4_quant_kernels.cu`) are 370-commit
upstream drift where the NIGHTLY is newer/more correct (it added nvfp4_ds_mla and
padded-scale zero-init the fork lacks). So the gap is either my Python port or a
FlashInfer-version semantic change -- not something more to copy from the fork.

**The fork's OWN tree also fails: 2/8** (built in place 2026-09-18, 408 objects,
arch 12.0 only, run via PYTHONPATH against the nightly env's deps). So our port is
NOT the problem -- the fork's own kernels + own Python corrupt output the same way
(`ZEBRA-TUNDRA-8821` -> `ZEBRA-TUNNEL-TUNDRA-8821`, a token INSERTED).
Scoreboard: fp8 8/8, our port 3/8, fork 2/8, unpatched nvfp4 1/8.

**CONFOUND ELIMINATED -- VERDICT: nvfp4 KV is a DEAD END on this card.** Re-ran
the fork against its exact pin `flashinfer-python==0.6.16.post3`: still **2/8**,
and the outputs were **byte-for-byte identical** to the 0.6.18.post1 run
(`ZEBRA-TUNNEL-TUNDRA-8821`, `GRANITE-LOCK-4`, same KV pool 351,952). Identical
output across two FlashInfer releases means the version is not a factor and the
corruption is deterministic in code that did not change between them.

Ruled out, each by experiment, not inference: our port vs the fork's own tree;
the `swizzle_v_sf` kernel fix; speculative decoding (SPEC=0); KV layout (HND
confirmed every run); FlashInfer 0.6.16.post3 vs 0.6.18.post1. **Do not spend
more time on nvfp4 KV for this model.**

**NEXT ROUTE INSTEAD -- TurboQuant, and it needs NO patches.** The unmodified
nightly already accepts `turboquant_k8v4`, `turboquant_4bit_nc`,
`turboquant_3bit_nc`, `turboquant_k3v4_nc` as cache dtypes (`config/cache.py`)
and ships a `v1/attention/backends/turboquant_attn.py` backend. Per vLLM's own
TurboQuant study, `turboquant_k8v4` is 24.25 KiB/tok -> 6.06 GiB at 262144 with
>98-99% quality recovery -- it fits the ~7.9 GiB ceiling. Try it on the PRISTINE
nightly (restore `flashinfer.py.orig` first so nvfp4 patches cannot interfere)
and gate it on the same 8/8 verbatim battery.

**(historical) The confound that was tested:** the fork pins
`flashinfer-python==0.6.16.post3` and we ran it against **0.6.18.post1**. The
reader-side semantics (FA2 paged nvfp4 / XQA `kv_cache_sf`) live in FlashInfer, so
a two-release drift is a plausible cause of exactly this kind of corruption. Until
that is tested, "nvfp4 KV is broken on SM120" is NOT established -- only "broken
with flashinfer 0.6.18.post1". Testing it costs a flashinfer downgrade in the
nightly env plus one cold JIT compile (~9 min at MAX_JOBS=4); restore 0.6.18.post1
afterwards because the nightly's own vllm expects it.

**Also learned:** the fork's vendored FlashAttention-2 (`_vllm_fa2_C`) builds for
**sm_80 with no sm_120 cubin** (vLLM's FA2 CMake does not list 12.0, so it falls
back to `8.0+PTX`), and driver **595.71.05 refuses to JIT CUDA 13.4's PTX ISA 9.4**
-> "the provided PTX was compiled with an unsupported toolchain". It is only
reached via the vision tower, so `--limit-mm-per-prompt '{"image":0}'` works around
it for text-only tests. A NEWER DRIVER would fix it properly (the user has newer
ones available) and is required if the fork build ever needs vision.

**Root cause (of the part that was fixed):** the NVFP4 KV **writer is a CUDA kernel**, and it stores the **V
scale factors swizzled** (SM100 trtllm-gen 4-token pattern) while the FlashInfer
FA2/XQA reader that consumer Blackwell must use requires them **linear**. K scales
are linear either way -- hence partial, plausible corruption rather than noise.
The fork fixes it with a `swizzle_v_sf` bool in
`csrc/libtorch_stable/nvfp4_kv_cache_kernels.cu`.

**Why this matters for planning:** the port is therefore **not Python-only** (an
earlier assessment of mine that turned out wrong). `~/qwen-vllm/patch-nightly-sm120-nvfp4-kv.py`
(14 anchored Python sites, idempotent, re-applies from a `.orig` backup, asserts
on every anchor) is necessary but insufficient. The remaining work is rebuilding
the **`_C_stable_libtorch`** CMake target with that flag plumbed through -- a
discrete target with its own source list, so it does NOT require building all of
vLLM. Cap any build with `MAX_JOBS` ([[host-ram-is-the-other-ceiling]]) and keep
the toolchain coherent ([[nightly-cuda-toolchain-must-be-coherent]]).

**Files:** `serve-qwen38-nightly.sh` (carries a loud DO-NOT-USE banner, `SPEC=0`
toggle, `VLLM_KV_CACHE_LAYOUT=HND`), `probe-nvfp4-ceiling.sh`, `test-longctx.py`
(needle-in-haystack; the test that caught this -- a smoke test would not have).
Also measured: attention block size is forced to **2848** under nvfp4 (1600 at
fp8). Daily driver remains `serve-qwen38.sh` (fp8, 190400, validated).

## Driver 610.57.04 FIXED THE SHORT-PROMPT CORRUPTION ONLY -- still unusable

Every elimination above ran on driver **595.71.05**. The box is now on
**610.57.04** (installed by the DKMS rebuild behind [[secureboot-mok-blocks-nvidia-dkms]]).
Re-ran the verbatim battery on the nightly, port applied, **stock wheel kernel
(no swizzle patch -- confirmed by md5 against `.so.wheel-orig`)**:

| config | verbatim | previously |
|---|---|---|
| `fp8_e4m3` control (nightly, drv 610) | **8/8** | 8/8 |
| `nvfp4`, port-only | **8/8** | **1/8** |
| `nvfp4_4over6`, port-only | 7/8 (`TOPAZ-BRIDGE-5529` -> `TOP-BRIDGE-5529`) | never tested |
| `nvfp4 --enforce-eager` | **8/8** | -- |
| `nvfp4` + `disable_flashinfer_q_quantization` | **8/8** | -- |

So the corruption was driver-dependent, not a code defect, and the swizzle kernel
rebuild is NOT needed. `nvfp4_4over6` is genuinely worse -- do not use it.
CUDA graphs and FP8 query quantization are both exonerated (8/8 either way).

**Also corrected:** the old scoreboard's "unpatched nvfp4 1/8" row cannot be right.
On a truly pristine nightly, nvfp4 never reaches inference --
`ValueError: No valid attention backend found for cuda with ... kv_cache_dtype=nvfp4`
(`platforms/cuda.py:500`); FlashInfer is the only backend advertising nvfp4 and it
disqualifies itself on SM120. `nvfp4_4over6` fails identically. That 1/8 was
measured WITH the Python port applied. The real ladder is port-only, not "unpatched".

**STILL PENDING at time of writing: deep validation at the full 262144.** The 8/8
runs above were at `--max-model-len 32768`. The prior notes are explicit that short
prompts are not the gate (a 247,595-token retrieval previously corrupted). Do not
promote nvfp4 to daily-driver use until `test-longctx.py` passes near max context.
New harness: `~/qwen-vllm/test-verbatim.py [port]` -- 8 hyphenated passphrases,
temp 0, exits non-zero below 8/8.

## FINAL: depth sweep kills it (2026-09-18, driver 610.57.04)

The 8/8 verbatim result above is REAL but MEANINGLESS as a gate: ~30-token prompts
put almost nothing in the KV cache. Served at the full 262144 (nvfp4, port applied,
stock wheel kernel, `--enforce-eager`, `--kv-cache-memory-bytes 6710886400`,
pool 291,271 tokens / 1.11x) and swept `test-longctx.py`:

| prompt tokens | result | answer |
|---|---|---|
| 31,383 | **FAIL** | quoted `MARBLE-4417` -- `SIPHON` dropped |
| 95,154 | PASS | correct |
| 148,949 | **FAIL** | `MARBLE-4407` -- segment dropped AND digit mutated |
| 178,819 | PASS | correct |
| 218,665 | PASS | correct |

**Non-monotonic -> intermittent corruption, not 4-bit error accumulation** (which
would degrade with depth, not fail at 31K and pass at 218K). At 31,383 the model
reasoned aloud and quoted the corrupted needle as what it found *in the text*, so
the bad bytes are genuinely IN the cache -- not a sampling artifact.

**It fails BELOW fp8's validated 190400, so nvfp4 buys nothing at any window size.**
Driver 610 moved it from "corrupt on 30-token prompts" to "corrupt intermittently
under real load" -- better, still unusable. Capacity was never the problem:
262144 needs 5.61 GiB nvfp4 vs 9.29 GiB fp8.

**Gate lesson:** `test-verbatim.py` 8/8 is NECESSARY, NOT SUFFICIENT. Any future KV
dtype must pass a DEPTH SWEEP (~30K/95K/150K/180K/220K), because a single deep
sample can pass by luck -- 3 of 5 passed here.

**Operational note:** at 262144 vLLM hands the KV pool ALL free VRAM (371,370 tokens
= 7.9 GiB for a window needing 5.61) and then OOMs in activations mid-prefill
(`torch.OutOfMemoryError ... 44.56 MiB is free`). Pin it with
`--kv-cache-memory-bytes`. Also `--enforce-eager` was required to fit at all.

**DO NOT REOPEN nvfp4 without a new variable.** Ruled out now: our port, the fork's
tree, the swizzle kernel fix, SPEC=0, KV layout, flashinfer 0.6.16.post3 vs
0.6.18.post1, CUDA graphs (`--enforce-eager` 8/8 both ways), FP8 query quantization,
`nvfp4_4over6` (WORSE -- 7/8 short), and driver 595 vs 610.

**2026-09-18: `~/vllm-nightly-env` deleted, so the env it lived in is GONE.** The
scripts that referenced it (`serve-qwen38-nightly.sh`, `serve-fork-nvfp4.sh`,
`probe-nvfp4-ceiling.sh`, `patch-nightly-sm120-nvfp4-kv.py`,
`build-nightly-sm120-kernel.sh`, `build-fork-sm120.sh`,
`install-nightly-sm120-kernel.sh`) are dead and point at a missing path. The fork
clone `~/vllm-pr-src` still exists. Given the DEAD-END verdict above, delete these
rather than repair them unless nvfp4 is reopened with a genuinely new variable.
