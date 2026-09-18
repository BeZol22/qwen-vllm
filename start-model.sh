#!/usr/bin/env bash
# Generic launcher (double-click target). Usage: start-model.sh <systemd-unit>
# Stops any OTHER Qwen model first (only one can bind :8000), then starts this one and waits.
SVC="$1"
ALL="qwen-vllm qwen-huihui qwen38"
case "$SVC" in
  qwen-vllm)   NAME="Qwen 35B-A3B (MoE)";;
  qwen-huihui) NAME="Qwen 27B abliterated";;
  qwen38)      NAME="Qwen3.8 27B (NVFP4)";;
  *)           NAME="$SVC";;
esac
notify() { command -v notify-send >/dev/null && notify-send -i media-playback-start "Qwen vLLM" "$1" || true; }

echo "==================================================="
echo "  Starting: $NAME"
echo "==================================================="

for s in $ALL; do
  [ "$s" = "$SVC" ] && continue
  if systemctl --user is-active --quiet "$s"; then
    echo "Stopping other model ($s) to free the GPU..."
    systemctl --user stop "$s"
  fi
done
sleep 2

if systemctl --user is-active --quiet "$SVC" && curl -s -m 2 http://localhost:8000/v1/models >/dev/null 2>&1; then
  echo "$NAME already running on :8000."
  notify "$NAME already running"
  read -rp "Press Enter to close."; exit 0
fi

notify "Starting $NAME… ~2-3 min"
systemctl --user start "$SVC"

echo -n "Loading (weights + CUDA graphs) "
for i in $(seq 1 80); do
  if curl -s -m 2 http://localhost:8000/v1/models >/dev/null 2>&1; then
    echo; echo "✅ READY — $NAME serving at http://localhost:8000/v1"
    notify "✅ $NAME ready on :8000"
    read -rp "Press Enter to close."; exit 0
  fi
  if ! systemctl --user is-active --quiet "$SVC"; then
    echo; echo "❌ $SVC stopped unexpectedly. Last 20 log lines:"
    journalctl --user -u "$SVC" -n 20 --no-pager
    notify "❌ $NAME failed — see terminal"
    read -rp "Press Enter to close."; exit 1
  fi
  echo -n "."; sleep 6
done
echo; echo "⚠️  Timed out. Tail: journalctl --user -u $SVC -f"
notify "⚠️ $NAME start timed out"
read -rp "Press Enter to close."; exit 1
