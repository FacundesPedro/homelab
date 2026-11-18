# Using it

The examples use `<CT_IP>` and `<CTID>`. In the reference deployment those are
`192.168.3.66` and `121`, and the port is `8080`; substitute your own
(see [README — Conventions](README.md#conventions)).

## Open the chat page

In a browser on the same network:

```
http://<CT_IP>:<PORT>
```

The first answer after a restart is slower while the model's expert cache fills.
After a few messages it settles at the model's normal speed. That speed depends
on the context size and on how much of the model fits on the card:

| Context | Prompt reading | Answer |
|---|---|---|
| 128K, int8 KV | ~600 tok/s | ~45–54 tok/s (reference) |
| 200K, int8 KV | ~570–595 tok/s | ~30–40 tok/s |
| 256K, int8 KV | ~550–572 tok/s | ~30–35 tok/s |

A larger context leaves less VRAM for the expert cache and is slower. Pick the
smallest context that holds your real conversations.

## Use it from OpenCode

Point OpenCode at the OpenAI-compatible endpoint. The reference configuration
uses provider `strata-lan` and model alias `qwen38-iq3s`:

| | |
|---|---|
| Provider | `strata-lan` |
| Model | `strata-lan/qwen38-iq3s` (sends the model name reported by `/health`) |
| Endpoint | `http://<CT_IP>:<PORT>/v1` |
| Context | the server's `max_context` |

In the TUI, press `/models` and pick the Strata entry. From the shell:

```sh
opencode run -m strata-lan/qwen38-iq3s "Explain what a container is in one sentence."
```

The provider block is in `~/.config/opencode/opencode.jsonc`; the exact snippet
is in [40 — Clients](03-building-it/40-clients.md).

## Use the API

OpenAI-compatible:

```sh
curl http://<CT_IP>:<PORT>/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer anything' \
  -d '{"model":"strata","messages":[{"role":"user","content":"Hello"}],"max_tokens":256}'
```

Anthropic-compatible: `POST /v1/messages`.

- **Any API key is accepted** by default (`api_key: false`).
- The `model` field is cosmetic; any name works. `/health` reports the real one.
- `GET /health` shows the loaded state and the context; `GET /v1/models` lists
  the model.
- Images are accepted as `image_url` parts (OpenAI) or image blocks (Anthropic).
  The image encoder runs on the CPU by default.

### A note on `max_tokens`

These models are usually *thinking* models. If `max_tokens` is small (below
~64), the model can spend the whole budget thinking and return `content: null`.
Use a larger `max_tokens` (256+) or `reasoning_budget_tokens` to leave room for
the answer.

### A note on length

Reading a long prompt is normal: a 32K-token prompt takes roughly a minute at
the reference speed. The answer itself is much faster.

## Start, stop, status

From the Proxmox host, with the helper scripts (adjust the path if you copied
them elsewhere):

```sh
bash /root/strata-lxc/30-strata-control.sh status
bash /root/strata-lxc/30-strata-control.sh start
bash /root/strata-lxc/30-strata-control.sh stop
bash /root/strata-lxc/30-strata-control.sh logs
```

Set `CTID=<CTID>` if your container is not 121. Stopping the container frees its
RAM and the GPU. Do not stop it while someone is using it.

## If something is wrong

| What you see | What to do |
|---|---|
| The page does not open | Check the container is running (`pct status <CTID>`) and that `<CT_IP>` is still its address (DHCP leases change) |
| The first answer takes a long time | Normal after a restart; the cache is filling. Wait for the first request to finish |
| Answers are slow | A large context is slower; a long prompt takes ~1 min to read. The engine serves one request at a time |
| `content: null` | `max_tokens` too small; use 256+ or a reasoning budget |
| The server is unreachable | Check the host; if the GPU wedged, the host may need a cold power cycle (see troubleshooting) |
| A fan is loud | The blower ramps under load; expected. Idle is quiet |
| The model is bad at tools | Tool calling is limited; use chat or the plan agent |

## Security

There is **no login** by default. The API is open to the local network and any
key is accepted.

- Keep the server on the trusted network; do not forward the port on the router.
- For anything else, add `--api-key <key>` to the run script (for the reference
  project that is `/opt/Strata/run-iq3_s.sh`) and use the same key in the client,
  or bind `127.0.0.1` and put a reverse proxy with auth in front.
- The web page and the API share the same port.

## What the lights mean

The Proxmox UI (container → Summary) is the quick health check:

- **Status: running**; CPU near 0% when idle.
- **Memory usage** close to the container limit is normal: the model's experts
  live in RAM, and the page cache fills the rest. Read the *real* value, not
  `memory.current` (which includes reclaimable cache). See
  [Verification](03-building-it/30-verification.md#the-real-memory).
- **SWAP** in the low hundreds of MiB is the low-RAM mode's cold pages; normal.
- A **CPU spike** during a prompt is the model's workers.

## Who to call

The maintainer: the host, the container, the GPU tuning. Do not edit the Proxmox
host or the BIOS unless you are the maintainer — a wrong GPU or BIOS setting can
require a cold power cycle.
