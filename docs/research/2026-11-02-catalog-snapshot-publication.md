# Complete catalog publication

Issue [#27898](https://github.com/jeong-sik/masc/issues/27898) remains open.
This unit replaces the two mutable source catalogs after the pure dependency
extraction. Its direct parent is `6de7ff9031a6429d802f91eb0fe6452853db3b9e`.

## Publication and lifetime

`Catalog_snapshot.of_catalogs` admits an explicit complete model/provider pair
without changing global state. Only an opaque admitted value can be published.
One `Atomic.t` owns the optional explicit whole value; no individual source
setters remain. `reset` selects a single immutable lazily admitted embedded
constant. A reader selects the old or new whole value at its one atomic read;
it need not return the latest value at the time the call returns. A reader
which selected the default may finish pure lazy admission while another domain
publishes a replacement, and still returns that coherent default.

This design follows the [OCaml Atomic contract](https://ocaml.org/manual/5.5/api/Atomic.html)
and the sharing of immutable values described in the
[parallelism manual](https://ocaml.org/manual/5.5/parallelism.html). It does not
turn several API calls into one reader transaction: consumers must retain
their captured snapshot, as binding, construction and batch owners do.

`Model_catalog` and `Provider_catalog` now only decode and project immutable
inputs. The previous `Provider_declarations` façade and unused JSON-only
`Provider_runtime_binding.find_catalog` are removed. `Capabilities` owns the
selected request-policy projector, above the pure catalog snapshot dependency.
Pricing captures the corresponding admitted provider scope.

## Observation authority

Raw provider-aware model observations use a pure model-catalog view with only
the admitted provider's aliases and bare-row permissions. A JSON replacement
cannot recover the old seed's aliases or permissions. A raw provider id does
not acquire the JSON provider's capability profile or credential identity;
selected bindings explicitly carry those facts. Exact custom scoped model rows
remain usable without a provider seed. Requested-alias rows keep precedence
over canonical scoped rows, including captured request prices. Anonymous wire
references never select provider aliases.

The token getter still requires an exact scoped provider/model row. It does
not inherit a token from a bare row even when general model capability lookup
permits that bare row.

Bootstrap admits a full replacement with `providers=None` before publication.
Wizard provider model queries use a private admitted embedded snapshot and
do not publish it. Prototype task classification uses the entry's captured
snapshot with its endpoint and identity.

## Validation scope

The public snapshot suite retains earlier admission, collision, replacement,
credential-edge and custom-row controls. New controls exercise whole
model/provider/auth/price replacement, a synchronized domain handoff, explicit
absence, default reset, pure admission, rejected-pair preservation, raw removed
aliases, revoked bare permissions, requested-alias price precedence and exact
token scope. Bootstrap covers publication after admission and preservation
after rejection. Existing fixture setup and cleanup now construct complete
pairs and restore whole captured values.

The old native/batch negative fixtures installed an invalid global catalog.
That state cannot be represented by this opaque public publication API. Their
replacement checks rejection before publication and the retained native,
empty, disabled and unresolved outcomes. They do not demonstrate forcing an
invalid global snapshot or promise an equivalent before/after test pair.
Three provider-config fixtures now explicitly declare their intended capability
base so they reach the new admission boundary. Their behavioral assertions are
retained; they are not byte-identical historical inputs.

Local validation is source parsing, dependency reading and whitespace checks
only. Executed CI results and their exact checkout belong in a separate retained
receipt when available; no local build or typecheck is claimed here.

Strict missing-field admission, remaining high-level provider selection,
startup/account and native implicit-HOME requirements from the original issue
remain separate. Source review, focused execution, formal approval, Native Stack
integration, installed runtime and issue completion remain distinct evidence.
