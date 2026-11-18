# Clients

The server exposes an OpenAI-compatible API and an Anthropic-compatible one. The
`model` field is cosmetic — any name is accepted — but the name reported by
`/health` is the natural choice.

## OpenAI-compatible

```sh
curl http://<CT_IP>:<PORT>/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer anything' \
  -d '{
        "model": "strata",
        "messages": [{"role": "user", "content": "Hello"}],
        "max_tokens": 256,
        "reasoning_budget_tokens": 128
      }'
```

The response has `choices[0].message.content` and a `timings` object with
`prompt_n`, `prompt_ms`, `prompt_per_second`, `predicted_n`,
`predicted_per_second`, `cache_n`, and the MTP draft counts.

| Endpoint | What |
|---|---|
| `GET /health` | loaded state, `max_context`, model, images |
| `GET /v1/models` | the model list |
| `GET /v1/status` | what the model is doing right now |
| `POST /v1/chat/completions` | OpenAI format |
| `POST /v1/messages` | Anthropic format |

Images: OpenAI `image_url` parts or Anthropic image blocks (base64, URL, or a
local path). JPEG/PNG/BMP/GIF go straight in; WebP/TIFF/AVIF are converted.

Any API key is accepted by default (`api_key: false`). Use a placeholder; do
not paste a real secret.

## OpenCode

The provider is client-side configuration. The reference setup:

```jsonc
"providers": {
  "strata-lan": {
    "name": "Strata LAN",
    "package": "@opencode/ai/providers/openai-compatible",
    "settings": {
      "baseURL": "http://<CT_IP>:<PORT>/v1",
      "apiKey": "not-needed",
    },
    "models": {
      "qwen38-iq3s": {
        "modelID": "qwen3.8-flash-next-iq3_s",
        "name": "Qwen3.8-Flash-Next IQ3_S (LAN)",
        "limit": { "context": 262144, "output": 8192 },
      },
    },
  },
},
```

- `providers` is plural in OpenCode V2; `package` selects the
  OpenAI-compatible runtime; `settings.apiKey` is a placeholder (the server
  ignores it when auth is off).
- `modelID` is what is sent upstream; `qwen38-iq3s` is the local alias.
- `limit.context` must match the server's `max_context`. `output` is the
  client's own cap; keep it below the context.
- If your model or quantization differs, rename the alias and keep `modelID`
  equal to what `/health` reports.

In the TUI press `/models` and pick the entry. From the shell:

```sh
opencode models | grep strata
opencode run -m strata-lan/qwen38-iq3s --agent plan "Say hello from the LAN."
```

### Tools

Native tool calling is limited in this engine. Chat and `plan` prompts work
well; the `build` agent may try tools and get an empty result. If that happens,
use `--agent plan` or a chat prompt, or disable tools for this model in the
client if it supports a capability flag.

### First request

The first request after a restart is cold: the expert cache fills and the answer
can be slower. Subsequent requests are faster. The steady-state decode depends
on the context size (see [Using it](../02-using-it.md)).

### `max_tokens`

A thinking model. With `max_tokens` below ~64 the whole budget can go to
thinking and `content` comes back `null`. Use 256+ or a
`reasoning_budget_tokens` that leaves room for the answer.

## Python

```python
import json, urllib.request

body = json.dumps({
    "model": "strata",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 256,
}).encode()
req = urllib.request.Request(
    "http://<CT_IP>:<PORT>/v1/chat/completions",
    data=body,
    headers={"Content-Type": "application/json", "Authorization": "Bearer x"},
)
with urllib.request.urlopen(req, timeout=300) as r:
    print(json.load(r)["choices"][0]["message"]["content"])
```

Set the timeout generously: a long prompt can take a minute to read before the
first token.

## Security

The endpoint is open on the LAN with no authentication by default. To lock it
down, add `--api-key <key>` to the run script and send the same key, or bind
`127.0.0.1` and put a reverse proxy with auth in front. Do not expose the port
to the internet.
