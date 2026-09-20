# Rebuild from a freshly formatted box

> On **Arch / Omarchy**, read [Arch / Omarchy deltas](#arch--omarchy-deltas) FIRST:
> two steps below are no-ops there and one extra fix is mandatory.

Everything needed to get back to the validated state of **2026-09-19**:
vLLM **0.29.0** serving `unsloth/Qwen3.8-27B-NVFP4` on an RTX 5090 (32 GB, SM120),
fp8 KV cache, **166,400-token context**, prefix caching, MTP-3 + CUDA graphs, plus the
OpenCode agent pipeline. Reference system: Ubuntu 26.04, kernel 7.0.0-22, NVIDIA driver
**610.57.04**, Python 3.12.13 (uv-managed), iGPU drives the display (5090 headless).

## BEFORE YOU WIPE THE MACHINE

The repo is on GitHub and everything in it is reproducible. These are NOT, and are
gone for good once the disk is formatted:

| what | size | what you lose |
|---|---|---|
| `~/.local/share/open-webui/` | ~1 MB | **every chat and every user account.** Plain SQLite -- just copy the directory |
| `~/.webui_secret_key` | 32 B | the JWT signing key; lose it and every phone is logged out and must sign in again |

```bash
DEST=/run/media/$USER/<stick>/qwen-backup && mkdir -p "$DEST"
cp -a ~/.local/share/open-webui "$DEST"/
cp -a ~/.webui_secret_key       "$DEST"/
# and confirm the repo is really on the remote, not just committed locally:
git -C ~/qwen-vllm push
[ "$(git -C ~/qwen-vllm rev-parse HEAD)" = "$(git -C ~/qwen-vllm ls-remote origin main | cut -f1)" ] \
  && echo "REPO SAFE ON REMOTE" || echo "NOT PUSHED -- STOP"
```

Restore by copying both back **before** first starting open-webui, then run
`./configure-openwebui.py`. Skipping the backup does not cost you the setup, only
the history and the accounts: `configure-openwebui.py` rebuilds every setting and
people simply re-register.

Everything else below is only a download:

Not in git (too big) - re-download or back up to an external disk BEFORE formatting:

| what | size | how to get it back |
|---|---|---|
| `~/.cache/huggingface/hub/models--unsloth--Qwen3.8-27B-NVFP4` | 22 GB | auto-downloads on first start (needs the `\|\| true` fix, see [notes](docs/notes/cold-cache-breaks-the-launcher.md)) |
| `models--nvidia--Qwen3.6-35B-A3B-NVFP4` | 22 GB | only for the old `serve-qwen35.sh` |
| `~/vllm-029-env` | 8 GB | step 3 below |

## 0. Clone to `~/qwen-vllm`

Scripts and systemd units assume `~/qwen-vllm` (the units use systemd's `%h`).
The desktop launchers carry a `@REPO@` placeholder that `restore.sh` substitutes,
so they follow the repo wherever it lives:

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
# restore.sh already installed the GLOBAL config + agent team, so this is enough:
cd /any/project && opencode            # starts on the orchestrator agent
# per-project instead (e.g. at work, against a different server):
~/qwen-vllm/opencode-agents/install.sh /path/to/project home
```
`system/opencode-global/opencode.json` points OpenCode at `http://localhost:8000/v1`
and sets `default_agent: orchestrator`, so the model AND the five-agent team are
available in EVERY directory with no per-project setup. `restore.sh` will not
overwrite an existing `~/.config/opencode/opencode.json` -- merge by hand if you
have one (you need `provider`, `model`, `small_model`, `default_agent`).
See `opencode-agents/README.md`. A working sample lives in
`opencode-agents/example-project/`.

## 7. Serving the whole home LAN

The launcher always passed `--host 0.0.0.0`, so the listener needs no change. What
actually has to happen (done 2026-09-19):

```bash
# 1. open the port to the LAN ONLY -- never 0.0.0.0/0 or ::/0
sudo ufw allow from <LAN>/24 to any port 8000 proto tcp comment 'qwen38 vLLM LAN'
sudo ufw allow from <ULA>::/64 to any port 8000 proto tcp comment 'qwen38 vLLM LAN v6'
# 2. let the --user unit live without a logged-in session, and start at boot
sudo loginctl enable-linger "$USER"
systemctl --user enable qwen38          # needs the [Install] section in the unit
```

Clients point at either address (avahi is running, so mDNS resolves the name):

```
http://<hostname>.local:8000/v1   # preferred - survives a DHCP change
http://<LAN-IP>:8000/v1           # the box's own LAN address
```

### Keep `--host 0.0.0.0`: IPv4-only is the point, not a limitation

`0.0.0.0` does not accept IPv6. That was briefly "fixed" with `--host ::` and then
**reverted 2026-09-19**, because on this box IPv6 is a liability, not a feature:

* This machine has a **globally routable IPv6** (`2a00:...`) and **IPv6 has no
  NAT**. Binding `::` puts a listener directly on a public address, so
  "unreachable from the internet" becomes entirely dependent on ufw staying
  correct forever. Binding `0.0.0.0` means the only listener is on an RFC1918
  address behind NAT -- unreachable by construction, even if ufw is flushed.
* The cost of IPv4-only is **nothing measurable**. avahi advertises IPv6, so
  `<hostname>.local` resolves to IPv6 first, but with no v6 listener the kernel
  replies RST immediately and the client switches to IPv4 at once. MEASURED:

  ```
  200 in 0.127s     <- first call, mDNS lookup
  200 in 0.0015s    <- subsequent
  ```

  The earlier worry that non-fallback clients would break did not survive
  measurement; the refusal is instant, not a timeout.

**So: two layers, and the first one is structural.** (1) no listener on any
public address; (2) ufw `DEFAULT_INPUT_POLICY=DROP` with port 8000 allowed only
from `<LAN>/24` (and `<ULA>::/64`, now moot). Verify both:

```bash
ss -tln | grep 8000          # must be 0.0.0.0:8000 -- NOT *:8000 or [::]:8000
sudo ufw status verbose      # 8000 allowed ONLY from the LAN subnet
```

**You cannot test external reachability from this box.** ufw accepts everything on
`lo`, and traffic to your own address is routed over `lo`, so `curl` to your own
public IP returns 200 whether or not the internet can reach it. Test from a device
off the LAN (phone on mobile data), or trust the two structural facts above.

**Also check the router.** NAT is what protects IPv4, so confirm there is no port
forward for 8000 -- including one created automatically by **UPnP**.

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

## 8. Phones and tablets: Open WebUI

vLLM serves a raw API, which is useless on a phone. `serve-openwebui.sh` +
`open-webui.service` put a chat UI in front of it, so any device on the LAN just
opens a URL in Safari. Installed 2026-09-19, Open WebUI 0.11.3.

```bash
~/.local/bin/python3.12 -m venv ~/open-webui-env
~/open-webui-env/bin/pip install open-webui          # ~7.6 GB, bundles its own ML stack
~/qwen-vllm/restore.sh                               # installs open-webui.service too
sudo ufw allow from <LAN>/24 to any port 3000 proto tcp comment 'open-webui LAN'
systemctl --user enable --now open-webui
```

Then from any iPhone/iPad/Mac on the LAN:

```
http://<hostname>.local:3000        # iOS resolves .local via Bonjour natively
http://<LAN-IP>:3000
```

Safari -> Share -> **Add to Home Screen** makes it behave like an app. The FIRST
account created becomes the admin; everyone else signs up and gets their own
chat history.

**Settings that are deliberate, not defaults:**
* `ENABLE_OLLAMA_API=False` -- Open WebUI probes for Ollama on :11434 otherwise
  and every page load eats that timeout.
* `OPENAI_API_BASE_URL=http://127.0.0.1:8000/v1` -- it is a CLIENT of qwen38, over
  loopback, so this never touches the LAN rules.
* `HOST=0.0.0.0` -- IPv4 only, same reasoning as qwen38 (see "Keep `--host
  0.0.0.0`"). Do not switch to `::`.
* `WEBUI_AUTH=True` -- **do not** set False to skip the login screen: it makes
  every visitor the SAME user, so all phones would share one conversation history.
* `DATA_DIR=~/.local/share/open-webui` -- the SQLite DB and uploads live outside
  the venv so reinstalling cannot destroy them. **Back this up**, it is the chat
  history; it is not in git.

**Measured:** 2.30 GiB RSS and **zero VRAM** -- `nvidia-smi` shows only
`VLLM::EngineCore`, so the UI never competes with the model for the 5090.

**Web search is ON via DuckDuckGo** (no API key). The env vars in
`serve-openwebui.sh` only take effect on a FRESH install: `DEFAULT_CONFIG` is
*seeded* into `webui.db` on first boot and the DB wins from then on, silently. On
an existing install change it in Admin Panel -> Settings -> Web Search, or edit
the `config` table directly. Details in
[`docs/notes/open-webui-phone-frontend.md`](docs/notes/open-webui-phone-frontend.md).

**Other phones cannot sign up by default.** After the first admin exists,
`ui.enable_signup` is false; turn it on in Admin Panel -> Settings -> General, and
note `ui.default_user_role=pending` means the admin approves each new account.

**Privacy note:** inference is 100% local, but Open WebUI itself makes OUTBOUND
calls to huggingface.co on first run to fetch its RAG embedding model
(`all-MiniLM-L6-v2`). That is outbound only and does not make anything reachable
from the internet; the inbound rules are unchanged.

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

**Paths:** the scripts and units assume `~/qwen-vllm` (the desktop launchers
follow the repo on their own -- `restore.sh` fills in their `@REPO@`). If you
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
