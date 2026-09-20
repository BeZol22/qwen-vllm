#!/usr/bin/env bash
# Measure what --kv-cache-dtype nvfp4 actually buys on this 5090.
#
# Method (the same one used to pin the fp8 ceiling at 190400): ask for the
# model's native 262144 and let vLLM do the arithmetic. Either it starts -- in
# which case full context is reached -- or it refuses and prints its own
# computed ceiling, which is the number to put in serve-qwen38-nightly.sh.
#
# Runs inside a systemd scope with MemoryMax so that a runaway FlashInfer JIT
# compile is contained to the scope instead of OOM-killing the machine (which is
# exactly what happened on 2026-09-18 17:50).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOG="${LOG:-/tmp/qwen-vllm/nvfp4-probe.log}"
mkdir -p "$(dirname "$LOG")"
: > "$LOG"

echo "Probing nvfp4 KV ceiling; log -> $LOG"

# 26G leaves the desktop room and still fits vLLM (~10.4G) + a 4-way JIT (~7G).
systemd-run --user --scope --quiet -p MemoryMax=26G -p MemorySwapMax=4G -- \
  env MAXLEN=262144 "$HERE"/serve-qwen38-nightly.sh >>"$LOG" 2>&1 &
RUNPID=$!

# Watch for a verdict: either the server binds, or vLLM reports the KV ceiling.
for i in $(seq 1 360); do
  if grep -qE "Application startup complete|Uvicorn running" "$LOG" 2>/dev/null; then
    echo "RESULT: SERVED at 262144 -- full context reached."
    break
  fi
  if grep -qE "larger than the maximum number of tokens|KV cache is not enough|No available memory for the cache blocks|Engine core initialization failed|torch\.OutOfMemoryError|ptxas fatal" "$LOG" 2>/dev/null; then
    echo "RESULT: refused -- see the extracted numbers below."
    break
  fi
  if pgrep -f "[v]llm-nightly-env/bin/vllm" >/dev/null 2>&1; then
    SEEN=1
  elif [ "${SEEN:-0}" = "1" ]; then
    echo "RESULT: engine exited."
    break
  fi
  sleep 10
done

echo
echo "===== key lines ====="
grep -iE "attention block size|mamba page|GPU KV cache size|maximum concurrency|estimated max|maximum number of tokens|available KV cache memory|Using .* backend|nvfp4|kv_cache_dtype|OutOfMemory|ValueError" "$LOG" | tail -40
echo
echo "(full log: $LOG)"
echo "Stop the server with: systemctl --user stop qwen38 ; pkill -f vllm-nightly-env"
