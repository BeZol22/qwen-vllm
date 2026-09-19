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

`llama-server` sits at ~1–2 GB of host RAM with no VM at all, and LAN exposure is
one firewall rule instead of mirrored networking. That is the whole argument.

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

**Those numbers are speed only.** The study says so itself: *"No accuracy
measurement at all."* That is why [`bench-drafters.py`](../../bench-drafters.py)
exists — see below. Two further unknowns it should settle: nobody has run an
unsloth *target* against a ggml-org *drafter* (should be fine, drafters are
independent of target quantisation and the vocab matches), and ggml-org's file
carries no version in its name, so whether it is DFlash1 or DFlash2 and what
`dflash.block_size` it enforces must come from the startup log, not assumption.

`serve-llamacpp.sh` still says *"No MTP (llama.cpp has none)"* — out of date, and
applies only to the Qwen3.6 NEO-CODE model it launches.

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
the three model files, firewall). Four things to verify, ordered by how likely
they are to sink the deployment:

1. **Qwen3 XML tool calling at large prompts.** `--jinja` is mandatory for
   Qwen3-family XML tool calls. llama.cpp issue #26530 reports XML tool calls
   failing to trigger on large prompts after the June 2026 AC-parser change
   (PR #24869); older builds fell back to a JSON-array grammar that was followed
   more reliably. **Test with a real OpenCode session at 50K+ tokens, not a toy
   call.** If it fails, this is the thing that sends us back to WSL2.
2. **Images and tool calls in the SAME conversation.** This is the Playwright MCP
   shape and it is not the same test as either alone — a screenshot returns as a
   tool result, gets reasoned over, then another tool call follows. Upstream also
   injects a system message under `--jinja` when tools are present ("Respond in
   JSON format, either with tool_call...") which is known to upset some
   templates. Drive one real Playwright loop end to end.
3. **The drafter choice, on this box.** Run
   [`bench-drafters.py`](../../bench-drafters.py) — it launches its own server
   per mode on port 8001 (so production on :8000 is undisturbed), holds
   everything but the drafter flags fixed, and reports **both** axes:

   * **speed** — decode tok/s at 512 / 4K / 32K depth, speedup vs no drafter,
     and true acceptance from the `draft_n` / `draft_n_accepted` timings fields.
   * **accuracy** — *greedy losslessness*, which is the right test rather than a
     benchmark score: the drafter only proposes, the 27B verifies every token,
     so at temperature 0 the output must match the no-drafter baseline. Exact
     equality is the expectation, not a hard guarantee — verification runs the
     target at different batch shapes and float non-associativity can flip a
     near-tie logit — so the gate reports *where* divergence starts: identical =
     PASS, after 80% = WARN (plausibly float noise), early = FAIL. The
     8-passphrase verbatim battery runs per mode too, since losslessness against
     a broken baseline would still pass.

   `--sweep 3,5,7` sweeps DFlash's n-max. If DFlash does not win here, switch
   with `$env:QWEN_SPEC = 'mtp'` and record the numbers in this note.
4. **The gates.** `test-verbatim.py`, `test-longctx.py` and `test-vision.py` all
   point at an OpenAI-compatible endpoint, so they run against `llama-server`
   unchanged — `test-vision.py` is no longer optional, it covers the single-image
   and 8-image cases this deployment depends on. Only raise `--ctx-size` after
   they pass. A clean startup proves nothing; that lesson transfers intact.

LAN reachability has a second step the Linux `ufw` setup did not: the rule must be
scoped to `192.168.178.0/24` **and** the Ethernet profile must be Private, or
Windows drops inbound regardless. NordLynx (10.5.0.2/16) is installed — if the
MacBook cannot reach port 8000, test with NordVPN disconnected before touching
the firewall.

The Linux install is unchanged and remains the reference; this is the Windows
path, not a replacement for it.
