#!/usr/bin/env python3
"""DFlash vs MTP vs no drafter -- speed AND accuracy, measured on THIS box.

WHY THIS EXISTS: the published DFlash-beats-MTP numbers (2.26x vs 2.00x, 60% vs
48% acceptance, on an RTX PRO 6000 Blackwell) say so themselves -- "No accuracy
measurement at all. Every number above is speed." Those figures chose the default
in serve-qwen38-windows.ps1, so they need reproducing here, on this card, with
the accuracy axis the original study skipped.

THE ACCURACY TEST IS LOSSLESSNESS, and that is the right test rather than a
benchmark score: speculative decoding does not change what the target model
outputs. The drafter only proposes; the 27B verifies every token. So at
temperature 0 the output with a drafter should match the output without one.
Anything else means the drafter path is buggy, not "slightly worse".

  CAVEAT, stated because the gate would otherwise over-claim: exact equality is
  the EXPECTATION, not a hard guarantee. Verification runs the target at
  different batch shapes than plain decoding, and float non-associativity can
  flip a near-tie logit. So this reports WHERE divergence starts:
     identical              -> PASS
     diverges late (>80%)   -> WARN, plausibly float noise
     diverges early / fully -> FAIL, treat as a real bug

It also runs the 8-passphrase verbatim battery from test-verbatim.py per mode,
because losslessness against a broken baseline would still pass.

Each mode gets its own server process, launched directly (not via the .ps1) so
the drafter flags are the ONLY thing that varies between runs. Everything else
mirrors the launcher's defaults.

Usage:
  ./bench-drafters.py                      # none, mtp, dflash
  ./bench-drafters.py --modes dflash,mtp   # subset
  ./bench-drafters.py --sweep 3,5,7        # n-max sweep for dflash
  ./bench-drafters.py --port 8001          # default; avoids the :8000 server
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

# --- configuration, mirroring serve-qwen38-windows.ps1 -----------------------
LLAMA_BIN = os.environ.get("QWEN_LLAMA_BIN", r"D:\llama.cpp\llama-server.exe")
MODEL_DIR = os.environ.get("QWEN_MODEL_DIR", r"D:\models\qwen3.8-27b")
QUANT = os.environ.get("QWEN_QUANT", "UD-Q5_K_M")
CTX = os.environ.get("QWEN_CTX", "131072")

MODEL = os.path.join(MODEL_DIR, "Qwen3.8-27B-%s.gguf" % QUANT)
DFLASH = os.path.join(MODEL_DIR, "dflash-Qwen3.8-27B-Q4_0.gguf")
MTP = os.path.join(MODEL_DIR, "MTP", "mtp-Qwen3.8-27B-Q4_0.gguf")

# Vision is left OFF for the benchmark: the projector costs VRAM and contributes
# nothing to a text decode-rate measurement. Production runs with it; the KV
# headroom note in the launcher already accounts for that difference.
BASE_ARGS = [
    "--model", MODEL,
    "--n-gpu-layers", "99",
    "--ctx-size", CTX,
    "--parallel", "1",
    "--flash-attn", "on",
    "--cache-type-k", "q8_0", "--cache-type-v", "q8_0",
    "--metrics",
    "--jinja",
    "--temp", "0",
]

SPEC_ARGS = {
    "none": [],
    "mtp": ["--model-draft", MTP, "--spec-type", "draft-mtp", "--spec-draft-n-max", "2"],
    "dflash": ["--model-draft", DFLASH, "--spec-type", "draft-dflash", "--spec-draft-n-max", "5"],
}

# Depth tiers. The published DFlash advantage GROWS with context
# (1.59x @512 -> 2.62x @4K -> 3.55x @36.8K), so a single-depth benchmark would
# understate it. Actual depth is read back from usage.prompt_tokens, never assumed.
DEPTHS = [512, 4096, 32768]

TASK = (
    "Write a Python function `merge_intervals(intervals)` that merges overlapping "
    "closed intervals and returns them sorted by start. Include a short docstring "
    "and handle the empty-input case. Then explain the time complexity."
)

SECRETS = [
    "COBALT-LANTERN-3095", "QX7-VELLUM-8812", "ZEBRA-TUNDRA-8821",
    "GRANITE-LOCK-4471", "MARBLE-SIPHON-4417", "INDIGO-FALCON-7263",
    "TOPAZ-BRIDGE-5529", "ONYX-MERIDIAN-1184",
]


def filler(target_tokens):
    """Deterministic padding. ~4 chars/token is a rough guide only -- the real
    depth comes back in usage.prompt_tokens and that is what gets reported."""
    lines, n = [], 0
    i = 0
    while n < target_tokens * 4:
        line = "Record %05d: the quarterly reconciliation batch completed without error.\n" % i
        lines.append(line)
        n += len(line)
        i += 1
    return "".join(lines)


class Server(object):
    def __init__(self, mode, port, extra=None, log_dir="."):
        self.mode, self.port = mode, port
        self.args = [LLAMA_BIN] + BASE_ARGS + ["--port", str(port)]
        self.args += extra if extra is not None else SPEC_ARGS[mode]
        self.log_path = os.path.join(log_dir, "bench-%s.log" % mode)
        self.proc = None

    def __enter__(self):
        self.log = open(self.log_path, "wb")
        self.proc = subprocess.Popen(self.args, stdout=self.log,
                                     stderr=subprocess.STDOUT)
        deadline = time.time() + 600
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError("llama-server exited during load (%s) -- see %s"
                                   % (self.proc.returncode, self.log_path))
            try:
                urllib.request.urlopen("http://localhost:%d/health" % self.port, timeout=2)
                return self
            except Exception:
                time.sleep(2)
        raise RuntimeError("server did not become healthy in 600s -- see %s" % self.log_path)

    def __exit__(self, *exc):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=60)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=30)
        self.log.close()
        time.sleep(3)  # let the driver release VRAM before the next mode loads
        return False


def chat(port, content, max_tokens):
    payload = {
        "model": "bench",
        "messages": [{"role": "user", "content": content}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "seed": 1234,
        "timings_per_token": True,
    }
    req = urllib.request.Request(
        "http://localhost:%d/v1/chat/completions" % port,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    t0 = time.time()
    r = json.load(urllib.request.urlopen(req, timeout=3600))
    wall = time.time() - t0

    msg = r["choices"][0]["message"]
    text = (msg.get("reasoning_content") or "") + (msg.get("content") or "")
    usage = r.get("usage", {})
    out_tokens = usage.get("completion_tokens", 0)

    # timings may sit at the top level or under __verbose depending on build;
    # wall-clock is the fallback that always works.
    t = r.get("timings") or (r.get("__verbose") or {}).get("timings") or {}
    tps = t.get("predicted_per_second")
    if not tps:
        tps = (out_tokens / wall) if wall > 0 else 0.0
    return {
        "text": text,
        "prompt_tokens": usage.get("prompt_tokens", 0),
        "out_tokens": out_tokens,
        "tps": tps,
        "ttft_ms": t.get("prompt_ms"),
        "draft_n": t.get("draft_n"),
        "draft_acc": t.get("draft_n_accepted"),
        "wall": wall,
    }


def first_divergence(a, b):
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return i
    return None if len(a) == len(b) else n


def run_mode(mode, port, extra=None):
    print("\n=== %s ===" % mode, flush=True)
    out = {"speed": [], "verbatim": 0, "texts": {}}
    with Server(mode, port, extra) as _:
        for d in DEPTHS:
            prompt = TASK if d <= 512 else filler(d) + "\n\n" + TASK
            r = chat(port, prompt, 400)
            out["speed"].append((d, r))
            out["texts"][d] = r["text"]
            acc = ""
            if r["draft_n"]:
                acc = "  draft %d/%d = %.1f%%" % (
                    r["draft_acc"] or 0, r["draft_n"],
                    100.0 * (r["draft_acc"] or 0) / r["draft_n"])
            print("  depth %6d (actual %6d)  %7.2f tok/s  %4d out%s"
                  % (d, r["prompt_tokens"], r["tps"], r["out_tokens"], acc), flush=True)

        for s in SECRETS:
            r = chat(port, "Repeat this exactly, with no other words: %s" % s, 600)
            if s in r["text"]:
                out["verbatim"] += 1
        print("  verbatim battery: %d/8" % out["verbatim"], flush=True)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--modes", default="none,mtp,dflash")
    ap.add_argument("--sweep", default="", help="comma-separated n-max values for dflash")
    ap.add_argument("--port", type=int, default=8001)
    a = ap.parse_args()

    for p in (LLAMA_BIN, MODEL):
        if not os.path.exists(p):
            sys.exit("missing: %s" % p)

    results = {}
    modes = [m.strip() for m in a.modes.split(",") if m.strip()]
    for m in modes:
        if m not in SPEC_ARGS:
            sys.exit("unknown mode %r" % m)
        if m != "none" and not os.path.exists(MTP if m == "mtp" else DFLASH):
            sys.exit("missing drafter for mode %r" % m)
        results[m] = run_mode(m, a.port)

    for n in [x.strip() for x in a.sweep.split(",") if x.strip()]:
        label = "dflash-n%s" % n
        extra = ["--model-draft", DFLASH, "--spec-type", "draft-dflash",
                 "--spec-draft-n-max", n]
        results[label] = run_mode(label, a.port, extra)

    # ---- speed table --------------------------------------------------------
    print("\n" + "=" * 72)
    print("SPEED  (tok/s decode, and speedup vs 'none' at the same depth)")
    print("=" * 72)
    base = results.get("none")
    header = "%-14s" % "depth" + "".join("%18s" % m for m in results)
    print(header)
    for i, d in enumerate(DEPTHS):
        row = "%-14d" % d
        for m in results:
            r = results[m]["speed"][i][1]
            cell = "%.1f" % r["tps"]
            if base and base["speed"][i][1]["tps"]:
                cell += " (%.2fx)" % (r["tps"] / base["speed"][i][1]["tps"])
            row += "%18s" % cell
        print(row)

    print("\nacceptance   " + "".join(
        "%18s" % (("%.1f%%" % (100.0 * sum(s[1]["draft_acc"] or 0 for s in results[m]["speed"])
                               / max(1, sum(s[1]["draft_n"] or 0 for s in results[m]["speed"]))))
                  if any(s[1]["draft_n"] for s in results[m]["speed"]) else "-")
        for m in results))

    # ---- accuracy table -----------------------------------------------------
    print("\n" + "=" * 72)
    print("ACCURACY")
    print("=" * 72)
    print("%-14s %-10s %s" % ("mode", "verbatim", "greedy losslessness vs 'none'"))
    failed = False
    for m in results:
        v = "%d/8" % results[m]["verbatim"]
        if results[m]["verbatim"] < 8:
            failed = True
        if m == "none" or not base:
            verdict = "(baseline)" if m == "none" else "(no baseline run)"
        else:
            worst, notes = None, []
            for d in DEPTHS:
                x, y = base["texts"][d], results[m]["texts"][d]
                i = first_divergence(x, y)
                if i is None:
                    continue
                frac = i / float(max(1, len(x)))
                notes.append("d%d@%d(%.0f%%)" % (d, i, 100 * frac))
                worst = frac if worst is None else min(worst, frac)
            if worst is None:
                verdict = "PASS  identical at all depths"
            elif worst > 0.8:
                verdict = "WARN  late divergence, plausibly float noise: " + " ".join(notes)
            else:
                verdict = "FAIL  early divergence: " + " ".join(notes)
                failed = True
        print("%-14s %-10s %s" % (m, v, verdict))

    print("\nlogs: bench-<mode>.log   (check the DFlash block size reported at load)")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
