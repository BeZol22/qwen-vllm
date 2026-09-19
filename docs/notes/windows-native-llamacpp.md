---
name: windows-native-llamacpp
description: On Windows the runtime is llama.cpp with unsloth GGUFs + a ggml-org DFlash drafter, not vLLM — host RAM is the reason, no trusted publisher ships an NVFP4 GGUF, and DFlash beats MTP on this architecture
metadata:
  node_type: memory
  type: project
  modified: 2026-09-19T00:00:00.000Z
---

Same box as the Linux install (RTX 5090 32 GB / 9800X3D / 31 GiB RAM, display on
the iGPU so the 5090 reads 0 MiB at idle), but booted into Windows 11, which is
where the day-to-day work happens. The server has to run **in the background
while 20+ GB of Docker containers and databases hold system RAM**, be reachable
on the LAN from a MacBook Pro running OpenCode, and **serve vision** — web/UI
work drives Playwright MCP, which feeds screenshots back as images. No phones,
no Open WebUI.

**Decision: native Windows `llama-server`, unsloth GGUFs + a ggml-org DFlash
drafter. Not vLLM, not WSL2.**
Launcher: [`serve-qwen38-windows.ps1`](../../serve-qwen38-windows.ps1).

## Host RAM is the reason, not the GPU

This is the load-bearing argument and it is worth stating plainly, because the
first draft of this decision leaned on NVFP4 and that turned out not to be
available (below). The reason survives anyway:

* All WSL2 distros *and Docker Desktop* share one VM and one `.wslconfig` memory
  budget. Docker Desktop here has no memory cap of its own, so it already lives
  inside the 15.6 GiB default (50% of 31 GiB).
* vLLM's host peak is ~10.4 GiB during load, plus the FlashInfer JIT
  ([[host-ram-is-the-other-ceiling]]). Fitting that beside 20+ GB of containers
  on a 31 GiB box means permanent negotiation over one pool.
* Under WSL the 5090 is a WDDM device: it pages VRAM to system RAM instead of
  raising a clean `torch.OutOfMemoryError`, so the measure-to-the-edge method
  behind [[gpu-memory-utilization-locked]] loses its signal.

`llama-server` runs with no VM at all, and LAN exposure is one firewall rule
instead of mirrored networking. That is the whole argument.

**Host RAM, MEASURED in service 2026-09-19 — an earlier draft of this note said
"~1–2 GB" and that was wrong:**

| metric | value |
|---|---|
| WorkingSetPrivate (the honest figure) | **7.28 GB** |
| WorkingSet (resident, incl. file-backed) | 24.51 GB |
| PrivateMemorySize64 (committed VA, incl. reservations) | 35.27 GB |
| model files on disk | 21.58 GB |

Read the right column. **7.28 GB private resident** is the real steady-state
cost; the 24.51 GB working set is mostly the memory-mapped model file, which is
file-backed and evictable rather than private commit, and the 35.27 GB
`PrivateMemorySize64` is committed *address space* including mmap reservations —
not memory pressure, and the number most likely to cause a false alarm.

This still beats WSL2 comfortably (vLLM's ~10.4 GiB anonymous load peak, plus
the VM, plus the FlashInfer JIT), but the margin is smaller than claimed: 7.28
alongside 20+ GB of containers is roughly 27 of 31 GiB. Expect the mmapped model
pages to be evicted under that pressure. With `--n-gpu-layers 99` the weights
are served from VRAM and the host copy is only needed during load, so eviction
should cost nothing after startup — *should*, on reasoning, not measured under
real container pressure. If the box thrashes, that assumption is the first thing
to test.

## Quant selection: why not NVFP4, and why not Q4_0

**No trusted publisher ships an NVFP4 GGUF.** Verified against the HF API, not
model cards:

* `unsloth/Qwen3.8-27B-GGUF` — Q4_0 / Q4_1 / Q8_0, the full UD-* ladder, two
  mmproj, an imatrix, and `MTP/mtp-Qwen3.8-27B-Q4_0.gguf`. **No NVFP4.**
* `ggml-org/Qwen3.8-27B-GGUF` — the llama.cpp team's own org. Q4_K_M / Q8_0 /
  BF16, mtp-* at three precisions, dflash-*, mmproj at BF16 **and Q8_0**
  (0.63 GB, the one thing unsloth lacks). **No NVFP4.**
