#Requires -Version 5.1
# Qwen3.8-27B + MTP + vision on llama.cpp -- NATIVE WINDOWS. No WSL, no Docker, no VM.
# Everything from unsloth: main GGUF, MTP draft head, vision projector.
#
# Counterpart to serve-qwen38-029.sh (vLLM 0.29 on Linux). Same model family, same
# card, different runtime and different quant. Full reasoning:
#   docs/notes/windows-native-llamacpp.md
#
# TWO THINGS THAT SURPRISE PEOPLE COMING FROM THE LINUX SIDE:
#   * This is NOT NVFP4. No trusted publisher ships an NVFP4 GGUF -- not unsloth,
#     not ggml-org, and Qwen publishes no GGUF at all. Community NVFP4 GGUFs exist
#     and were rejected on provenance. UD-Q5_K_M is 5.86 bits/weight, which is
#     ABOVE the ~5.6 bpw of those NVFP4 mixed quants, so this is a throughput
#     trade, not a quality one. MTP buys most of the throughput back.
#   * serve-llamacpp.sh says "No MTP (llama.cpp has none)". OUT OF DATE -- both
#     MTP and DFlash drafters exist for this model as separate files.
#   * The default drafter is DFLASH, not MTP. See the SPECULATIVE DECODING block.
#
# ---------------------------------------------------------------------------
# ONE-TIME SETUP
#
#   1. llama.cpp Windows CUDA 13.4 binaries (official release, no build needed):
#        https://github.com/ggml-org/llama.cpp/releases
#        asset: llama-b<NNNNN>-bin-win-cuda-13.4-x64.zip  (+ the matching cudart zip)
#      Unzip both into  D:\llama.cpp\  so that D:\llama.cpp\llama-server.exe exists.
#      PIN THE BUILD NUMBER. llama.cpp multimodal is explicitly experimental and
#      upstream warns breaking changes are expected -- treat it like the vLLM pin.
#
#   2. Four files, ~23 GB total, from TWO trusted publishers. D: has room; do NOT
#      put them on the WSL VHDX.
#        $D = 'D:\models\qwen3.8-27b'
#        # target model + vision + MTP fallback drafter -- unsloth
#        $U = 'unsloth/Qwen3.8-27B-GGUF'
#        huggingface-cli download $U Qwen3.8-27B-UD-Q5_K_M.gguf    --local-dir $D
#        huggingface-cli download $U mmproj-BF16.gguf              --local-dir $D
#        huggingface-cli download $U MTP/mtp-Qwen3.8-27B-Q4_0.gguf --local-dir $D
#        # default drafter -- ggml-org (the llama.cpp team's own org)
#        $G = 'ggml-org/Qwen3.8-27B-GGUF'
#        huggingface-cli download $G dflash-Qwen3.8-27B-Q4_0.gguf  --local-dir $D
#      The MTP path keeps its MTP\ subfolder under --local-dir; this script expects that.
#
#   3. LAN access for the MacBook. Two things, and the second is the one people miss:
#
#        # a) the rule, scoped to the LAN -- NEVER use -RemoteAddress Any
#        New-NetFirewallRule -DisplayName "llama-server LAN" -Direction Inbound `
#          -Action Allow -Protocol TCP -LocalPort 8000 `
#          -RemoteAddress 192.168.178.0/24 -Profile Private
#
#        # b) the Ethernet network must BE Private. On a Public profile Windows
#        #    drops inbound regardless of the rule above.
#        Get-NetConnectionProfile -InterfaceAlias Ethernet        # want: Private
#        Set-NetConnectionProfile -InterfaceAlias Ethernet -NetworkCategory Private
#
#      This box is 192.168.178.75/24 on "Ethernet". Adjust if the subnet moves.
#
#      NORDVPN: NordLynx (10.5.0.2/16) is installed. With the tunnel up, inbound LAN
#      connections to this box can be blackholed or the profile re-evaluated even
#      though the rule is correct. If the MacBook cannot reach port 8000, test with
#      NordVPN disconnected BEFORE touching the firewall rule.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

$LlamaBin = $env:QWEN_LLAMA_BIN
if (-not $LlamaBin) { $LlamaBin = 'D:\llama.cpp\llama-server.exe' }
$ModelDir = $env:QWEN_MODEL_DIR
if (-not $ModelDir) { $ModelDir = 'D:\models\qwen3.8-27b' }

