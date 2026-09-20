# Qwen3.6-27B (NVFP4 + MTP + Vision) on vLLM — Fresh Ubuntu 26.04 LTS Setup

Run **Qwen3.6-27B** locally as an OpenAI-compatible server with:

- **NVFP4** weights (4-bit, Blackwell-native) — ~20 GB on disk, fits a 32 GB GPU with 128K context
- **MTP speculative decoding** (self-draft, ~1.4–2× faster generation)
- **Vision** (image input — e.g. Playwright screenshots)
- **Tool/function calling** for coding agents

Built and verified on: **RTX 5090 (Blackwell, SM120, 32 GB)**, Ubuntu 26.04, NVIDIA driver 595, CUDA 13.2 runtime.
Verified result: vision OK, MTP accept-length ~4.0, tool calls OK, ~137 tok/s single-stream, 128K context.

> ⚠️ **This is a bleeding-edge nightly stack.** The exact version strings below are pinned to **2026-05-31**. Newer nightlies generally work, but the three FlashInfer packages **must all be the same version** (see Step 5). If a pinned nightly has rotated off the index, use the newest available and keep them matched.

---

## 0. Hardware / OS requirements

| Requirement | Why |
|---|---|
| **NVIDIA Blackwell GPU** (RTX 50-series, RTX PRO 6000, B200, GB10…) with ≥ 32 GB | NVFP4 FP4 tensor cores are Blackwell-only (compute capability 12.0 / SM120) |
| Ubuntu 26.04 LTS | Reference platform |
| ~40 GB free disk | Model (~20 GB) + wheels/caches (~15 GB) |
| Internet | Downloads model + nightly wheels |

A non-Blackwell GPU (Ampere/Ada) **cannot** run this NVFP4 build — use an FP8 checkpoint instead.

---

## 1. NVIDIA driver (CUDA 13-capable)

A fresh Ubuntu 26.04 needs a Blackwell-capable proprietary driver (≥ 580; this guide used 595). **You do _not_ need a system CUDA toolkit** — the CUDA 13.3 compiler comes inside the Python venv (Step 6).

```bash
sudo ubuntu-drivers install        # auto-selects a recent driver
# …or pin one explicitly, e.g.:  sudo apt install -y nvidia-driver-595
sudo reboot
```

After reboot, confirm the GPU and that the driver advertises **CUDA Version: 13.x**:

```bash
nvidia-smi
nvidia-smi --query-gpu=name,compute_cap,memory.total --format=csv
# Expect e.g.  NVIDIA GeForce RTX 5090, 12.0, 32607 MiB
```

If `compute_cap` is `12.0`, you're good.

---

## 2. System packages

Minimal — most of the toolchain is installed into the venv via pip wheels.

```bash
sudo apt update
sudo apt install -y build-essential git curl
```

`build-essential` provides `gcc`/`g++`, which FlashInfer's JIT uses to compile the SM120 FP4 kernel on first run. (`ninja` is installed into the venv in Step 4, not via apt.)

---

## 3. Install `uv` and create a Python 3.12 venv

> Ubuntu 26.04 ships **Python 3.14**, which has **no vLLM wheels yet**. We use `uv` to provision a managed **Python 3.12**.

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.local/bin/env          # or restart your shell

uv venv --python 3.12 ~/vllm-env
```

All `uv pip install` commands below target this venv via `VIRTUAL_ENV=~/vllm-env`.

---

## 4. Install vLLM (CUDA 13.0 nightly) + ninja

```bash
VIRTUAL_ENV=~/vllm-env uv pip install -U vllm \
  --torch-backend=cu130 \
  --extra-index-url https://wheels.vllm.ai/nightly

VIRTUAL_ENV=~/vllm-env uv pip install ninja
```

This pulls `vllm 0.22.1rc1`, `torch 2.11.0+cu130`, and — crucially — the **CUDA 13.3 toolchain wheels** (`nvidia-cuda-nvcc 13.3`, cccl, crt, runtime) into the venv. Takes several minutes (multi-GB).

---

## 5. Align FlashInfer to one version (with the SM120 FP4 cubins)

The base install brings `flashinfer-python`/`-cubin` at `0.6.11.post2`, which **lacks** a prebuilt SM120 NVFP4 GEMM. Upgrade the **whole trio** to a matching nightly that ships it. `--no-deps` avoids a `cuda-tile`/torch resolver conflict.

```bash
VIRTUAL_ENV=~/vllm-env uv pip install --no-deps \
  "flashinfer-python==0.6.12.dev20260531" \
  "flashinfer-cubin==0.6.12.dev20260531" \
  "flashinfer-jit-cache==0.6.12.dev20260531" \
  --prerelease=allow \
  --index-url https://flashinfer.ai/whl/nightly/ \
  --extra-index-url https://flashinfer.ai/whl/nightly/cu130