* Qwen publishes no official GGUF for this model at all.

NVFP4 GGUFs exist only from single-user community repos, which are **rejected on
provenance** — this serves the coding agent, trust matters more than kernels.
So the three goals do not co-exist; pick two:

| | trusted | NVFP4 | native Windows |
|---|---|---|---|
| unsloth GGUF + llama.cpp | yes | no | yes |
| `unsloth/Qwen3.8-27B-NVFP4` + vLLM | yes | yes | no (WSL2) |
| community NVFP4 GGUF | no | yes | yes |

Row 1 wins because row 2 loses on the host-RAM constraint above, which is the
hard one. **Losing NVFP4 costs throughput, not quality**: `UD-Q5_K_M` is 19.77 GB
= **5.86 bits/weight**, *above* the ~5.6 bpw of the community NVFP4 mixed quants
and above what this model effectively runs at on the vLLM side. A drafter buys
most of the throughput back (see below).

**Do not use plain `Q4_0` (16.06 GB)** even though it is in the unsloth repo and
looks like the obvious 4-bit pick. It is the legacy format — one fp16 scale per
32 weights, no imatrix — and `UD-Q4_K_M` is better per bit at essentially the
same size. Critically, **Q4_0 is not NVFP4**: both are "4-bit" and that is where
the resemblance ends. Q4_0 does not touch the Blackwell FP4 tensor cores, so
picking it gives up quality *and* buys no acceleration.

## Speculative decoding: DFlash is the default, MTP is the fallback

Two drafters exist for this model and neither is baked into the weights — both
are separate files passed with `--model-draft`. They differ in how they propose:

* **MTP** — Qwen's native next-*n* head (`blk.64`), sequential, shallow
  (`--spec-type draft-mtp`, n-max 2–3). unsloth ships it as a **1.37 GB** GGUF
  under `MTP/`. Their own docs pair it with `--mmproj`, so **drafter + vision is
  a supported combination**, not a gamble.
