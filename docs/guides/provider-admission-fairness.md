# Sharing provider capacity between Keeper calls and memory work

Provider permits are shared by process, provider kind, endpoint and credential.
Different models on the same account can therefore wait in the same queue.
`max-concurrent` controls how many calls may run; it does not select which
waiting call runs next. A permit covers one provider request, not the whole
Keeper conversation, and returns before tool execution.

An account whose bindings declare `max-concurrent` queues waiting requests in
three request classes (`Slot_scheduler`):

| Class | MASC callers | Service without `admission-priority-run-limit` (default) | Service with `admission-priority-run-limit = N` |
| --- | --- | --- | --- |
| Priority | Verifier, HITL auto judge, Board attention | First, in arrival-order FIFO | Before Standard, up to `N` consecutive grants while Standard waits |
| Standard | Keeper provider calls and other ordinary requests | After Priority is empty, in arrival-order FIFO | After Priority yields or empties, while foreground grants remain within `N` |
| Background | Librarian memory and continuity processing | Only when both Priority and Standard queues are empty (may use up to all `max-concurrent` slots when foreground queues are empty) | Receives the next available permit once `N` consecutive Priority/Standard grants have passed it |

Strict **`Priority` → `Standard` → `Background`** ordering therefore holds by
default even when `admission-priority-run-limit` is omitted. FIFO arrival order
is preserved within each class, and no class is ever inferred from a model
name, prompt, or request duration. Requests that cancel or exhaust their
declared wait leave their queue without consuming another request's permit.

A permit covers execution cleanly without preemption: admission neither
increases provider concurrency nor interrupts an active request. If all permits
are already held by running `Background` (or other long-running) calls, an
arriving Keeper or judgment call still waits until one active request finishes
and returns its permit.

`admission-priority-run-limit` is an opt-in starvation-prevention bound for
`Background` (and `Standard`) on an intentionally shared account — **not** a
setting to protect Keepers. When an operator removes a live run limit, waiters
already in the `Priority`, `Standard`, and `Background` queues stay in the
class queues they joined, the consecutive-grant counters reset to `0`, and strict
`Priority` → `Standard` → `Background` ordering takes effect immediately for
both existing waiters and subsequent arrivals.

## Prefer dedicated accounts for Librarian lanes

Separate the accounts or endpoints backing Keepers from those backing Librarian
background synthesis whenever possible (see
[RFC-librarian-seat-separation-and-keeper-first-admission](../rfc/RFC-librarian-seat-separation-and-keeper-first-admission.md)):

- Because running `Background` calls are non-preemptive and Librarian
  consolidations hold permits much longer than interactive Keeper turns (around
  14×–57× occupancy asymmetry in live fleet measurements), sharing a single
  account still blocks arriving Keepers whenever active `Background` calls fill
  the pool.