# --- quant choice -------------------------------------------------------------
# UD-Q5_K_M (19.77 GB, 5.86 bpw) is the default: unsloth's imatrix-calibrated
# dynamic quant, comfortably above the precision this model runs at in production
# on the vLLM side, with VRAM left over for a long window. The ladder, if needed:
#     UD-Q4_K_M   16.46 GB  4.88 bpw   more KV room, lower precision
#     UD-Q4_K_XL  17.56 GB  5.20 bpw
#     UD-Q5_K_M   19.77 GB  5.86 bpw   <- default
#     UD-Q5_K_XL  20.88 GB  6.19 bpw
#     UD-Q6_K     21.98 GB  6.51 bpw   tight once MTP + mmproj are loaded
# Do NOT use plain Q4_0 (16.06 GB): legacy format, no imatrix, worse per bit than
# UD-Q4_K_M at essentially the same size, and it is NOT NVFP4 despite being 4-bit.
$Quant = $env:QWEN_QUANT
if (-not $Quant) { $Quant = 'UD-Q5_K_M' }

$Model   = Join-Path $ModelDir "Qwen3.8-27B-$Quant.gguf"
$DflashD = Join-Path $ModelDir 'dflash-Qwen3.8-27B-Q4_0.gguf'
$MtpD    = Join-Path $ModelDir 'MTP\mtp-Qwen3.8-27B-Q4_0.gguf'
$MmProj  = Join-Path $ModelDir 'mmproj-BF16.gguf'

if (-not (Test-Path $LlamaBin)) {
  throw "llama-server.exe not found at $LlamaBin -- see ONE-TIME SETUP step 1, or set QWEN_LLAMA_BIN"
}
if (-not (Test-Path $Model)) {
  throw "model not found at $Model -- see ONE-TIME SETUP step 2, or set QWEN_MODEL_DIR / QWEN_QUANT"
}

# --- SPECULATIVE DECODING: DFlash by default, MTP as fallback -----------------
# Both are drafters: a small model proposes tokens, the 27B verifies them in one
# forward pass, so greedy output is unchanged. They differ in HOW they propose.
#   MTP    Qwen's native next-n head (blk.64), sequential, shallow (n-max 2-3).
#   DFLASH a block-diffusion drafter (arXiv 2602.06036) -- predicts a whole block
#          in one pass, keeps top candidates per position, a selector traces one
#          coherent path. Drafts much deeper (n-max 5-7).
#
# DFLASH IS THE DEFAULT because it measured better on THIS model and on the same
# compute capability (12.0) this card is, over 100 LiveCodeBench prompts:
#     MTP    @ width 7   2.00x   48% acceptance   1.8 GB draft
#     DFlash @ width 7   2.26x   60% acceptance   1.1 GB draft
#     DFlash @ width 5   ~2.75x  70.4% acceptance          <- the tuned optimum
# and the gap WIDENS with context (1.59x @512 -> 2.62x @4K -> 3.55x @36.8K),
# which is the direction that matters for agentic coding at depth. There is also
# a known upstream weakness on exactly this architecture family: llama.cpp issue
# #23322, "Low MTP Draft Acceptance Rate with SWA/Hybrid Memory Models".
#
# Those figures are SPEED ONLY -- the study that produced them measured no
# accuracy at all. Run ./bench-drafters.py to reproduce both axes on this box
# before trusting either drafter; it checks greedy losslessness, which is the
# property speculative decoding is supposed to guarantee.
#
# QWEN_SPEC = dflash (default) | mtp | none
$Spec = $env:QWEN_SPEC
if (-not $Spec) { $Spec = 'dflash' }
$SpecArgs = @()
switch ($Spec) {
  'dflash' {
    if (-not (Test-Path $DflashD)) {
      throw "DFlash draft not found at $DflashD -- download it (ONE-TIME SETUP step 2), or set QWEN_SPEC=mtp"
    }
    # n-max 5 is the measured optimum. The benchmarked checkpoint enforces
    # dflash.block_size=8, hard-capping n-max at 7; ggml-org's file carries no
    # version in its name, so CHECK THE STARTUP LOG for the block size it reports
    # and do not assume 8.
    $SpecArgs = @('--model-draft', $DflashD, '--spec-type', 'draft-dflash', '--spec-draft-n-max', '5')
  }
  'mtp' {
    if (-not (Test-Path $MtpD)) {
      throw "MTP draft not found at $MtpD -- download it (ONE-TIME SETUP step 2), or set QWEN_SPEC=none"
    }
    # unsloth's own docs pair --model-draft with --mmproj, so MTP + vision is a
    # supported combination. n-max 2 is their recommended start; acceptance
    # falls off fast past 3.
    $SpecArgs = @('--model-draft', $MtpD, '--spec-type', 'draft-mtp', '--spec-draft-n-max', '2')
  }
  'none'   { $SpecArgs = @() }
  default  { throw "QWEN_SPEC must be dflash, mtp or none -- got '$Spec'" }
}