* **DFlash** — a *block-diffusion* drafter ([arXiv 2602.06036](https://arxiv.org/pdf/2602.06036)):
  predicts a whole block in one pass, keeps top candidates per position, and a
  selector traces one coherent path through them. Drafts much deeper
  (`--spec-type draft-dflash`, n-max 5–7). `ggml-org` ships it at **1.09 GB**.

**DFlash is the default.** Measured on the same compute capability this card is
(12.0, RTX PRO 6000 Blackwell), same model, 100 LiveCodeBench prompts:

| | speedup | acceptance | draft size |
|---|---|---|---|
| MTP @ width 7 | 2.00× | 48% | 1.8 GB (Q8_0) |
| DFlash2 @ width 7 | 2.26× | 60% | 1.1 GB (Q4_K_M) |
| **DFlash2 @ width 5** | **~2.75×** | **70.4%** | — |

and the gap **widens with context** — 1.59× @512, 2.62× @4K, 3.55× @36.8K —
which is the direction that matters for agentic coding at depth. There is also a
known upstream weakness on exactly this architecture family: llama.cpp issue
**#23322, "Low MTP Draft Acceptance Rate with SWA/Hybrid Memory Models"**.

### MEASURED ON THIS BOX, 2026-09-19

llama.cpp **b11053**, UD-Q5_K_M target, q8_0 KV, ctx 131072, vision off,
400 output tokens per sample, via `bench-drafters.py`:

| depth | none | MTP (n=2) | DFlash (n=5) |
|---|---|---|---|
| 512 | 67.7 tok/s | 126.2 (1.86×) | **171.3 (2.53×)** |
| 4,096 | 67.6 tok/s | 125.2 (1.85×) | **147.6 (2.18×)** |
| 32,768 | 62.4 tok/s | 100.4 (1.61×) | **150.3 (2.41×)** |
| acceptance | — | 67.9% | 57.4% |

**DFlash wins at every depth** — by 37% / 21% / 43%. The published choice holds,
but two details did not transfer and are worth not re-deriving:

* **MTP's acceptance here is 67.9%, far above the published 48%, and it BEATS
  DFlash's 57.4% — yet DFlash is much faster.** Acceptance *rate* is the wrong
  figure of merit: DFlash drafts far more tokens per step (470–567 vs MTP's
  324–363), so a lower rate still yields more accepted tokens per step.
* **The "advantage grows with context" curve did not reproduce.** Both are
  flat-to-declining here; what actually happens is that MTP *degrades* with
  depth (1.86× → 1.61×) while DFlash roughly holds (2.53× → 2.41×). The
  comparison's direction survives, its shape does not.

Also settled: ggml-org's unversioned drafter reports `block_size=8,
mask_token_id=248070, n_extract=5, sample_from_anchor=true` at load — same as
the benchmarked DFlash2 checkpoint, so n-max caps at 7 and **n-max 5 is in
range**. And the unsloth target against the ggml-org drafter works fine.

### Speculative decoding is NOT bit-exact here, and that is fine

The accuracy axis the published study skipped, measured: **verbatim battery 8/8
for every mode**, but on free-form output both drafters diverge from the
no-drafter baseline *early* — 24–47% in, reproducibly, at the same offsets
across independent runs.

That is not a defect, and the control is what proves it. A `none-b` run with
byte-identical flags to `none` is **identical at all depths**, so llama.cpp is
deterministic run to run and the divergence really is the drafter. Reading the
diffs: every one sat inside the model's **reasoning** text and was a paraphrase
reaching the same conclusion, with the same final code.

Mechanism: verification runs the target at a different batch shape than 1-token
decode, so float reduction order differs and near-tie logits flip. Chain-of-
thought is near-tie-dense from its first sentence, which is why divergence is
early rather than late. An earlier version of the gate assumed the opposite
(late = noise, early = bug) and failed both drafters for normal behaviour; it
now reports free-form divergence and gates on the verbatim battery instead,
where exact equality does have to hold.

**This measures correctness, not quality.** No quality benchmark was run, and
four inspected divergences are not a quality study. If output ever seems worse
with a drafter, `$env:QWEN_SPEC = 'none'` is the control to reach for first.

`serve-llamacpp.sh` still says *"No MTP (llama.cpp has none)"* — out of date, and
applies only to the Qwen3.6 NEO-CODE model it launches.

Incidentally, b11053's `--spec-type` also accepts `draft-eagle3`, **`draft-dspark`**
and several `ngram-*` variants; the Jetson AI Lab page claiming DSpark is
vLLM-only is out of date. Untested here, no checkpoint downloaded.

## Vision, and the Playwright trap

Qwen3-VL support including **DeepStack** is merged upstream (PR #16780); the
`tools/mtmd/README.md` model list still says only "Qwen 2 / 2.5 VL" and is stale.

**`--image-max-tokens 1280` is the load-bearing flag.** It is the llama.cpp
analogue of the vLLM side's `--mm-processor-kwargs '{"max_pixels": 1003520}'`,
and it matters more here — without it a **full-page Playwright screenshot can eat
the context window**, because those are viewport-width but arbitrarily tall, so
pixel count is unbounded in a way an ordinary photo is not. 1280 tokens is
roughly the 1,003,520-pixel cap already in production on vLLM and still covers a
1280x720 viewport shot at about native resolution.

Caveat to hold: **llama-server multimodal is explicitly experimental** and
upstream warns the subsystem is "under very heavy development, breaking changes
are expected." Pin a known-good build number rather than always pulling latest,
the same way the vLLM side is pinned.

## VRAM budget at the defaults

| | |
|---|---|
| card | 31.84 GiB |
| UD-Q5_K_M weights | ~18.41 GiB |
| DFlash drafter | ~2.66 GiB (measured +2,720 MiB) |
| BF16 mmproj | ~0.87 GiB |
| **left for KV + state + compute** | **~9.9 GiB** |

(MTP instead costs slightly more, ~3.28 GiB: the 1.37 GB file plus unsloth's
stated ~2 GB of headroom.)

At the same 36.5 KiB/token the vLLM side measured, q8_0 KV costs ~4.6 GiB for
131,072 tokens, leaving ~4.7 GiB of slack. f16 KV would cost ~9.1 GiB and consume
essentially the whole remainder — so **q8_0 is not an optimisation here, it is
what makes the window affordable**. Dropping the drafter entirely
(`$env:QWEN_SPEC = 'none'`) frees ~2.7 GiB if a much longer window is ever worth
more than the speed.

## How to apply

Run `serve-qwen38-windows.ps1`; its header carries the one-time setup (binaries,
the four model files, firewall).

### The two big risks: BOTH CLEARED, measured 2026-09-19

`test-agentic.py`, against the real launcher config, **8/8**:

1. **Qwen3 XML tool calling at depth — issue #26530 does NOT reproduce** on
   b11053 with this model. A proper `tool_calls` structure with the right
   function and argument came back at every depth tested: 360 / 7,891 / 30,484 /
   60,591 and **92,262 real prompt tokens**. This was ranked the most likely
   thing to sink the deployment. It did not. `--jinja` remains mandatory.
2. **The Playwright MCP shape works end to end** — image in, tool call carrying
   a value read from the image, tool result fed back, second tool call. Vision
   does not break tool calling, and the system message upstream injects under
   `--jinja` ("Respond in JSON format, either with tool_call...") does not upset
   this template.

**But it found a real defect, and the fix is `--image-min-tokens 1024`.**
Without the floor the model read a rendered `MARBLE-SIPHON-4417` as
`MARBLE-SIPHON-417` — a dropped digit on an image a human reads instantly — and
*inconsistently*, since the same image read correctly in the two tool-calling
turns. That inconsistency is worse than a clean failure: a UI check would
silently pass on the wrong value. Cause: a 1280x320 banner at 32x32 px/token is
~400 image tokens, well under the 1024 that llama.cpp warns about at load
("Qwen-VL models require at minimum 1024 image tokens to function correctly on
grounding tasks"). Setting the floor turned 7/8 into 8/8. Grounding is precisely
what Playwright work needs, so **a ceiling without a floor is a misconfiguration
here, not a half-measure.**

### Re-running the gates

* [`test-agentic.py`](../../test-agentic.py) — the two risks above. Assumes a
  running server (start the launcher first, so it exercises the production
  config rather than a hand-built one). Re-run it after any llama.cpp bump:
  multimodal and the tool-call parser are the two fastest-moving things here.
* [`bench-drafters.py`](../../bench-drafters.py) — the drafter comparison,
  results recorded above. Manages its own server per mode on port 8001, so
  production on :8000 is undisturbed. `--sweep 3,5,7` sweeps DFlash's n-max.
  If DFlash ever stops winning, `$env:QWEN_SPEC = 'mtp'` and record why here.
* `test-verbatim.py`, `test-longctx.py`, `test-vision.py` — the original gates.
  They point at an OpenAI-compatible endpoint, so they run against
  `llama-server` unchanged. Only raise `--ctx-size` after they pass; a clean
  startup proves nothing, and that lesson transfers intact.

### Two Windows-specific traps, both cost a debugging round

* **The launcher killed itself under output redirection.** `llama-server` writes
  its NORMAL logs to stderr, and PowerShell 5.1 wraps every stderr line from a
  native exe in a `NativeCommandError` whenever the stream is redirected — so
  with `$ErrorActionPreference = 'Stop'` still in force, the first ordinary log
  line ("llama_server: initializing ...") became fatal and the script exited 1
  before the model loaded, with the cause buried in a PowerShell parser trace.
  It does NOT reproduce interactively, only under `*>` / `2>&1` or a service
  wrapper — i.e. exactly where it hurts. The launcher now drops back to
  `Continue` immediately before invoking the binary, after path validation.
* **`localhost` resolves to `::1` first on this box** while `llama-server` binds
  IPv4 only, so a `localhost` health check is refused. Everything here uses the
  `127.0.0.1` literal. This is the same IPv6-before-IPv4 trap the vLLM launcher
  documents for `--host ::`, biting from the other side. Related: when waiting
  on readiness use `curl -sf`, not `curl -s` — without `-f` a 503 "still
  loading" counts as success and the test fires mid-load.

LAN reachability has a second step the Linux `ufw` setup did not: the rule must be
scoped to `192.168.178.0/24` **and** the Ethernet profile must be Private, or
Windows drops inbound regardless. NordLynx (10.5.0.2/16) is installed — if the
MacBook cannot reach port 8000, test with NordVPN disconnected before touching
the firewall.

The Linux install is unchanged and remains the reference; this is the Windows
path, not a replacement for it.
