#!/usr/bin/env bash
# Correctness gate for the GLM-5.3-Flash TP4 endpoint.
#
# Do NOT declare the ring "serving" on a /v1/models 200 or a docker "Up".
# This runs the three checks that actually prove it works end to end:
#   1. Long-context needle (~30K prefill) — proves attention across the ring.
#   2. Tool-call — proves the glm47 tool-call parser is emitting proper calls.
#   3. Warm decode — one throwaway turn to fill the prefix cache, then measure t/s.
#
# Usage:  ./gate.sh
# Requires: curl, python3.
#
# ─────────────────────────────────────────────────────────────────────────────
# EDIT FOR YOUR SITE
# ─────────────────────────────────────────────────────────────────────────────

# Base URL of the HEAD node's OpenAI-compatible API.
# >>> set this to YOUR head node <<<
BASE_URL="http://10.0.0.1:8000/v1"
MODEL="glm-5.3-flash"

# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
pass=0; fail=0
ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "== 0. endpoint reachable =="
if curl -fsS --max-time 15 "$BASE_URL/models" | grep -q "$MODEL"; then
  ok "$MODEL present in /v1/models"
else
  bad "$MODEL not found in /v1/models (backend not registered yet?)"
  echo "aborting — the endpoint is not serving $MODEL."; exit 1
fi

echo "== 1. long-context needle (~30K prefill) =="
python3 - "$BASE_URL" "$MODEL" <<'PY'
import json, sys, urllib.request
base, model = sys.argv[1], sys.argv[2]
secret = "The vault passphrase is INDIGO-OTTER-4417."
# ~30K tokens of filler; a paragraph repeated, with the needle buried in the middle.
para = ("Routine status log entry: all subsystems nominal, no action required. " * 12 + "\n")
n = 900
filler = [para] * n
filler[n // 2] = filler[n // 2] + "\nIMPORTANT FACT: " + secret + "\n"
haystack = "".join(filler)
msg = ("Read the following log carefully.\n\n" + haystack +
       "\n\nQuestion: what exactly is the vault passphrase? Answer with only the passphrase.")
body = json.dumps({
    "model": model,
    "messages": [{"role": "user", "content": msg}],
    "max_tokens": 64, "temperature": 0,
    "chat_template_kwargs": {"enable_thinking": False},
}).encode()
req = urllib.request.Request(base + "/chat/completions", body,
                             {"Content-Type": "application/json"})
try:
    r = json.load(urllib.request.urlopen(req, timeout=600))
    out = r["choices"][0]["message"]["content"] or ""
    pt = r.get("usage", {}).get("prompt_tokens", "?")
    if "INDIGO-OTTER-4417" in out:
        print(f"  PASS: needle retrieved (prompt_tokens={pt}) -> {out.strip()[:80]!r}")
    else:
        print(f"  FAIL: needle NOT retrieved (prompt_tokens={pt}) -> {out.strip()[:120]!r}")
        sys.exit(2)
except Exception as e:
    print(f"  FAIL: needle request error: {e}"); sys.exit(2)
PY
if [ $? -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi

echo "== 2. tool-call (glm47 parser) =="
python3 - "$BASE_URL" "$MODEL" <<'PY'
import json, sys, urllib.request
base, model = sys.argv[1], sys.argv[2]
tools = [{
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city.",
        "parameters": {
            "type": "object",
            "properties": {"city": {"type": "string"}},
            "required": ["city"],
        },
    },
}]
body = json.dumps({
    "model": model,
    "messages": [{"role": "user", "content": "What's the weather in Bristol right now? Use the tool."}],
    "tools": tools, "tool_choice": "auto",
    "max_tokens": 256, "temperature": 0,
}).encode()
req = urllib.request.Request(base + "/chat/completions", body,
                             {"Content-Type": "application/json"})
try:
    r = json.load(urllib.request.urlopen(req, timeout=180))
    tc = r["choices"][0]["message"].get("tool_calls")
    if tc and tc[0]["function"]["name"] == "get_weather":
        args = tc[0]["function"]["arguments"]
        print(f"  PASS: tool_call emitted -> get_weather({args})")
    else:
        print(f"  FAIL: no proper tool_call in response: {r['choices'][0]['message']}")
        sys.exit(2)
except Exception as e:
    print(f"  FAIL: tool-call request error: {e}"); sys.exit(2)
PY
if [ $? -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi

echo "== 3. warm decode (throwaway turn, then measure) =="
python3 - "$BASE_URL" "$MODEL" <<'PY'
import json, sys, time, urllib.request
base, model = sys.argv[1], sys.argv[2]
def turn(prompt, max_tokens):
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens, "temperature": 0,
        "chat_template_kwargs": {"enable_thinking": False},
    }).encode()
    req = urllib.request.Request(base + "/chat/completions", body,
                                 {"Content-Type": "application/json"})
    t0 = time.time()
    r = json.load(urllib.request.urlopen(req, timeout=600))
    dt = time.time() - t0
    ct = r.get("usage", {}).get("completion_tokens", 0)
    return ct, dt
try:
    # Throwaway turn to warm the prefix cache; ignore its rate.
    turn("Write a short hello-world function in Python.", 128)
    # Measured turn.
    ct, dt = turn("Write a Python function that returns the nth Fibonacci number, "
                  "with a short docstring and a couple of examples.", 512)
    tps = ct / dt if dt > 0 else 0
    print(f"  warm decode: {ct} tokens in {dt:.1f}s = {tps:.1f} t/s")
    if tps >= 30:
        print("  PASS: decode in the expected band (reference warm ~48-51 t/s code).")
    else:
        print("  WARN: decode below 30 t/s — check MTU 9000 on both rails "
              "(1500 = ~2.7x slower, silent) and that the cache warmed.")
        sys.exit(3)
except Exception as e:
    print(f"  FAIL: decode request error: {e}"); sys.exit(2)
PY
rc=$?
if [ $rc -eq 0 ]; then pass=$((pass+1)); elif [ $rc -eq 3 ]; then echo "  (decode warn counted as soft-fail)"; fail=$((fail+1)); else fail=$((fail+1)); fi

echo
echo "== gate summary: $pass passed, $fail failed/warned =="
[ $fail -eq 0 ] && echo "GATE GREEN — safe to declare serving." \
                || { echo "GATE NOT GREEN — do NOT declare serving."; exit 1; }
