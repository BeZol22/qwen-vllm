#!/usr/bin/env bash
# Install the freshly built _C_stable_libtorch.abi3.so into the nightly env,
# keeping a one-time backup of the wheel's original.
#
# Safe to re-run. Restores with: install-nightly-sm120-kernel.sh --restore
set -euo pipefail

VENV="$HOME/vllm-nightly-env"
DEST="$VENV/lib/python3.12/site-packages/vllm/_C_stable_libtorch.abi3.so"
BACKUP="$DEST.wheel-orig"
SRC="${SRC:-}"

if [ "${1:-}" = "--restore" ]; then
  [ -f "$BACKUP" ] || { echo "No backup at $BACKUP"; exit 1; }
  cp -v "$BACKUP" "$DEST"
  echo "Restored the wheel's original extension."
  exit 0
fi

[ -n "$SRC" ] || { echo "set SRC to the patched source tree"; exit 1; }
BUILT="$(find "$SRC/build-sm120" -name "_C_stable_libtorch*.so" -print -quit)"
[ -n "$BUILT" ] || { echo "No built .so found under $SRC/build-sm120"; exit 1; }

if [ ! -f "$BACKUP" ]; then
  cp -v "$DEST" "$BACKUP"
  echo "Backed up the wheel's original (first install only)."
fi

# Sanity: the built object must actually carry the fix. The flag is a device-side
# bool derived from the arch, so check for the relaxed block_size message that
# only the patched source emits.
if [ "$(strings "$BUILT" | grep -c "scale-factor swizzle" || true)" = "0" ]; then
  echo "REFUSING: $BUILT does not contain the patched swizzle check."
  echo "Did the build pick up sm120-nvfp4-linear-v-scales.patch?"
  exit 1
fi

cp -v "$BUILT" "$DEST"
echo
echo "Installed. Now VALIDATE -- a clean startup is not validation:"
echo "  systemctl --user stop qwen38"
echo "  ./serve-qwen38-nightly.sh          # or with SPEC=0"
echo "  ./test-longctx.py 8000             # then the full run"
echo "Gate: the verbatim battery must be 8/8, matching fp8."