```

**The golden rule:** `flashinfer-python`, `flashinfer-cubin`, and `flashinfer-jit-cache` must report the **same version**, or FlashInfer aborts at startup. Verify:

```bash
~/vllm-env/bin/python -c "import importlib.metadata as m; \
print([m.version(p) for p in ['flashinfer-python','flashinfer-cubin','flashinfer-jit-cache']])"
```

---

## 6. ⭐ The critical fix: point FlashInfer at the venv's CUDA 13 `nvcc`

FlashInfer JIT-compiles the **SM120 NVFP4 GEMM** on first run, which needs **`nvcc ≥ 12.8`**. Any system `nvcc` is usually older (12.x) and lacks SM120, causing:

```
RuntimeError: No supported CUDA architectures found for major versions [12].
```

The CUDA **13.3** toolchain is already in the venv (from Step 4). The launch script (Step 8) sets `CUDA_HOME` to it. Confirm it's there:

```bash
find ~/vllm-env -name nvcc -path '*cu13*'
# → ~/vllm-env/lib/python3.12/site-packages/nvidia/cu13/bin/nvcc
~/vllm-env/lib/python3.12/site-packages/nvidia/cu13/bin/nvcc --version   # release 13.3
```

If that path is missing, install the toolchain explicitly:
```bash
VIRTUAL_ENV=~/vllm-env uv pip install nvidia-cuda-nvcc-cu13 nvidia-cuda-cccl-cu13
```

---

## 7. Download the model

```bash
HF_HUB_ENABLE_HF_TRANSFER=0 \
  ~/vllm-env/bin/hf download Peutlefaire/Qwen3.6-27B-NVFP4
# or:  uvx --from huggingface_hub hf download Peutlefaire/Qwen3.6-27B-NVFP4
```

Downloads ~20 GB to `~/.cache/huggingface`. This checkpoint keeps the **vision tower** and the **MTP module** (`model_mtp.safetensors`) unquantized alongside the NVFP4 weights.

---

## 8. The launch script

Save as `~/qwen-vllm/serve-qwen.sh` and `chmod +x` it:

```bash
#!/usr/bin/env bash
# Qwen3.6-27B NVFP4 + MTP + Vision on a Blackwell GPU, native vLLM.
set -euo pipefail

export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"

# CRITICAL: FlashInfer JIT-compiles the SM120 NVFP4 GEMM and needs CUDA >= 12.8 nvcc.
# Use the CUDA 13.3 toolchain shipped inside the venv (auto-detected).
CUDA_HOME="$(dirname "$(dirname "$(find "$HOME/vllm-env" -name nvcc -path '*cu13*' -type f 2>/dev/null | head -1)")")"
export CUDA_HOME
export PATH="$CUDA_HOME/bin:$PATH"

# Reclaim fragmented VRAM so graph capture doesn't OOM (also enlarges usable KV cache).
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

source "$HOME/vllm-env/bin/activate"

exec vllm serve Peutlefaire/Qwen3.6-27B-NVFP4 \
  --host 0.0.0.0 --port 8000 \
  --tensor-parallel-size 1 \
  --safetensors-load-strategy prefetch \
  --performance-mode interactivity \
  --quantization compressed-tensors \
  --speculative-config '{"method":"mtp","num_speculative_tokens":3}' \
  --kv-cache-dtype fp8_e4m3 \
  --gpu-memory-utilization 0.90 \
  --max-model-len 131072 \
  --max-num-seqs 1 \
  --max-num-batched-tokens 8192 \
  --enable-prefix-caching \
  --limit-mm-per-prompt '{"image":2,"video":0}' \
  --mm-processor-kwargs '{"max_pixels": 1003520}' \
  --reasoning-parser qwen3 \
  --default-chat-template-kwargs '{"enable_thinking": false}' \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --trust-remote-code
