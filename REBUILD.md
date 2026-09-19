# Rebuild from a freshly formatted box

> On **Arch / Omarchy**, read [Arch / Omarchy deltas](#arch--omarchy-deltas) FIRST:
> two steps below are no-ops there and one extra fix is mandatory.

Everything needed to get back to the validated state of **2026-09-19**:
vLLM **0.29.0** serving `unsloth/Qwen3.8-27B-NVFP4` on an RTX 5090 (32 GB, SM120),
fp8 KV cache, **166,400-token context**, prefix caching, MTP-3 + CUDA graphs, plus the
OpenCode agent pipeline. Reference system: Ubuntu 26.04, kernel 7.0.0-22, NVIDIA driver
**610.57.04**, Python 3.12.13 (uv-managed), iGPU drives the display (5090 headless).

Not in git (too big) - re-download or back up to an external disk BEFORE formatting:

| what | size | how to get it back |
|---|---|---|
| `~/.cache/huggingface/hub/models--unsloth--Qwen3.8-27B-NVFP4` | 22 GB | auto-downloads on first start (needs the `\|\| true` fix, see [notes](docs/notes/cold-cache-breaks-the-launcher.md)) |
| `models--nvidia--Qwen3.6-35B-A3B-NVFP4` | 22 GB | only for the old `serve-qwen35.sh` |
| `models--sakamakismile--Huihui-Qwen3.6-27B-abliterated-NVFP4-MTP` | 20 GB | only for `serve-huihui.sh` |
| `~/vllm-029-env` | 8 GB | step 3 below |

## 0. Clone to the SAME path

Scripts, systemd units and desktop launchers assume `/home/bezol/qwen-vllm`:

```bash
sudo apt install -y git curl build-essential
git clone <your-private-remote> ~/qwen-vllm
```

## 1. BIOS / display
Keep the monitor on the **iGPU** so the 5090 stays headless (18 MiB used at idle). The
memory numbers below assume that.

## 2. NVIDIA driver + Secure Boot (the trap that cost an evening)
Install driver **>= 610** (595.71.05 had a real NVFP4-KV corruption bug and cannot JIT
CUDA 13.4 PTX). With Secure Boot ON, DKMS signs the module with a fresh MOK that is NOT
trusted yet - `nvidia-smi` then fails with "couldn't communicate with the NVIDIA driver"
and it looks like a driver problem. It is not:

```bash
mokutil --sb-state; mokutil --list-new          # empty list = nothing queued
sudo mokutil --import /var/lib/shim-signed/mok/MOK.der   # set a one-time password
sudo reboot     # blue "Shim UEFI key management" screen -> press a key within 10 s
                # Enroll MOK -> Continue -> Yes -> password -> Reboot
nvidia-smi      # must list the RTX 5090
```
Details: `docs/notes/secureboot-mok-blocks-nvidia-dkms.md`.

## 3. Python + vLLM 0.29.0

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
uv python install 3.12
~/.local/bin/python3.12 -m venv ~/vllm-029-env
~/vllm-029-env/bin/pip install -U pip
~/vllm-029-env/bin/pip install "vllm==0.29.0"
# exact known-good set, if the resolver drifts:
#   ~/vllm-029-env/bin/pip install -r system/requirements/vllm-029-env.freeze.txt
```

### 3a. MANDATORY: make the pip CUDA toolchain coherent
A fresh install arrives mixed (nvcc/nvvm/crt 13.4.92 but runtime 13.0.96, nvrtc 13.0.88)
and FlashInfer's JIT then fails with *"CUDA compiler and CUDA toolkit headers are
incompatible"*. Align everything UP (13.0 does not work with this glibc):

```bash
~/vllm-029-env/bin/pip install --no-deps 'nvidia-cuda-nvcc==13.4.92' 'nvidia-nvvm==13.4.92' \
  'nvidia-cuda-crt==13.4.92' 'nvidia-cuda-runtime==13.4.92' 'nvidia-cuda-nvrtc==13.4.92'
# one-shot check - must print TOOLCHAIN OK:
N=~/vllm-029-env/lib/python3.12/site-packages/nvidia/cu13
printf '#include <cuda/std/__cccl/cuda_toolkit.h>\n__global__ void k(){}\n' > /tmp/g.cu
$N/bin/nvcc -c -gencode=arch=compute_120f,code=sm_120f -std=c++17 \
  -I ~/vllm-029-env/lib/python3.12/site-packages/flashinfer/data/cccl/libcudacxx/include \
  /tmp/g.cu -o /tmp/g.o && echo TOOLCHAIN OK
```
Details: `docs/notes/nightly-cuda-toolchain-must-be-coherent.md`.

## 4. Services and launchers

```bash
~/qwen-vllm/restore.sh          # installs systemd user units + desktop launchers
systemctl --user start qwen38   # first start downloads the model and JIT-compiles (~10+ min)
journalctl --user -u qwen38 -f
```
`qwen38.service` runs `serve-qwen38-029.sh`. The three things in that script you must
not "simplify away":
* `VLLM_KV_CACHE_LAYOUT=HND` - without it 0.29 on SM120 answers fluently WITHOUT SEEING
  THE PROMPT (`docs/notes/vllm-029-breaks-this-model.md`).
* `MAX_JOBS=4` - unbounded FlashInfer JIT host-OOMs a 29 GB box.
* `--gpu-memory-utilization 0.95`, `--max-num-batched-tokens 2048`, `--max-model-len 166400`
  are MEASURED, not guessed (0.97 starts fine, then OOMs on the first request).

## 5. Verify - a clean startup is NOT validation

```bash
~/qwen-vllm/test-verbatim.py 8000      # must print VERBATIM: 8/8
~/qwen-vllm/test-longctx.py 150000     # needle retrieval, must PASS
~/qwen-vllm/test-vision.py             # asks /v1/models which model is serving
```
Expected: ~6.46 GiB KV pool, "GPU KV cache size: ~173,000 tokens", ~650 MiB VRAM free.
Worth adding to the battery: parallel tool calls (two `get_weather` calls in one
turn) -- that is the whole reason production is 0.29 and not 0.22, and none of the
three gates above would notice it regressing.

## 6. OpenCode + the agent pipeline

```bash
curl -fsSL https://opencode.ai/install | bash
~/qwen-vllm/opencode-agents/install.sh /path/to/project home
cd /path/to/project && opencode        # Tab -> orchestrator
```
See `opencode-agents/README.md`. A working sample lives in
`opencode-agents/example-project/`.

## 7. Serving the whole home LAN

The launcher always passed `--host 0.0.0.0`, so the listener needs no change. What
actually has to happen (done 2026-09-19):

```bash
# 1. open the port to the LAN ONLY -- never 0.0.0.0/0 or ::/0
sudo ufw allow from 192.168.178.0/24 to any port 8000 proto tcp comment 'qwen38 vLLM LAN'
sudo ufw allow from fd34:2703:ce98::/64 to any port 8000 proto tcp comment 'qwen38 vLLM LAN v6'
# 2. let the --user unit live without a logged-in session, and start at boot
sudo loginctl enable-linger bezol
systemctl --user enable qwen38          # needs the [Install] section in the unit
```

Clients point at either address (avahi is running, so mDNS resolves the name):

```
http://omarchy.local:8000/v1      # preferred - survives a DHCP change
http://192.168.178.75:8000/v1     # this box, 2026-09-19
```

### `--host 0.0.0.0` is IPv4-only, and that half-breaks the hostname

`0.0.0.0` does NOT accept IPv6. avahi advertises this box's IPv6 addresses over
mDNS, so `omarchy.local` resolves to an IPv6 address FIRST and the connection is
refused; clients reach the server only because Happy Eyeballs falls back to IPv4.
That costs a delay on every connection and fails outright in clients that do not
fall back. Changed to **`--host ::`** -- `net.ipv6.bindv6only=0` here, so one
socket serves both families. Verify:

```
ss -tln | grep 8000            # must show  *:8000  (not 0.0.0.0:8000)
curl -m8 -o/dev/null -w'%{http_code} %{time_total}s\n' http://omarchy.local:8000/v1/models
```

Measured before/after: IPv6 `000` -> `200`, by-name now 0.10 s natively.

**SECURITY:** this box has a globally routable IPv6 address and IPv6 has NO NAT,
so ufw is the only thing making it private. Scope the v6 rule to the **ULA**
prefix (`fd34::/64`), which is unroutable from the internet -- not to the global
`2a00:` prefix, and never `::/0`. ufw defaults to deny-incoming on both families,
so binding `::` exposes nothing by itself.

Any OpenAI-compatible client works; model name is `unsloth/Qwen3.8-27B-NVFP4`.
**There is no authentication** -- fine on a trusted LAN, and the ufw rule is what
keeps it there. If that ever stops being true, add `--api-key <secret>` to the
serve script and set `OPENAI_API_KEY` on the clients.

### What multi-client actually buys you

`--max-num-seqs` was raised 1 -> 2. Cost: 2,797 tokens of context
(pool 6.46 -> 6.34 GiB, 173,391 -> 170,594), still clear of `--max-model-len 166400`.

**It does NOT give two large contexts at once, and that is not a tuning mistake --
it is arithmetic.** `max-num-seqs` caps how many sequences may be SCHEDULED; the KV
pool remains one shared budget. vLLM states the real limit at startup:

```
GPU KV cache size: 170,594 tokens, Maximum concurrency for 166,400 tokens per request: 1.03x
```

MEASURED 2026-09-19, two clients firing ~149K-token prompts simultaneously:

```
clientA:  46.4s  148,949 tokens  correct
clientB:  92.3s  148,921 tokens  correct
wall:     92.3s   preemption/recompute log lines: 0
```

So they **serialise cleanly**: both answers correct, wall clock is just 2x one
request, and the scheduler never preempted -- no recompute was wasted. That is the
good outcome; the risk with V1 preemption is that a preempted 150K prefill must be
redone from scratch. The win from seqs=2 is for the ordinary agentic mix of short
turns, not for two jumbo prompts.

Raising to 4 would cost ~456 MiB and require `--max-model-len` to drop by roughly
12,800 tokens. Re-run the gates if you do it.

## Arch / Omarchy deltas

Validated on **Omarchy** (kernel 7.2.5-3, gcc 16.2.1, glibc 2.44, driver 610.57.04,
60 GiB swap), 2026-09-19 -- same numbers as the Ubuntu box: pool 6.46 GiB,
173,391 tokens, verbatim 8/8, retrieval PASS at 148,949, vision PASS, parallel
tool calls OK. Warm restart 61 s.

**Steps that do NOT apply:**
* **Step 2 (Secure Boot / MOK)** -- Secure Boot was off on this install
  (`bootctl status` -> `Secure Boot: disabled`), so there is no MOK to enroll and
  no `mokutil` on the box. Check before assuming; if it is ON, the Ubuntu
  procedure still applies via `sbctl`, not `mokutil`.
* **Step 2 (driver install)** -- Omarchy ships the 610 driver already. Verify with
  `nvidia-smi` and only act if it is missing or < 610.
* **`apt`** -- `sudo pacman -S --needed <pkg>`. Nothing in step 0 is needed
  beyond what Omarchy already has (git, curl, base-devel).

**The one MANDATORY extra fix (step 3a companion):** the pip CUDA wheels are not
linkable on a box with no distro CUDA toolkit. FlashInfer compiles the NVFP4 GEMM
and then fails to **link** it with `ld: cannot find -lcudart`, ~4 min into startup.
`serve-qwen38-029.sh` now creates the two missing symlinks itself, so a clone of
this repo needs no manual action -- but if you write a new launcher, carry them
over. Full story: [`docs/notes/pip-cuda-is-not-self-sufficient.md`](docs/notes/pip-cuda-is-not-self-sufficient.md).

**gcc:** CUDA 13.4.92's guard is `#if __GNUC__ > 16`, so **gcc 16 is supported** --
no `gcc15` needed today. When Arch moves to **gcc 17 this becomes a hard stop**;
then `sudo pacman -S gcc15` and add `-ccbin /usr/bin/g++-15` via
`NVCC_PREPEND_FLAGS`. Verify with:

```bash
N=~/vllm-029-env/lib/python3.12/site-packages/nvidia/cu13
printf '#include <cuda_runtime.h>\n#include <vector>\n__global__ void k(){}\nint main(){cudaFree(0);}\n' > /tmp/g.cu
$N/bin/nvcc -gencode=arch=compute_120f,code=sm_120f -std=c++17 /tmp/g.cu -o /tmp/g.bin && echo HOST COMPILER OK
```

**Host RAM:** this install has **60 GiB of swap**, not 8 GiB, so the FlashInfer
JIT host-OOM described in `serve-qwen38-029.sh` has far more margin. `MAX_JOBS=4`
stays anyway -- it costs only cold-start latency
([[host-ram-is-the-other-ceiling]]).

**Paths:** the scripts, units and desktop launchers assume `~/qwen-vllm`. If you
clone elsewhere (e.g. `~/Documents/qwen-vllm`), symlink rather than edit paths:

```bash
ln -sfn ~/Documents/qwen-vllm ~/qwen-vllm
```

## What was tried and rejected (do not repeat)
All in `docs/notes/` - the short version:
* **fp8 KV is the keeper.** Native 262,144 does not fit at fp8 on 32 GB.
* **NVFP4 KV cache**: needs an unmerged fork port; corrupts intermittently at depth even
  on driver 610 (fails at 31K, passes at 218K). Dead end.
* **TurboQuant k8v4**: works only with `--enforce-eager` OR without MTP; MTP + CUDA graphs
  crashes on 0.22 and silently corrupts on 0.29.
* **vLLM 0.22** (old daily driver, `serve-qwen38.sh`, 190,400 ctx): its `qwen3_xml`
  streaming parser breaks PARALLEL tool calls -> OpenCode subagents die. Reason for 0.29.
* Large windows need `--kv-cache-memory-bytes` or vLLM gives the KV pool all VRAM and
  OOMs in activations mid-prefill.
* Short prompts passing proves nothing about a KV dtype - always run the depth sweep.
