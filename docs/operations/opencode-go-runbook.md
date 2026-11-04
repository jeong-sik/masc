# OpenCode Go subscription provider

The operator runbook for the `opencode_go` provider (OpenCode Go/Go Plus
subscription gateway). The seed ships the provider, one DeepSeek V4.1 Flash
binding and the `go-deepseek-then-glm` lane; this page wires a live workspace
to the subscription behind them.

## Why a subscription gateway

Go meters usage at official token rates against a monthly dollar allowance per
model. DeepSeek V4.1 Flash allowance was $100 on Go ($10/month) and $200 on Go
Plus ($40/month) as of 2026-11-02, with 20% usable per 5 hours and 50% per
week. Allowances move with promo phases; confirm the current figures in the
[Go docs](https://opencode.ai/v2/docs/console/go/) before budgeting.

Each model has its own allowance bucket, and every bucket has the 5-hour and
weekly sub-caps. A single heavy keeper can sit inside the monthly total while
tripping a sub-cap, so the shipped lane fails over to Ollama Cloud and Z.AI
on independent quotas instead of running one candidate.

## 1. Subscribe and take the key

1. Sign in to the [OpenCode Console](https://opencode.ai/console), subscribe to
   Go or Go Plus, and copy the API key.
2. Export it where the server starts from as `OPENCODE_API_KEY`. The server
   reads the environment of its launching process (plus repo-root `.env` /
   `.env.local`); a key added to a shell profile after the server started is
   not visible until restart. A turn dispatched without it fails with
   `Missing env var: OPENCODE_API_KEY`.
3. In Console Settings › Privacy, select **Global** under Regions. DeepSeek
   V4.1 Flash and V4 Pro are restricted models: without Global the API
   answers 400 (`This Go model requires Global regions`).

## 2. Wire facts (probed 2026-11-04)

| Fact | Value |
|---|---|
| Endpoint | `https://opencode.ai/zen/go/v1` (chat completions; `/models` 200) |
| Official docs path | `https://opencode.ai/inference/go/openai/v1` (same backend; no `/models`) |
| Auth | `Authorization: Bearer $OPENCODE_API_KEY` |
| Required header | `x-opencode-session` (stable id per conversation; 400 without it) |
| DeepSeek api-name | `deepseek-v4.1-flash` (1M context, 384k output) |
| Reasoning control | gateway takes `reasoning_effort` low/high/max, but MASC sends none (no ladder key; default-on reasoning verified without it) |
| Reasoning stream | `delta.reasoning_content` (SSE) |
| Billing proof | `billing_source: "go-plus"` in usage |

MASC sends one static `x-opencode-session` for all keepers
(`[providers.opencode_go.headers]`). That satisfies the requirement; routing
and cache affinity stay below what per-conversation ids would give.

## 3. Assign keepers

Point a keeper at the shipped lane through the runtime configuration surface
(or merge into the live `runtime.toml` and restart):

```toml
[runtime.assignments]
worker-name = "go-deepseek-then-glm"
```

Keep a subscription lane narrow: start with two or three workers and watch
burn against the 5-hour and weekly sub-caps before widening it. Go workspaces
are single-member and traffic must look like a coding agent; hammering one
key from a whole fleet risks the account, not just the allowance.

## 4. Verify

1. Restart the server from a shell that has the key (step 1.2).
2. Confirm the boot report resolves `go-deepseek-then-glm` with the
   `opencode_go.opencode-go-deepseek-flash` head and names no missing slot.
3. Run one keeper turn on the lane and check its receipt serves the Go head
   (failures name the candidate: `Missing env var` means step 1.2,
   `requires Global regions` means step 1.3, a 5-hour cap means the next
   candidate serves).
4. Track allowance burn in the Console; the usage object reports
   `billing_source` and per-request allowance cost.

## Failure modes

- `Missing env var: OPENCODE_API_KEY` — the server process predates the key.
  Restart from a fresh shell.
- `MissingSessionID` 400 — the headers table was dropped. Restore
  `[providers.opencode_go.headers]`.
- `requires Global regions` 400 — step 1.3 not done.
- `has no declared categorical reasoning-effort contract`, or `cannot encode
  enable_thinking=true` under the `Reasoning_effort` dialect — a
  `reasoning-effort` declaration needs an effort ladder no runtime.toml key
  expresses, and a bare enable has no encoding there either. Keep the shipped
  shape (`reasoning-uncontrolled`, control format `none`) until the ladder is
  plumbable.
- Sub-cap rejection mid-month — expected at fleet scale; the lane's next
  candidate serves. Narrow the lane or add allowance; do not widen blindly.
