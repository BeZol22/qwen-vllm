#!/usr/bin/env python3
"""Needle-in-a-haystack at near-max context. The real validation for the nvfp4
KV path.

WHY A RETRIEVAL TEST AND NOT A SMOKE TEST: a clean startup proves nothing here
(the 0.97 gpu-memory-utilization lesson), and neither does a short reply. The two
open risks on the SM120 nvfp4 path both show up ONLY under depth:

  * KV layout / [data|scale] carve wrong -> the cache is silently corrupted, so
    short prompts still look fine while deep retrieval returns plausible garbage.
  * decode output-dtype path wrong (FA2 vs XQA, fp8 round-trip) -> subtly wrong
    logits rather than a crash.

So: bury a unique token deep in a long prompt, ask for it back at temperature 0,
and require an EXACT match. Anything less is not validation.

Usage:
  ./test-longctx.py               # ~95% of the server's own max_model_len
  ./test-longctx.py 190400        # target a specific prompt size
"""
import json
import sys
import urllib.request

BASE = "http://localhost:8000"
NEEDLE = "The courier's passphrase is MARBLE-SIPHON-4417."
QUESTION = "What is the courier's passphrase? Reply with only the passphrase."
SECRET = "MARBLE-SIPHON-4417"


def post(path: str, payload: dict, timeout: int = 1800) -> dict:
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    return json.load(urllib.request.urlopen(req, timeout=timeout))


def model_name() -> str:
    with urllib.request.urlopen(BASE + "/v1/models", timeout=30) as r:
        return json.load(r)["data"][0]["id"]


def max_len(model: str) -> int:
    with urllib.request.urlopen(BASE + "/v1/models", timeout=30) as r:
        d = json.load(r)["data"][0]
    return int(d.get("max_model_len") or 0)


def ntokens(model: str, text: str) -> int:
    return int(post("/tokenize", {"model": model, "prompt": text})["count"])


def main() -> int:
    model = model_name()
    served_max = max_len(model)
    target = int(sys.argv[1]) if len(sys.argv) > 1 else int(served_max * 0.95)
    print(f"model            : {model}")
    print(f"server max_model_len: {served_max or 'unreported'}")
    print(f"target prompt    : ~{target} tokens")

    # 1. Short sanity request first: separates "server is broken" from
    #    "long context is broken".
    short = post("/v1/chat/completions", {
        "model": model,
        "messages": [{"role": "user", "content": "Reply with exactly: OK"}],
        "max_tokens": 2000, "temperature": 0,
        "chat_template_kwargs": {"enable_thinking": False},
    })
    print(f"short reply      : {short['choices'][0]['message']['content']!r}")

    # 2. Build the haystack around a buried needle, calibrating iteratively.
    filler = ("Routine shipping manifest entry. Crates are logged by weight and "
              "destination, then re-checked at the depot. ")
    reserve = 512                      # question + template + answer headroom
    need = max(target - reserve, 1024)

    def build(count: int) -> tuple[str, int]:
        depth = max(int(count * 0.70), 1)
        body = "".join(
            f"[{i:06d}] " + (NEEDLE + " " if i == depth else filler)
            for i in range(count)
        )
        return (
            "Read the manifest below and answer the question at the end.\n\n"
            + body + "\n\n" + QUESTION
        ), depth

    # Seed from a 200-entry sample so the index prefix is included in the rate.
    sample, _ = build(200)
    per = ntokens(model, sample) / 200.0
    count = max(int(need / per), 1)
    prompt, depth = build(count)
    actual = ntokens(model, prompt)
    for _ in range(5):                 # converge to just UNDER the target
        if actual <= need:
            break
        count = max(int(count * (need / actual) * 0.98), 1)
        prompt, depth = build(count)
        actual = ntokens(model, prompt)
    print(f"actual prompt    : {actual} tokens (needle at ~{depth * 100 // count}% depth)")
    if served_max and actual > served_max:
        print(f"ABORT: prompt {actual} exceeds server max {served_max}; pass a smaller target.")
        return 2

    out = post("/v1/chat/completions", {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 4000, "temperature": 0,
        "chat_template_kwargs": {"enable_thinking": False},
    })
    msg = out["choices"][0]["message"]
    answer = (msg.get("content") or "").strip()
    usage = out.get("usage", {})
    print(f"prompt_tokens    : {usage.get('prompt_tokens')}")
    print(f"completion_tokens: {usage.get('completion_tokens')}")
    print(f"finish_reason    : {out['choices'][0].get('finish_reason')!r}")
    print(f"answer           : {answer[:300]!r}")

    if SECRET in answer:
        print(f"\nPASS ✅ retrieved the needle from {usage.get('prompt_tokens')} tokens.")
        return 0
    print(f"\nFAIL ❌ needle not returned. Expected {SECRET!r}.")
    print("   A short reply that works plus a deep retrieval that fails is the")
    print("   signature of a corrupted KV cache -- check the resolved KV layout")
    print("   (must be HND/LBHNC) before suspecting the model.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
