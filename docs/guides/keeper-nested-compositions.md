# Exact inline composition compilation

`Keeper_composition_nested.compile` expands an exact, turn-frozen inline Skill
into the existing typed plan. This layer supplies the compiler API. The public
`keeper_composition_prepare` and installed Skill catalog do not yet accept this
node alternative; exposing it also requires durable draft provenance and actual
Skill activation at the dispatch boundary. Compilation is never activation.

The compiler consumes the same closed outer request grammar as ordinary plans.
A node can name one complete pinned inventory reference and fixed arguments:

```json
{
  "id": "prior-evidence",
  "skill_reference": {
    "identity": {
      "source_id": "project-agents",
      "package_id": "prior-art",
      "name": "prior-art"
    },
    "content_revision": "<exact revision returned by the frozen inventory>"
  },
  "args": {"query": "composition"},
  "after": ["earlier-node"]
}
```

Use the actual reference and parameter schema from the frozen capability surface.
The example revision is a placeholder; it is not an accepted reference. Names,
source precedence and a globally valid catalog entry do not grant this Keeper
permission. The exact reference must be model-visible and active on its turn
surface. Changing the content revision is a refusal, without a name-based fallback
or a source-file reread.

Arguments pass the same schema validator as a direct named composition call before
parameter substitution. The compiler checks required fields, types, enums and
extra fields. This API admits fixed arguments only. Feeding upstream output into
a child parameter requires a runtime contract barrier before any child leaf runs;
that separate integration is pending.

A child output is its declared named export. `/profile` selects export `profile`;
`/document/items/0` selects within export `document`. RFC 6901 escaping applies to
export names too. The compiler maps the export to its exact leaf producer and
revalidates the combined pointer against that producer's schema. Whole-child root
output and undeclared exports are explicit errors.

Every dependency on a child, including a reference to its exported output, waits
on all its leaves. A failing sibling therefore blocks a downstream consumer even
when the selected producer succeeded. Under `continue_independent`, unrelated
branches still run and successful selected exports remain available with the
aggregate failure. Child and parent failure policies must agree in this first
flat-plan compiler; the compiler refuses disagreements instead of changing them.

Expanded IDs encode complete string paths as canonical JSON arrays. Both ordinary
parent IDs and child IDs are renamed, so an arbitrary user ID that resembles a
child path cannot collide. Each compiled call retains its exact reference, bound
arguments and source-to-expanded leaf mapping for later durable evidence.

Async children are refused as `async_child_requires_suspension`. An async request
receipt is not a child result. Connecting that child requires durable suspension,
completion correlation and resumption, rather than flattening a worker as a normal
inline leaf. Expanded leaves currently require static read-only ordinary Tool
contracts; resource-aware effect admission remains a separate implementation unit.

The focused `test_keeper_composition_nested` scenario checks repeated child
references, escaped IDs and export names, parameter contracts, unavailable exact
references, expansion cycles and whole-child failure with retained independent
results. Parser checks do not establish its types or execution. Runtime activation,
public authoring and latency measurements remain outside this layer's evidence.