# --- VISION: ON by default ----------------------------------------------------
# Required, not a nice-to-have: web/UI work drives Playwright MCP, which feeds
# screenshots back as images. Qwen3-VL support incl. DeepStack is merged upstream
# (PR #16780). Opt out for a text-only session with  $env:QWEN_VISION = '0'.
$VisionArgs = @()
if ($env:QWEN_VISION -ne '0') {
  if (-not (Test-Path $MmProj)) {
    throw "vision projector not found at $MmProj -- download it (ONE-TIME SETUP step 2), or set QWEN_VISION=0"
  }
  # --image-max-tokens is the llama.cpp analogue of the vLLM side's
  # --mm-processor-kwargs '{"max_pixels": 1003520}'. WITHOUT IT A FULL-PAGE
  # PLAYWRIGHT SCREENSHOT CAN EAT THE CONTEXT WINDOW: those are viewport-width
  # but arbitrarily tall, so pixel count is unbounded in a way a photo is not.
  # 1280 tokens ~= the 1,003,520-pixel cap already in production on vLLM, and
  # still covers a 1280x720 viewport shot at roughly native resolution.
  # Raise only if the model starts missing genuine UI detail; every extra image
  # token is context the agent loses for code.
  # --image-min-tokens 1024 is NOT optional, and it is not symmetry with the cap.
  # llama.cpp warns at load: "Qwen-VL models require at minimum 1024 image tokens
  # to function correctly on grounding tasks". MEASURED 2026-09-19: without the
  # floor, a 1280x320 banner lands at ~400 image tokens (32x32 px/token) and the
  # model misread MARBLE-SIPHON-4417 as MARBLE-SIPHON-417 -- a dropped digit, on
  # an image a human reads instantly, and inconsistently (the same image read
  # correctly in the two tool-calling turns). Grounding is exactly what Playwright
  # work needs: finding a button, judging alignment. With the floor, 8/8.
  # The 1024-1280 band is deliberate: the floor keeps grounding reliable, the
  # ceiling still stops a full-page capture from eating the context window.
  $VisionArgs = @('--mmproj', $MmProj,
                  '--image-min-tokens', '1024',
                  '--image-max-tokens', '1280')
}

# --- context -----------------------------------------------------------------
# 131072 is a DELIBERATELY CONSERVATIVE START, not a measurement on this box.
# The arithmetic at the UD-Q5_K_M default, so the first probe is informed:
#   card                     31.84 GiB (32,607 MiB)
#   UD-Q5_K_M weights       ~18.41 GiB
#   DFlash drafter           ~2.66 GiB  (measured +2,720 MiB, file included)
#   BF16 mmproj              ~0.87 GiB
#   left for KV + linear-attn state + compute buffers      ~9.9 GiB
# (MTP instead of DFlash costs slightly more: ~3.28 GiB, 1.37 GB file plus
#  unsloth's stated ~2 GB of headroom.)
# KV geometry is the same hybrid as the vLLM side -- only 16 of 64 layers run full
# attention: 16 x 4 kv heads x 2 (K+V) x head_dim 256 = 32 KiB/token at 8-bit,
# which vLLM measured as 36.5 KiB/token once page padding is counted.
#   q8_0 KV:  131,072 tok ~= 4.6 GiB    <- fits with ~4.7 GiB to spare
#   f16  KV:  double that, ~9.1 GiB, consuming essentially the whole remainder.
# So q8_0 is not an optimisation here, it is what makes the window affordable.
# Raise --ctx-size only after the gates pass (test-verbatim.py, test-longctx.py,
# test-vision.py) -- a clean startup proves nothing, that lesson carries over
# from vLLM unchanged. Dropping MTP frees ~3.3 GiB if you want a much longer window.
$CtxSize = $env:QWEN_CTX
if (-not $CtxSize) { $CtxSize = '131072' }

# --- concurrency TRAP ---------------------------------------------------------
# llama-server DIVIDES --ctx-size among --parallel slots: --parallel 2 at 131072
# gives each agent 65,536, it does NOT serve two full contexts. The OpenCode
# pipeline has five agents (orchestrator/planner/coder/reviewer/refactorer), so
# this is a live decision, not a formality. Staying at 1 because the vLLM side
# already measured that two large contexts serialise anyway
# (docs/notes/lan-serving-and-concurrency.md) -- one deep context beats two shallow.
$Parallel = $env:QWEN_PARALLEL
if (-not $Parallel) { $Parallel = '1' }

# --- KV dtype -----------------------------------------------------------------
# q8_0, matching the fp8_e4m3 bit width already validated on the vLLM side
# (docs/notes/kv-dtype-decision-stay-on-fp8.md) and what serve-llamacpp.sh used.
# Do NOT drop to q4_0: llama.cpp's own function-calling docs warn that extreme KV
# quantisation significantly degrades TOOL CALLING, which is the point of this
# deployment.

