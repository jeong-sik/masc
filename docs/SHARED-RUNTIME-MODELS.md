# Sharing models across provider accounts

A model declaration names an API model and its capabilities. A provider
declares the connection and account. Multiple providers can bind the same
model id; an account does not need a copy of the model specification.

Use a model set when multiple accounts offer the same list:

```toml
[models.sol]
api-name = "gpt-6.1-sol"
max-context = 272000
tools-support = true
streaming = true
reasoning-effort = "high"

[model_sets.codex]
models = ["sol"]

[providers.codex_first]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "/path/to/first/codex-home"
model-set = "codex"

[providers.codex_second]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "/path/to/second/codex-home"
model-set = "codex"
```

This declares one model and generates `codex_first.sol` and `codex_second.sol`.
Add a future model under `[models.*]`, then add its id to the shared list once.
Every provider referencing that set gets its own binding. Providers can choose
different sets when their accounts offer different models; there is no automatic
cross product with unrelated models or accounts.

An explicit binding table overrides the generated default for that exact
provider and model. For example, `[codex_second.sol] enabled = false` disables
that binding, and `wizard-default`, concurrency and context marks stay on
individual binding tables. The parser never creates a second copy of an
explicitly configured binding.

Model-set lists contain declared model ids, not API names. Missing models,
unknown sets, repeated model ids, wrong value types and unknown set keys are
load errors with a TOML path. Expanded bindings go through the existing runtime
validation, materialization, routing and quota paths.

Reasoning depth remains a declared model-profile setting. Two profiles using
the same API model at different efforts can share a set; changing accounts
does not require another copy of either profile. Accounts, credentials and
availability remain provider properties.

The dashboard reads shared models and binding overrides from table headers,
inline tables and dotted keys. Editing a binding creates or updates only that
provider's override. Deleting a provider removes its lane candidates, exact
slots and media fallback references, and refuses a deletion that would empty
a required lane. Shared models and the model-set definition stay available to
the remaining accounts.

Repository seeds are copied only for new workspaces. Existing installations
must apply the model-set declarations through the runtime configuration API
after deploying a binary that understands them.

## Choosing the context window

In the dashboard runtime editor, open **Models**, enter a positive context token
count, or use the **500K** / **1M** presets. Select
**Save** at the top to persist the change. The model's `max-context` applies to
every provider binding that shares that model declaration.

With the Codex context propagation change in [#40472](https://github.com/jeong-sik/masc/pull/40472), MASC passes this value as Codex's
`model_context_window` on each new client process, including Keeper, Fusion,
verification and connection probes. This explicit runtime value takes precedence
over an inherited Codex home configuration; an existing `max-context = 272000`
therefore requests 272,000 until you edit it. Running turns retain their process
configuration. MASC does not change `model_auto_compact_token_limit`.

This is a requested window, not proof of provider capacity. Codex's reported
`modelContextWindow` remains the observed effective value. The API model context
specification and the subscription client's available context can differ;
selecting 1M does not establish that every account or model supports it.
See the [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
and the [GPT-6.1 Sol API model specification](https://developers.openai.com/api/docs/models/gpt-6.1-sol).

### Requested versus reported context

The model editor labels `max-context` as a **request**. A preset or profile name
is not a capacity measurement. After a turn, the turn inspector and memory
inspector show the configured window alongside the client's same-turn report.
If that report is absent, the UI says it is unmeasured; it does not multiply the
request by a fixed percentage or borrow another account's observation.

Occupancy uses the reported window when present. The configured window is a
clearly labelled fallback, and cumulative/turn-total usage is not treated as
per-request occupancy. Counts exceeding the selected window remain unavailable
instead of being clamped to a plausible percentage. These are observations of
the recorded turn, not guarantees about the next request or maximum accepted
prompt size. Saved request values are not rewritten from observations.
