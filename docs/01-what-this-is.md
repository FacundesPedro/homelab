# What this is

A private AI chat server that lives on the local network. It is not a cloud
service, and after the model was downloaded it does not need the internet to
answer.

> The numbers below are the **reference deployment** (prox-2). Your host, card,
> container ID, addresses and model size may differ; the ideas do not. The
> placeholders and reference values are listed in
> [README — Conventions](README.md#conventions).

## In one minute

- It runs a large open language model, **Qwen3.8-Flash-Next**, quantized to
  **IQ3_S** so it fits on a consumer graphics card.
- The card is an **AMD Radeon** (the reference box uses an **ASRock RX 7900 XT
  Creator, 20 GB**).
- The card lives in a **Proxmox** server, inside a lightweight **Debian 13
  container** (the reference is CT 121, `strata-2`).
- You talk to it through a **web page** or an **OpenAI/Anthropic-compatible
  API**. OpenCode can use it like any other model.
- It can read a lot of text at once: **up to 256K tokens** on the reference
  card, roughly 190,000 words.
- It can also accept images; the image encoder runs on the CPU.

## What it is good at

- Chat, summaries, rewriting, coding help.
- Reading long documents, logs, or repositories.
- Private work: prompts and answers stay on the local network.

## What it is not

- **Not on the internet.** It listens on the local network only, and there is no
  login.
- **One conversation at a time.** A second request waits in a queue.
- **Not a general-purpose computer.** It runs one model; the container is not
  for other services.
- **Not as fast as a cloud API.** Expect roughly 30–54 tokens per second for the
  answer; the first request after a restart is slower while the cache fills.

## The parts, in plain language

| Part | What it does | In plain numbers (reference) |
|---|---|---|
| Host (`prox-2`) | the server that runs everything | 28 CPU threads, 62 GB RAM |
| Container (`CT 121`) | the box the model lives in | 28 cores, 56 GB RAM, 380 GB disk |
| GPU | the card that does the AI math | 20 GB VRAM |
| NVMe | the fast disk that holds the model | 477 GB, about 134–148 GB used by the model |
| Model | the "brain" | 84 GB download, IQ3_S |
| API | how programs talk to it | OpenAI and Anthropic formats |

## Why it is built this way

The short version: a full virtual machine with the graphics card passed through
hit the known **Navi 31 reset bug** (the RX 7000 series) — the card would
disappear and the server needed a cold power cycle. The virtual machine also
**locked 52 GB of the host's RAM** on the reference 62 GB host, leaving almost
nothing for the server itself.

The container shares the host's graphics driver instead:

- no passthrough, so no reset bug;
- the host keeps its memory;
- the model sees the real CPU topology and picks its own workers;
- the model files sit directly on the fast NVMe.

The trade-off is less isolation than a virtual machine. For a single-purpose
home server, that is the right trade.

## The one physical quirk

On the reference card (ASRock RX 7900 XT Creator) the blower cooler cannot get
rid of the stock ~250 W. Its **hotspot (junction) temperature reaches 110 °C in
seconds**, and the card crashes. The fix is a software **undervolt** plus a more
aggressive fan curve, applied by a small tool called LACT.

With the reference profile, a 5-minute full-load test stays at **86 °C** and the
card is stable. A repaste and better case airflow would still help, but they are
not required to run it. The method and the reference values are in
[undervolt/](undervolt/README.md); other cards need their own tuning.

## The honest limitations (reference)

| Limit | Why |
|---|---|
| 20 GB VRAM | 256K of context leaves only a small expert cache on the card |
| 56 GB container RAM | the model's experts are about 38 GB; the page cache fills the rest |
| 3 GB free host RAM | at 256K; 200K leaves about 4.3 GB, 128K about 4.5 GB |
| One request at a time | the engine serves one sequence |
| No login | anyone on the LAN can use it |
| No BMC | a wedged GPU needs a cold power cycle (a smart plug helps) |

## For the curious

The exact versions, commands, container configuration and tuning matrix are in
[03 — Building it](03-building-it/README.md), [04 — Reference](04-reference/versions.md)
and [undervolt/](undervolt/README.md). You do not need any of it to use the
server.