$ArgList = @(
  '--model', $Model,
  '--alias', 'qwen3.8-27b',
  '--host', '0.0.0.0', '--port', '8000',
  '--n-gpu-layers', '99',
  # --load-mode none IS THE WHOLE ANSWER TO "Windows says 100% RAM used".
  # llama.cpp defaults to mmap, which leaves the entire 21.58 GB GGUF mapped and
  # RESIDENT in the process working set. Windows does not count those pages as
  # Available until it trims them, so the box reads as full -- Linux reports the
  # same pages under buff/cache and calls them available, which is why Ubuntu
  # never looked like this. MEASURED 2026-09-19, model fully on GPU either way:
  #   auto (mmap)  load 16s   WS 19.20 GB (0.69 private + 18.51 mapped)  avail  5.68 GB
  #   none         load  6s   WS  1.45 GB (1.36 private +  0.09 mapped)  avail 23.46 GB
  #   dio          load  6s   WS  1.45 GB (1.36 private +  0.09 mapped)  avail 23.47 GB
  # 17.75 GB back AND a faster load: with -ngl 99 every weight ends up in VRAM,
  # so the host mapping is pure overhead, and one sequential read beats
  # demand-paging the file in. 'dio' measured identical; 'none' is simpler.
  # This matters here specifically because the whole point of this deployment is
  # to leave 20+ GB of system RAM to Docker and the databases.
  '--load-mode', 'none',
  '--ctx-size', $CtxSize,
  '--parallel', $Parallel,
  '--flash-attn', 'on',
  '--cache-type-k', 'q8_0', '--cache-type-v', 'q8_0',
  # /metrics (Prometheus) + /slots, so draft acceptance is observable in
  # production and not only under bench-drafters.py.
  '--metrics',
  # MANDATORY for Qwen3-family XML tool calls. Without --jinja, OpenCode's tool
  # use silently degrades to prose. This is the most likely thing to break here.
  '--jinja',
  # PATCHED CHAT TEMPLATE, required for Claude Code against /v1/messages.
  # The template baked into the GGUF does this at line 110:
  #     {{- raise_exception('System message must be at the beginning.') }}
  # so ANY system-role message after the first turn is a hard 500:
  #     "Jinja Exception: System message must be at the beginning."
  # Claude Code injects system messages mid-conversation (its system-reminder
  # mechanism), so every such request fails. OpenCode never triggers it, which
  # is why this surfaced only when Claude Code was pointed at the box.
  # The patch renders that message as an ordinary ChatML system turn instead of
  # raising -- strictly more permissive, so nothing that worked before changes.
  # Verified after the swap: test-agentic.py still 8/8.
  '--chat-template-file', (Join-Path $PSScriptRoot 'system\chat-templates\qwen3.8-27b-midsystem.jinja'),
  # Qwen's recommended thinking-mode sampling, same values as the vLLM
  # --override-generation-config. Defaults only; OpenCode can override per request.
  '--temp', '1.0', '--top-p', '0.95', '--top-k', '20', '--repeat-penalty', '1.0'
) + $SpecArgs + $VisionArgs

$PerSlot = [int]$CtxSize / [int]$Parallel
$SpecState = @{
  'dflash' = 'DFlash (draft-dflash, n-max 5)'
  'mtp'    = 'MTP (draft-mtp, n-max 2)'
  'none'   = 'off'
}[$Spec]
$VisionState = 'on (image-max-tokens 1280)'
if ($env:QWEN_VISION -eq '0') { $VisionState = 'off (text-only)' }

Write-Host "llama-server : $LlamaBin"
Write-Host "model        : $Model"
Write-Host "context      : $CtxSize (q8_0 KV, $Parallel slot(s) -> $PerSlot per slot)"
Write-Host "drafter      : $SpecState"
Write-Host "vision       : $VisionState"
Write-Host "LAN endpoint : http://192.168.178.75:8000/v1   <- point OpenCode here"
Write-Host ''

# MANDATORY, and it cost a debugging round: llama-server writes its NORMAL logs
# to stderr, and PowerShell 5.1 wraps every stderr line from a native exe in a
# NativeCommandError ErrorRecord whenever the stream is redirected. With
# ErrorActionPreference still 'Stop', the FIRST ordinary log line ("llama_server:
# initializing ...") becomes a terminating error and kills this script before the
# model even loads -- exit 1, with the real cause buried in a PowerShell parser
# trace rather than in any llama.cpp output. It does not reproduce when running
# interactively with no redirection, so it surfaces exactly where it hurts: under
# a service wrapper (NSSM, Task Scheduler) or any `*>` / `2>&1` capture.
# All path validation above is done by now, so Stop has served its purpose.
$ErrorActionPreference = 'Continue'

& $LlamaBin @ArgList
exit $LASTEXITCODE
