#!/usr/bin/env python3
"""Short verbatim battery -- the cheap gate that caught the nvfp4 corruption.

Eight ~30-token prompts asking for an EXACT copy of a hyphenated passphrase at
temperature 0. Hyphenated multi-segment strings are the sensitive probe: the
observed nvfp4 failure mode drops or mutates the MIDDLE segment, which a smoke
test or a one-word answer never reveals. Gate: 8/8, matching fp8.

Usage: ./test-verbatim.py [port]
"""
import json, re, sys, urllib.request

PORT = sys.argv[1] if len(sys.argv) > 1 else "8000"
BASE = f"http://localhost:{PORT}"
SECRETS = [
    "COBALT-LANTERN-3095", "QX7-VELLUM-8812", "ZEBRA-TUNDRA-8821",
    "GRANITE-LOCK-4471",   "MARBLE-SIPHON-4417", "INDIGO-FALCON-7263",
    "TOPAZ-BRIDGE-5529",   "ONYX-MERIDIAN-1184",
]

def post(path, payload, timeout=300):
    req = urllib.request.Request(BASE + path, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=timeout))

model = post("/v1/models", {}, 30) if False else json.load(
    urllib.request.urlopen(BASE + "/v1/models", timeout=30))["data"][0]["id"]

ok = 0
for s in SECRETS:
    r = post("/v1/chat/completions", {
        "model": model,
        "messages": [{"role": "user",
                      "content": f"Repeat this exactly, with no other words: {s}"}],
        "max_tokens": 600, "temperature": 0,
        "chat_template_kwargs": {"reasoning_effort": "low"},
    })
    msg = r["choices"][0]["message"]
    got = (msg.get("content") or "").strip()
    # tolerate surrounding quotes/punctuation, require the exact token sequence
    hit = s in got and not re.search(re.escape(s) + r"[-A-Z0-9]", got)
    ok += hit
    print(f"  {'PASS' if hit else 'FAIL'}  want {s:22s} got {got[:60]!r}")
print(f"\nVERBATIM: {ok}/8" + ("  <- matches fp8" if ok == 8 else "  <- CORRUPTED"))
sys.exit(0 if ok == 8 else 1)
