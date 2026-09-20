#!/usr/bin/env bash
# Stops ALL Qwen vLLM models (whichever is running) and frees GPU VRAM. Double-click target.
ALL="qwen-vllm qwen38"
notify() { command -v notify-send >/dev/null && notify-send -i media-playback-stop "Qwen vLLM" "$1" || true; }
echo "==================================================="
echo "  Stopping all Qwen vLLM models"
echo "==================================================="
systemctl --user stop $ALL 2>/dev/null
sleep 2
running=""
for s in $ALL; do systemctl --user is-active --quiet "$s" && running="$running $s"; done
if [ -n "$running" ]; then
  echo "⚠️  Still active:$running"
  systemctl --user status $running --no-pager | head -5
  notify "⚠️ Stop may have failed"
else
  echo "✅ All models stopped. GPU VRAM freed."
  notify "✅ Stopped — VRAM freed"
fi
read -rp "Press Enter to close."
