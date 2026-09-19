#!/usr/bin/env python3
"""The two risks that decide whether this deployment is usable at all.

Everything else about the Windows path can be right and it is still worthless if
OpenCode cannot call tools, so these rank above the drafter benchmark.

GATE 1 -- TOOL CALLING AT DEPTH. `--jinja` is mandatory for Qwen3-family XML
tool calls, and llama.cpp issue #26530 reports exactly this failing on LARGE
prompts after the June 2026 AC-parser change (PR #24869): older builds fell back
to a JSON-array grammar that was followed more reliably. A toy one-line tool call
proves nothing -- agentic coding runs at depth, so the gate sweeps to ~100K and
requires a real `tool_calls` structure, not prose that mentions the tool.

GATE 2 -- THE PLAYWRIGHT MCP SHAPE. Images and tool calls in the SAME
conversation, which is not the same test as either alone: a screenshot comes
back as a tool result, has to be reasoned over, and must be followed by another
tool call. Upstream also injects a system message under `--jinja` when tools are
present ("Respond in JSON format, either with tool_call...") which is known to
upset some templates. Three steps, each gating the next:
    2a  read a passphrase rendered into a PNG            (vision works at all)
    2b  image + tools -> a tool call carrying that value (vision does not break tools)
    2c  feed the tool result back -> a SECOND tool call  (the loop actually continues)

Assumes a server is already running -- start it with serve-qwen38-windows.ps1 so
this exercises the real production config (vision on, DFlash, --jinja,
--image-max-tokens) rather than a hand-built one.

Usage: ./test-agentic.py [port]        # default 8000
"""
import base64
import io
import json
import sys
import urllib.request

PORT = sys.argv[1] if len(sys.argv) > 1 else "8000"
BASE = "http://127.0.0.1:%s" % PORT  # literal: localhost resolves to ::1 first here
SECRET = "MARBLE-SIPHON-4417"

SEARCH_TOOL = {
    "type": "function",
    "function": {
        "name": "search_codebase",
        "description": "Search the repository for a string and return matching files.",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "text to search for"},
                "max_results": {"type": "integer", "description": "cap on results"},
            },
            "required": ["query"],
        },
    },
}

RECORD_TOOL = {
    "type": "function",
    "function": {
        "name": "record_ui_check",
        "description": "Record the result of a visual UI check.",
        "parameters": {
            "type": "object",
            "properties": {
                "banner_code": {"type": "string", "description": "code shown on the banner"},
                "status": {"type": "string", "description": "pass or fail"},
            },
            "required": ["banner_code"],
        },
    },
}


