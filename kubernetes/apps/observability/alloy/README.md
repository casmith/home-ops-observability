# Alloy — OTLP collector for LLM usage telemetry

Receives pushed OpenTelemetry from LLM clients that Prometheus cannot scrape,
and fans it out: metrics to Prometheus, per-request events to Loki.

- **Endpoint:** `https://otlp-obs.kalde.in` (OTLP/HTTP, internal gateway only)
- **In-cluster:** `alloy.observability.svc.cluster.local` — 4318 HTTP, 4317 gRPC

## Why a push collector

The senders are ephemeral processes on machines outside this cluster — Claude
Code on the workstation, and the Claude Code job runner in the homelab agent on
`pve6-ubuntu-agent-1`. A CLI session that lives for ninety seconds cannot be a
scrape target, so it pushes and something long-lived receives. Same shape as
`loki-obs.kalde.in`, which the homelab agent already ships container logs to.

## Configuring a sender

Claude Code, in `~/.claude/settings.json` under `env` (better than shell exports
— it applies to every session including ones launched by an editor):

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "https://otlp-obs.kalde.in",
    "OTEL_METRICS_INCLUDE_SESSION_ID": "false",
    "OTEL_METRIC_EXPORT_INTERVAL": "10000"
  }
}
```

`http/protobuf` is not optional: this is exposed through an HTTPRoute, so only
the HTTP receiver is reachable from outside the cluster. gRPC on 4317 would need
a GRPCRoute.

`OTEL_METRIC_EXPORT_INTERVAL` is lowered from its 60s default because a session
shorter than one interval may never export. Upstream docs do not state whether
Claude Code flushes on exit, so treat very short sessions as best-effort.

## The cardinality guard

`OTEL_METRICS_INCLUDE_SESSION_ID` defaults to **true**, which puts a distinct
`session.id` on every metric datapoint — one new Prometheus series per session,
growing without bound against 90d retention. The setting above turns it off at
the sender, and `prometheus.relabel "drop_high_cardinality"` in the Alloy config
drops it again on the way through.

Both, deliberately. Senders are hand-configured on several machines and one that
forgets would quietly damage Prometheus for everyone; enforcing it at the single
point every sender passes through is the difference between a convention and an
invariant. Session detail is not lost — it stays on the `claude_code.api_request`
events routed to Loki, where high cardinality is cheap and is what you want for
drill-down anyway.

## What it feeds

| Signal | Sink | Answers |
|---|---|---|
| `claude_code.cost.usage`, `claude_code.token.usage` | Prometheus | "what did this month cost", by `model` / `query_source` |
| `claude_code.api_request` events | Loki | "which requests", with cost, tokens, duration |
| `otelcol_exporter_send_failed_metric_points` (Alloy's own) | Prometheus | "is the collector actually delivering" |

That last row matters: a collector that has silently stopped forwarding looks
exactly like "nobody used Claude today" on every dashboard downstream. The
chart's `serviceMonitor` is enabled so that failure is visible rather than
inferred from an absence.

## Two cost numbers that must not be added together

Claude Code reports cost under a **subscription** — the figure is imputed at API
list prices, not money billed. The LiteLLM gateway on `pve6-ubuntu-agent-1`
reports **metered** spend against real API keys. Both are useful and they mean
different things: the first answers "am I getting my money's worth from the
subscription", the second "what will the invoice say". Any dashboard that sums
them into one "LLM cost" is lying.

## Not covered yet

**OpenClaw** on `pve4-ubuntu-1` authenticates with a ChatGPT subscription
(`provider: openai-codex`, `mode: oauth`), so it cannot route through the LiteLLM
gateway either. Its OTEL support is traces-only — no usage metrics are
instrumented — but it does record per-turn tokens and an imputed cost in
`~/.openclaw/agents/*/sessions/*.trajectory.jsonl`. Closing that leg needs a
small exporter that parses those files; nothing here blocks it.
