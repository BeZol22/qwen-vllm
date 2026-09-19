#!/usr/bin/env python3
"""Smoke-test: confirm the vLLM server actually SEES images (vision path live)."""
import base64, io, sys, urllib.request, json

from PIL import Image, ImageDraw  # provided by vllm's deps

# Draw an image with a secret word + number the model must read back.
SECRET = "PURPLE-7351"
img = Image.new("RGB", (480, 160), (245, 245, 245))
d = ImageDraw.Draw(img)
d.rectangle([10, 10, 470, 150], outline=(0, 0, 0), width=3)
d.text((40, 60), f"VISION CHECK: {SECRET}", fill=(20, 20, 20))
buf = io.BytesIO(); img.save(buf, format="PNG")
b64 = base64.b64encode(buf.getvalue()).decode()

# Ask the server which model it is actually serving, instead of hardcoding a name
# that goes stale every time the production model changes (it was still pointing at
# nvidia/Qwen3.6-35B-A3B-NVFP4 long after qwen38 became production).
MODEL = json.load(urllib.request.urlopen(
    "http://localhost:8000/v1/models", timeout=30))["data"][0]["id"]
print("Testing model:", MODEL)

payload = {
    "model": MODEL,
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": "Read the exact text shown in this image. Reply with only that text."},
            {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}"}},
        ],
    }],
    "max_tokens": 50, "temperature": 0,
    # Thinking mode is ON server-side for qwen38. Without this the reasoning tokens
    # consume the whole max_tokens budget and `content` comes back empty -- the test
    # would fail for a reason that has nothing to do with the vision path.
    "chat_template_kwargs": {"enable_thinking": False},
}
req = urllib.request.Request(
    "http://localhost:8000/v1/chat/completions",
    data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"},
)
out = json.load(urllib.request.urlopen(req, timeout=120))
answer = out["choices"][0]["message"]["content"] or ""
print("Model read:", repr(answer))
print("PASS ✅ vision works" if SECRET in answer else "FAIL ❌ secret not read back")
sys.exit(0 if SECRET in answer else 1)