def post(payload, timeout=1800):
    req = urllib.request.Request(
        BASE + "/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=timeout))


def filler(tokens):
    out, n, i = [], 0, 0
    while n < tokens * 4:
        line = "Record %05d: the quarterly reconciliation batch completed without error.\n" % i
        out.append(line)
        n += len(line)
        i += 1
    return "".join(out)


def tool_calls_of(resp):
    return resp["choices"][0]["message"].get("tool_calls") or []


def banner_png(text):
    """A screenshot stand-in: a wide banner with the code in large bold type.
    Shaped like a viewport capture so the image path sees realistic dimensions."""
    from PIL import Image, ImageDraw, ImageFont
    W, H = 1280, 320
    img = Image.new("RGB", (W, H), (24, 26, 32))
    d = ImageDraw.Draw(img)
    d.rectangle([40, 40, W - 40, H - 40], fill=(245, 245, 248))
    font = ImageFont.truetype(r"C:\Windows\Fonts\arialbd.ttf", 84)
    box = d.textbbox((0, 0), text, font=font)
    d.text(((W - (box[2] - box[0])) / 2, (H - (box[3] - box[1])) / 2 - 10),
           text, fill=(16, 16, 20), font=font)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()


def image_msg(url, text):
    return {"role": "user", "content": [
        {"type": "image_url", "image_url": {"url": url}},
        {"type": "text", "text": text},
    ]}


results = []


def gate(name, ok, detail=""):
    results.append((name, ok))
    print("  %-4s %-34s %s" % ("PASS" if ok else "FAIL", name, detail), flush=True)


model = json.load(urllib.request.urlopen(BASE + "/v1/models", timeout=30))["data"][0]["id"]
print("model: %s\n" % model)

# ---- GATE 1: tool calling at depth -----------------------------------------
print("GATE 1  tool calling at depth (issue #26530)")
for depth in (1024, 8192, 32768, 65536, 100000):
    pad = "" if depth <= 1024 else filler(depth) + "\n\n"
    r = post({
        "model": model,
        "messages": [{"role": "user", "content":
                      pad + "Use the search_codebase tool to find where the retry "
                            "limit is configured. Search for 'max_retries'."}],
        "tools": [SEARCH_TOOL],
        "tool_choice": "auto",
        "max_tokens": 700,
        "temperature": 0,
    })
    tc = tool_calls_of(r)
    used = r.get("usage", {}).get("prompt_tokens", 0)
    named = tc and tc[0]["function"]["name"] == "search_codebase"
    if named:
        try:
            args = json.loads(tc[0]["function"]["arguments"])
        except Exception:
            args = {}
        detail = "%6d tok -> %s(%s)" % (used, tc[0]["function"]["name"],
                                        args.get("query", "?"))
    else:
        body = (r["choices"][0]["message"].get("content") or "").strip().replace("\n", " ")
        detail = "%6d tok -> NO tool_calls; prose: %r" % (used, body[:70])
    gate("depth %d" % depth, bool(named), detail)

# ---- GATE 2: the Playwright shape ------------------------------------------
print("\nGATE 2  image + tool calls in one conversation")
url = banner_png(SECRET)

r = post({"model": model, "max_tokens": 400, "temperature": 0,
          "messages": [image_msg(url, "What code is printed on the banner? "
                                      "Reply with only that code.")]})
seen = (r["choices"][0]["message"].get("content") or "")
gate("2a vision reads the banner", SECRET in seen, repr(seen.strip()[:60]))

convo = [image_msg(url, "Read the code on the banner, then call record_ui_check "
                        "with it as banner_code and status 'pass'.")]
r = post({"model": model, "messages": convo, "tools": [RECORD_TOOL],
          "tool_choice": "auto", "max_tokens": 700, "temperature": 0})
tc = tool_calls_of(r)
arg_ok = False
if tc and tc[0]["function"]["name"] == "record_ui_check":
    try:
        arg_ok = SECRET in json.loads(tc[0]["function"]["arguments"]).get("banner_code", "")
    except Exception:
        arg_ok = False
gate("2b image -> tool call w/ value", bool(arg_ok),
     json.dumps(tc[0]["function"]["arguments"])[:70] if tc else "NO tool_calls")

if tc:
    convo.append(r["choices"][0]["message"])
    convo.append({"role": "tool", "tool_call_id": tc[0].get("id", "call_0"),
                  "name": "record_ui_check",
                  "content": json.dumps({"recorded": True, "id": 41})})
    convo.append({"role": "user", "content":
                  "The check was recorded. Now call record_ui_check once more "
                  "with the same banner_code and status 'done'."})
    r2 = post({"model": model, "messages": convo, "tools": [RECORD_TOOL],
               "tool_choice": "auto", "max_tokens": 700, "temperature": 0})
    tc2 = tool_calls_of(r2)
    ok2 = bool(tc2) and tc2[0]["function"]["name"] == "record_ui_check"
    gate("2c loop continues after result", ok2,
         json.dumps(tc2[0]["function"]["arguments"])[:70] if tc2 else "NO second tool_calls")
else:
    gate("2c loop continues after result", False, "skipped, 2b produced no tool call")

passed = sum(1 for _, ok in results if ok)
print("\n%d/%d gates passed" % (passed, len(results)))
sys.exit(0 if passed == len(results) else 1)
