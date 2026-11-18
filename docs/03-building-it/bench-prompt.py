#!/usr/bin/env python3
"""bench-prompt.py - measure Strata's prompt-reading (prefill) speed.

    python3 bench-prompt.py --target 8192
    python3 bench-prompt.py --target 32768 --max-tokens 16

The prompt is unique (a random nonce) so the KV cache is cold on every run.
The endpoint is the OpenAI-compatible one; any API key is accepted.
"""
import argparse
import json
import time
import urllib.error
import urllib.request
import uuid

PARA = "The quick brown fox jumps over the lazy dog. "


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8080/v1/chat/completions",
                    help="OpenAI-compatible endpoint (use http://<CT_IP>:<PORT>/v1/chat/completions remotely)")
    ap.add_argument("--model", default="strata")
    ap.add_argument("--target", type=int, default=8192, help="approximate prompt tokens")
    ap.add_argument("--max-tokens", type=int, default=128)
    ap.add_argument("--reasoning-budget", type=int, default=64)
    ap.add_argument("--api-key", default="not-needed")
    args = ap.parse_args()

    nonce = uuid.uuid4().hex
    nchars = args.target * 4
    text = (PARA * (nchars // len(PARA) + 1))[:nchars]
    prompt = f"[{nonce}] Read the text and reply with exactly DONE.\n\n{text}"

    body = json.dumps({
        "model": args.model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": args.max_tokens,
        "reasoning_budget_tokens": args.reasoning_budget,
        "temperature": 0,
    }).encode()
    req = urllib.request.Request(args.url, data=body, headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {args.api_key}",
    })

    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            d = json.load(r)
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read()[:500]}")
        return 1
    wall = time.time() - t0

    t = d.get("timings", {})
    m = d.get("choices", [{}])[0].get("message", {})
    print(f"target={args.target} prompt_n={t.get('prompt_n')} cache_n={t.get('cache_n')} "
          f"prompt_ms={t.get('prompt_ms', 0):.0f} prompt_tok/s={t.get('prompt_per_second', 0):.1f} "
          f"pred_n={t.get('predicted_n')} pred_tok/s={t.get('predicted_per_second')} wall={wall:.1f}s")
    print(f"content={m.get('content')!r} finish={d.get('choices',[{}])[0].get('finish_reason')}")
    print(f"usage={d.get('usage')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
