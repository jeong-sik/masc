# Codex account reasoning effort

Codex owns its available models and reasoning effort tiers. MASC retains
`supportedReasoningEfforts` and `defaultReasoningEffort` from the selected
account's `model/list` response through isolated model refresh, setup metadata,
the dashboard model picker, and terminal setup. These fields are discovery
evidence, not proof that the account completed a model turn.

The static Codex model list and context lookup require an exact bare catalog
row. A context declared only for an API provider does not establish the native
client's context, so that model is omitted from the static Codex list and its
client lookup refuses. Isolated account-native refresh discovers the actual
available models and reads their effective context from the fresh CLI cache.
Explicit provider queries retain their provider-scoped catalog context.

An explicitly configured `reasoning-effort` is admitted on the same app-server
connection that will run the turn. After `thread/start` or `thread/resume`
reports the actual model, MASC reads all model-list pages, including hidden
models. It keeps a supported requested tier, otherwise chooses the nearest
known lower tier, or the lowest known advertised tier. The resulting tier is
sent on `turn/start`; Keeper records requested and effective values in the
`codex_reasoning_effort` raw-trace hook.

Upstream effort strings are an open vocabulary. Discovery preserves unknown
strings verbatim, including the advertised default. Only exact canonical MASC
wire values have a rank. A missing model, malformed metadata, or a ladder with
no known tier refuses an explicit request before history or prompt dispatch.
That refusal releases the Keeper claim as a pre-dispatch failure; host shutdown
and cancellation keep their own stop semantics.

When effort is unset, MASC sends no additional model-list request and no effort
field. Codex chooses its default. Setup never freezes that advertised default
into a runtime override. The static provider catalog continues to govern other
transports; it does not cap the selected Codex account's advertised tiers.
