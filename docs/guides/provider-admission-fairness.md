# Sharing provider capacity between Keeper calls and memory work

Provider permits are shared by process, provider kind, endpoint and credential.
Different models on the same account can therefore wait in the same queue.
`max-concurrent` controls how many calls may run; it does not select which
waiting call runs next. A permit covers one provider request, not the whole
Keeper conversation, and returns before tool execution.

An account with `admission-priority-run-limit` uses three request classes:

| Class | MASC callers | Service |
| --- | --- | --- |
| Priority | Verifier, HITL auto judge, Board attention | Before Standard, within the declared consecutive-grant limit |
| Standard | Keeper provider calls and other ordinary requests | Before the Librarian backlog, while still yielding to judgments |
| Background | Librarian memory and continuity processing | Receives the next available permit once the declared number of combined Priority/Standard grants has passed it |

The limit is a service rule measured in granted permits. It neither increases
provider concurrency nor interrupts an active request. It cannot guarantee a
response time while all permits are held by long requests. FIFO is preserved
within each class; requests that cancel or exhaust their declared wait leave
their queue without consuming another request's permit.

If no run limit is declared, all classes join one arrival-order FIFO. No class
is inferred from a model name, prompt, or request duration. When an operator
removes a live run limit, already queued Priority and Background requests keep
their original queues and drain before the Standard queue. That finite
transition is not a global FIFO; subsequent arrivals join the Standard FIFO.

## Enable the policy for an existing account

Use the existing provider table and its actual account capacity. For example,
an operator who has chosen a shared concurrency of four and alternating
foreground/background service can add:

```toml
[providers.ollama_cloud]
# Keep the endpoint and credentials already configured here.
admission-priority-run-limit = 1

[ollama_cloud.chat_model]
max-concurrent = 4

[ollama_cloud.memory_model]
max-concurrent = 4
```

The binding names are examples. Every admitted binding sharing that endpoint
and credential must agree on the account allowance. A run limit on an account
without any `max-concurrent` binding is rejected. A binding with no permit
declaration bypasses admission and cannot benefit from this policy.

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