- Allocate a dedicated HTTP account or local runtime (see
  [Several accounts of one catalog provider](#several-accounts-of-one-catalog-provider)
  below) to `[runtime.exact_output_lanes.librarian_exact]` and
  `[runtime.exact_output_lanes.librarian_memory]`, removing shared Keeper seats
  from their `slots` and `cli_slots`. With dedicated seats and
  `admission-priority-run-limit` unset, Librarian uses the full slot capacity
  when idle and never delays Keepers.
- On single-key or single-subscription hosts without a separate runtime, set
  `enabled = false` on optional `[runtime.exact_output_lanes.librarian_memory]`.
- At config load, MASC checks enabled `librarian_exact` and `librarian_memory`
  HTTP `slots` and CLI `cli_slots` against Keeper-reachable runtimes and logs
  overlap warnings if both share the same account or credential identity.

## Bound Background starvation on an intentionally shared account

Only set `admission-priority-run-limit` when you intentionally share an account
between Keepers and `Background` work AND want `Background` (or `Standard`) to
receive a bounded turn under continuous foreground traffic. Because granting a
slot to a long-running `Background` call prevents Keepers from reusing that
permit until completion, setting a small limit such as `1` or `4` increases
long Keeper wait times compared to leaving `admission-priority-run-limit`
unset (strict `Priority` → `Standard` → `Background`) or separating seats.

Use the existing provider table and its actual account capacity. For example,
an operator sharing a concurrency pool of four who intentionally permits one
waiting `Background` request after every `16` foreground grants can configure:

```toml
[providers.ollama_cloud]
# Keep the endpoint and credentials already configured here.
# Omit this key on dedicated accounts or when Keepers should always drain ahead of Background.
admission-priority-run-limit = 16

[ollama_cloud.chat_model]
max-concurrent = 4

[ollama_cloud.memory_model]
max-concurrent = 4
```

The binding names are examples. Leave `admission-priority-run-limit` unset when
strict Keeper-first ordering is desired. Every admitted binding sharing that
endpoint and credential must agree on the account allowance. A run limit on an
account without any `max-concurrent` binding is rejected. A binding with no
permit declaration bypasses admission and cannot benefit from queue ordering.

Read the current source with the authenticated
`GET /api/v1/runtime/config/raw`, preview the edited source with
`POST /api/v1/runtime/config/raw/preview`, then save it to
`POST /api/v1/runtime/config/raw` with the observed `expected_source_revision`
and `expected_source_path`. Reread after a revision conflict rather than
overwriting another edit. Publishing reconfigures admission without a restart;
the three-class code must already be present in the running binary. Editing
the repository seed alone does not change a deployment.

## Verify the effect

Read `/api/v1/providers` to verify the enforced slot count. Inspect
`masc:provider_admission:waited` records in
`<base-path>/.masc/agent-core-events/YYYY-MM/DD.jsonl` by provider and
`admission_class`; the payload states the wait duration and whether a permit
was granted or the wait expired. Immediately admitted calls do not emit a wait
record. Background grants and completed Librarian runs must continue alongside
Standard Keeper responses and tool continuations.

Use `Streaming_first_chunk.requested_at` and `Streaming_summary.total_ms` to
separate queue delay from the upstream request. A lower queue count can include
expired requests; it does not establish successful throughput. One successful
stream is also distinct from a complete final answer or sustained fleet health.

## Several accounts of one catalog provider

Give each account its own `[providers.<id>]` table and credential, and name
the catalog row it speaks as with `catalog-provider`. The catalog then answers
for the account's dialect, capabilities and request policy, and the account can
be an Exact-output lane slot. Permits, quota windows and slot rests stay per
account, because they are keyed by credential and runtime id, not by the
catalog row.

```toml
[providers.claude_a]
protocol = "messages-http"
endpoint = "https://api.anthropic.com"
catalog-provider = "claude"
exact-body-timeout-s = 1200.0
[providers.claude_a.credentials]
type = "env"
key = "ANTHROPIC_API_KEY_A"

[models.haiku]
api-name = "claude-haiku-5-5"

[claude_a.haiku]
max-concurrent = 4
```

- Remove `kind` when you add `catalog-provider`: the catalog owns it, and a
  file that states both is refused with the key to remove. `endpoint` and
  `request-path` still override the catalog's values when written.
- Write the row id exactly as the catalog spells it (`claude`, not `Claude`
  or an alias). The exact-output resolver matches the id as written, so
  another spelling is refused with the id to write.
- A `catalog-provider` that names no catalog row refuses the whole file, as a
  binding that names a missing `[providers.<id>]` row does. So does a provider
  whose own id is already a catalog row. These checks run for a provider an
  enabled binding names.
- The setup wizard and model discovery still look the account up by its own
  id, so their model list and context window for it come from runtime.toml,
  not from the catalog row.
- An official client (`claude-code`, `codex-app-server`, …) may not declare it.
- A lane slot the catalog cannot admit is left out at boot, and the lane runs
  with the slots that remain. The deployment preflight refuses the same
  runtime.toml and names the lane, the slot's position and id, and what to
  write, so an install does not quietly shorten a lane. That covers an
  account without `catalog-provider`, a mistyped or removed id, a binding
  switched off with `enabled = false` that a lane still names, and a
  subscription CLI binding in `slots` instead of `cli_slots`. A lane switched
  off with `enabled = false` is not checked.
- The admission wait record carries the catalog row in its provider field, so
  `masc:provider_admission:waited` no longer separates these accounts by
  provider.