```

**First launch is slow (~2–4 min): it JIT-compiles the FP4 kernel + captures CUDA graphs.** The result is cached under `~/.cache/vllm` and `~/.cache/flashinfer`, so later starts take ~2 min.

Quick foreground test:
```bash
mkdir -p ~/qwen-vllm && chmod +x ~/qwen-vllm/serve-qwen.sh
~/qwen-vllm/serve-qwen.sh
# wait for "Application startup complete", then in another terminal: curl localhost:8000/v1/models
```

### Why these flag values (tuning notes)
- `--max-model-len 131072` — 128K. The full KV pool here is ~186K tokens; capping a single request at 128K leaves headroom for **prefix caching** (faster repeat agent calls). Raising it toward ~180K trades that headroom for a longer single context.
- `--max-num-batched-tokens 8192` — caps the FP4 matmul's transient workspace to avoid OOM during graph capture. Still far larger than one screenshot (~2.5K image tokens).
- `--mm-processor-kwargs '{"max_pixels": 1003520}'` — caps per-image resolution; the biggest lever for latency/VRAM with full-page screenshots.
- `--gpu-memory-utilization 0.90` — **fixed; do not change.** This is the proven ceiling for this box: it works alongside a running desktop (~1 GB VRAM), and it is the same value every launcher here uses. If you hit OOM or the KV pool won't fit, lower `--max-model-len` / `--max-num-batched-tokens` instead of touching this.
- `--num_speculative_tokens 3` — MTP draft depth. Drop to 2 if acceptance falls on your workload.

---

## 9. Run it as a service (auto-start, auto-restart) — no sudo

Create `~/.config/systemd/user/qwen-vllm.service`:

```ini
[Unit]
Description=Qwen3.6-27B NVFP4 + MTP + Vision (vLLM)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env bash %h/qwen-vllm/serve-qwen.sh
Restart=on-failure
RestartSec=10
TimeoutStartSec=900
KillMode=mixed

[Install]
WantedBy=default.target
```

Enable it (linger lets it survive logout / start on boot):

```bash
loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user enable --now qwen-vllm.service
```

Manage:
```bash
systemctl --user status  qwen-vllm
systemctl --user restart qwen-vllm
systemctl --user stop    qwen-vllm
journalctl --user -u qwen-vllm -f          # live logs
```

---

## 10. Verify everything works

Wait for health, then test text, vision, and tools:

```bash
# health + model id
curl -s localhost:8000/v1/models

# vision smoke test (draws a PNG with a secret string, asks the model to read it)
~/vllm-env/bin/python - <<'PY'
import base64, io, json, urllib.request
from PIL import Image, ImageDraw
SECRET="PURPLE-7351"
img=Image.new("RGB",(480,160),(245,245,245)); d=ImageDraw.Draw(img)
d.rectangle([10,10,470,150],outline=(0,0,0),width=3); d.text((40,60),f"VISION CHECK: {SECRET}",fill=(0,0,0))
b=io.BytesIO(); img.save(b,format="PNG"); u="data:image/png;base64,"+base64.b64encode(b.getvalue()).decode()
p={"model":"Peutlefaire/Qwen3.6-27B-NVFP4","max_tokens":50,"temperature":0,
   "messages":[{"role":"user","content":[
     {"type":"text","text":"Read the exact text in this image. Reply with only that text."},
     {"type":"image_url","image_url":{"url":u}}]}]}
r=urllib.request.Request("http://localhost:8000/v1/chat/completions",
   data=json.dumps(p).encode(),headers={"Content-Type":"application/json"})
