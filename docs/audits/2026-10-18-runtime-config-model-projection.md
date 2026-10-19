# Config models from the same interpreted server source

Source baseline: `2273a3bdb31dae0672d4e5f51705769aa2b4b96a` (main including
externally merged source preparation #43676 and its release-note repair #43680).

## As-Is / To-Be / Before and After

| Config observation boundary | Baseline | This layer |
| --- | --- | --- |
| Runtime interpretation | Server interprets source, then TUI interprets it again for model rows | Server interprets once; TUI receives typed declared bindings |
| TUI Runtime source parses per ordinary Config observation | One | Zero |
| Total syntax parses in this observation when Keeper/Runtime inputs match | Server one + TUI one | Server one + TUI zero |
| Total syntax parses when Keeper normalization changes its input | Server two + TUI one | Server two + TUI zero |
| Model reference lookup | Client searches models/providers for each binding | Server indexes declarations once, then projects each exact binding |
| Client preparation effect boundary | Shared IO, because Runtime parsing can expand credential homes | Shared CPU; snapshot no longer calls Runtime parsing or reads environment |
| Model provenance | Same raw response, with local model interpretation | Explicit model envelope with exact source path/revision, declared context origin and provider/model pair |
| Missing or invalid model evidence | Local model parse might still succeed | Model error; original source and independent observations remain usable |

Counts are source-derived for the ordinary Config observation path, not timings.
Server semantic interpretation remains one and retains its environment expansion.
Keeper-specific input normalization policy, source loading, account-group/email
observations, HTTP work, JSON serialization and painting are unchanged. Sending
bindings adds JSON bytes and decoding work; elapsed performance is unmeasured.
No network round trip is removed. Pool absent/non-Eio/already-worker inline policy
and late pure-work completion policy remain authoritative.

## Declaration and observation ownership

`Runtime_config_models` projects the already interpreted config, without catalog,
environment, account or credential reads. It includes every declared binding,
including disabled declarations, and provider identities with no bindings so group
references can still be checked. Unbound model specifications do not invent rows.
Binding/provider/model context precedence, original model context, exact quoted or
dotted identity, reasoning effort, temperature and absent output limits remain.
Dangling or duplicate declaration identities produce an error rather than being
silently dropped. Pair identities are structural, not concatenated keys.

The raw response adds `model_bindings`: an envelope with `path`, `source_revision`
and `outcome`. Available outcomes carry typed provider identities and bindings;
unavailable outcomes carry the interpretation/projection error. The decoder checks
the enclosing reading's exact identity, required fields, row types, finite numbers,
positive declared limits, known context/effort and unique binding/provider identity.
Model-origin context must agree with the retained model declaration.
No credential values, account homes or credential paths enter this projection.
Other raw-response fields and commit receipts keep their existing meaning.
The dashboard normalizer ignores this additive field; it has no new consumer here.

TUI decoding keeps model, account-group and account-email results independent.
Model presentation combines only the accepted declaration result and that same
reading's disjoint server-owned account groups. A missing field (including an
older server), mismatch, unavailable outcome or malformed row does not trigger a
local source parse or a current-global-catalog fallback. Source repair remains
available. Source-only form parsing still uses Runtime parsing and its environment
effects; this layer does not describe that parser as pure.
Specialized document-only reads keep their source/status decoder and skip unused
model-row decoding; only Config snapshot reads request that client projection.

Only immutable response interpretation and source tokenization run on the client
CPU worker. UI admission, workspace/read authority, requested model intent, draft
owners, read generation, unknown-save revalidation and original CAS inputs retain
their prior boundaries. Neither a projection nor cached tokens grant edit authority.
The existing request/prepared/admission clocks remain; the CPU event's decode wait
includes pool admission and scheduling, not just CPU execution or paint latency.

## Evidence and remaining goal

Four new feature/protocol scenarios are authored and **unexecuted**: declared
binding/context/knob preservation; wire round trip with exact observation identity
and unavailable result; malformed/dangling/duplicate refusal; original source and
independent account observations through missing/mismatched model evidence.
Existing ownership scenarios now supply server model projections in their fixtures.
No wording, layout, row-order, snapshot-output or PTY check is added.

Only parser-only source checks, diff hygiene and changelog validation are executed.
Types, feature execution, independent current-head approval, CI, installed binary,
runtime, paint and speedup remain unverified. No live product config, prompt,
login file or runtime is read or changed. No own merge or restart is performed.

The complete preparation/first-usable-input/readability/visibility/observability,
Ask-to-original-Task-to-useful-work, resource-owned ordinary/nested/dynamic/effectful
Composition, held-job/shared-backend and matched Before/After goal remains open.
Future comparisons must retain failed, cancelled, interrupted and unfinished
samples; this source layer does not establish goal completion.
