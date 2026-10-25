# Exact model catalog identity — issue #27898

Layered on the exact manifest repair #45862, source parent `9bbccf5261fa2703f3d31c542c9d972940cced00`.
The remaining catalog could give an undeclared suffixed model capabilities
and pricing through longest-prefix matching. Declared providers could also
borrow any bare row within an allowed family. These two expansion rules are
removed together.

## Contract

- Model declarations use `model_id : Model_identifiers.Model_id.t`.
  Provider-scoped and independent lookup and duplicate checks use the same
  exact ASCII case equality. Stored/API spelling remains unchanged.
- `serves_bare_models` is an explicit list of exact model identities.
  A provider alias retains the owner's exact permission, not a model family.
  Lookup and visible-row enumeration use the same permission.
- Old model `id_prefix` and provider `serves_bare_rows` keys are rejected.
  The prefix identifier type and its prefix-matching APIs are removed.
- `of_model_entries` returns Result and rejects duplicate normalized identities
  before indexing, as file parsing already does.
- `suggested_clients` is typed presentation metadata. It preserves the exact
  35 existing CLI model suggestions without guessing from model names or
  granting HTTP ownership. Missing tags mean no suggestion. Unknown/duplicate
  tags are rejected. All235 model row payloads remain otherwise unchanged.
- Binding, context metadata and CLI exact-ID comparisons use shared typed
  equality; they do not rewrite wire bytes.

Direct consumers and TOML fixtures migrate in the same layer. Tests that
previously blessed undeclared suffix inheritance now use exact declarations
for positive capability/precedence assertions and explicit negative variant
cases. Runtime slot aliases are not fabricated into new API-model declarations.
Unrelated PID, digest and transcript-prefix identifiers retain their original
names; an overly broad early migration was corrected before publication.

## Evidence and limits

The actual prior consumer run40146575018 checked out the parent9bb and passed
assertions that glm-5v-turbo-x and other undeclared variants inherited policy.
The retained excerpt is an actual before observation against the original
issue contract, although the historical test called it a prefix-ordering pass.

Changed OCaml sources/interfaces parse and whitespace checks pass. Python TOML
comparison confirms235 unchanged row payloads apart from the identity key and
35 exact preserved suggestions.

Actual initial run40149391321 at23e6d4d262038e12c2e113ec8e709817a6053e99
finished FAILURE: six suites passed262 cases; catalog26/27 and capabilities114/124.
The new identifier/permission cases passed, as did provider config, catalog
coverage, exact resolver, MASC auth and thinking consumers. The11 failures
exposed positive fixtures still expecting undeclared variants, scoped Gemma
leaking into bare lookup, and an invalid negative assumption about the explicitly
declared glm-4.5-x. Corrections use existing exact rows, scoped-only denial and
a genuinely undeclared suffix; glm-4.5-x keeps its own128K output assertion.
Native Kimi sampling policy assertions are preserved on its declared row.
Selected actual logs are retained alongside this file. Corrected execution is
requested separately; no aggregate success is claimed.

No local Dune build, full MASC executable build, provider HTTP, deployment or
complete #27898 closure is claimed here.

The issue remains open for provider/catalog/manifest consolidation, remaining
reverse provider discovery/high-level binding/API cleanup, and integration.
Explicit exact provider-independent row sharing still exists; removing prefix
expansion is not a claim that every original bare-lookup API has been removed.