print(json.load(urllib.request.urlopen(r,timeout=120))["choices"][0]["message"]["content"])
PY
```

Confirm MTP is accepting in the logs:
```bash
journalctl --user -u qwen-vllm | grep -i "SpecDecoding metrics" | tail -1
# → Mean acceptance length: ~3–4, Avg Draft acceptance rate: high %
```

---

## 11. Connect from another machine (e.g. a MacBook)

The Blackwell GPU server must stay on this Linux host (NVFP4 can't run on Apple Silicon). Clients connect over the network.

**Option A — SSH tunnel (recommended, nothing exposed on the LAN):**
```bash
sudo systemctl enable --now ssh          # on the Linux host, once
# on the client:
ssh -L 8000:localhost:8000 <user>@<host-LAN-ip>
# then point tools at http://localhost:8000/v1
```

**Option B — direct LAN** (server already binds `0.0.0.0:8000`):
```bash
sudo ufw allow 8000/tcp                   # only if ufw is active
# client uses http://<host-LAN-ip>:8000/v1
```

Any OpenAI-compatible client works: base URL `…/v1`, model `Peutlefaire/Qwen3.6-27B-NVFP4`, any dummy API key.

---

## 12. Troubleshooting (the gotchas this guide solves)

| Symptom | Cause | Fix |
|---|---|---|
| `No module named 'vllm'` after install | System Python 3.14 has no wheels | Use the `uv` Python 3.12 venv (Step 3) |
| `No supported CUDA architectures found for major versions [12]` | FlashInfer using system `nvcc` < 12.8 | Set `CUDA_HOME` to the venv cu13 toolchain (Step 6 — already in the script) |
| `flashinfer-jit-cache version (…) does not match flashinfer version (…)` | Mixed FlashInfer versions | Make all three the same version (Step 5) |
| `torch.OutOfMemoryError` during startup/graph capture | KV + transient workspace overflow | `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` + lower `--max-num-batched-tokens` / `--max-model-len` (leave `--gpu-memory-utilization` at 0.90) |
| `KV cache … larger than available … max length is N` | `max-model-len` too big for VRAM | Lower `--max-model-len` (128K here). Do **not** raise `--gpu-memory-utilization` — 0.90 is the ceiling on this machine |
| Vision silently ignored | Using a `-Text-` checkpoint or `--language-model-only` | Use `Peutlefaire/Qwen3.6-27B-NVFP4`; don't pass `--language-model-only` |

---

## Stack summary (pinned 2026-05-31)

| Component | Version |
|---|---|
| OS / kernel | Ubuntu 26.04 LTS |
| GPU / arch | RTX 5090 / SM120 (compute 12.0) |
| NVIDIA driver / CUDA runtime | 595.71 / 13.2 |
| Python (venv) | 3.12 |
| vLLM | 0.22.1rc1 (cu130 nightly) |
| torch | 2.11.0+cu130 |
| FlashInfer (python/cubin/jit-cache) | 0.6.12.dev20260531 |
| CUDA toolchain (in venv) | nvcc 13.3 |
| Model | Peutlefaire/Qwen3.6-27B-NVFP4 |

---

## 13. Qwen3.8-27B NVFP4 (thinking mode) — second model, same desktop buttons

`unsloth/Qwen3.8-27B-NVFP4` runs alongside the 3.6 models. Only one may hold `:8000`
at a time; `start-model.sh` stops the others first.

| Piece | Path |
|---|---|
| Launcher | `serve-qwen38.sh` |
| Unit | `~/.config/systemd/user/qwen38.service` (not boot-enabled) |
| Desktop button | `~/Desktop/Start-Qwen38.desktop` (shows as **Start Qwen3.8 27B**) |
| Stop | the existing **Stop Qwen (any model)** button |

### How it differs from the 3.6 checkpoints

- **No `--quantization` flag.** This is `compressed-tensors` in `mixed-precision`
  format (NVFP4 MLPs + FP8 attention/`lm_head`, BF16 vision tower), auto-detected.
  Forcing `modelopt` explicitly fails here.
- **Hybrid architecture.** 64 layers: 48 gated-linear-attention + 16 full-attention
  (every 4th). Only those 16 hold a KV cache, but each concurrent sequence also
  reserves ~152 MiB of recurrent state.
- **Prefix caching is off**, and not by our choice — vLLM auto-disables it for this
  hybrid (`enable_prefix_caching=False` in the engine config). Do not pass
  `--enable-prefix-caching`.
- **MTP works.** `model_mtp.safetensors` ships in the repo; vLLM maps
  `method: "mtp"` to `Qwen3_5MTP`. Measured acceptance: **43–70%**, mean
  acceptance length 2.3–3.1.
- **Tool parser is `qwen3_xml`**, not `qwen3_coder` — the template emits
  `<tool_call><function=…><parameter=…>` XML.

### Thinking mode

Enabled via `--default-chat-template-kwargs '{"enable_thinking": true}'`.

The Qwen3.5 template puts `<think>` in the **prompt**, so only `</think>` appears in
the output; the `qwen3` reasoning parser knows this convention. Reasoning comes back
in the message field **`reasoning`** (this vLLM's name — not `reasoning_content`).

**Reasoning effort** — `chat_template_kwargs: {"reasoning_effort": "..."}`:

| Value | Behaviour |
|---|---|
| `xhigh` | **template default.** Injects "think carefully, validate assumptions…" |
| `medium` | No injected instruction |
| `low` | Injects "keep your thinking brief" |

⚠️ **Budget tokens generously.** At `xhigh` a 1200-token cap was consumed *entirely*
by reasoning with zero answer emitted. Even `medium` truncated at 2000. For agentic
coding use `max_tokens` ≥ 8000, or drop to `low`.

Disable per request: `chat_template_kwargs: {"enable_thinking": false}`.

### Sampling defaults

Qwen's recommended thinking-mode values are set server-side:
`temperature=1.0, top_p=0.95, top_k=20, repetition_penalty=1.0`.
`presence_penalty` is not readable from generation config by vLLM, and `min_p` is
ignored under speculative decoding — both recommended values (0.0) are already
vLLM's defaults. **These are defaults only**: a client sending its own
`temperature`/`top_p` overrides them.

### Measured numbers (RTX 5090, util 0.90)

| Metric | Value |
|---|---|
| Weights on disk | 23.4 GB (22.6 main + 0.85 MTP) |
| Available KV cache | 4.31 GiB |
| GPU KV cache size | 111,940 tokens |
| `--max-model-len` | **110592 (108K)** — 131072 needs 4.88 GiB and fails |
| VRAM in use when loaded | ~28.5 GiB / 31.8 GiB |
| Generation speed | ~98 tok/s single stream |
| Startup | ~156 s warm (~46 s of it compilation) |

`--max-num-seqs 1` — single-user agentic coding is a sequential loop, so extra
slots would only reserve per-sequence recurrent state.
