# Immutable state and authority audit

Baseline: `934c63d2904651b9a902b80b830447ffd15b298c`.
Scope: state producers and consumers serving `<base-path>/.masc` and MASC.
This audit remains open; the first repair is not a repository-wide completion claim.

## Dashboard publication repair

`Server_dashboard_http_cache` exposed mutable current and memoized-payload fields.
Operator invalidation/failure and Keeper lifecycle patches wrote those fields
outside the cache module. Snapshot fields were immutable already, but compound
updates and publication of derived encodings were not one operation.

The cache now owns an abstract atomic cell containing an immutable snapshot and
its optional derived payload. A state transition invalidates the payload in the
same CAS. Serialization publishes only against the observation it rendered.
Operator tombstone/error transitions publish their related fields together, and
Keeper lifecycle patches use the same update boundary. Existing higher-level
generation locks still own stale-computation admission; atomic publication does
not replace that ordering policy.

`surface_snapshot_json ~now` has explicit time input. HTTP accessors own clock
reads. The diagnostic merge now removes all overwritten occurrences, including
duplicate diagnostic containers, and the last incoming value wins. Previously
`List.rev_append (List.rev extra_fields)` preserved incoming order and duplicates,
contradicting the declared last-write-wins contract.

Verification mapping:

- Cache API -> operator and execution surfaces -> `test_dashboard_http_core`:
  retained observations, error clearing, invalidation, JSON/ETag refresh,
  deterministic stale-age projection and duplicate-key precedence.
- Abstract cache -> strengthened core facade -> namespace-truth warmup fixture:
  migrated its direct field write to the cache API.
- OCaml parsing and `git diff --check` passed. These are syntax/whitespace
  evidence, not type checks or executed behavior tests.
- Independent adversarial source review identified one missed production field
  write in execution surfaces; a separate response agent migrated it.
- No Dune build, behavior suite, browser validation or deployment performed.

## Attached-service policy ownership repair

Producer: `Keeper_identity_tools.agent_tools` converts the catalog to immutable
`offered_tool` records but also writes `Keeper_identity_tool_index.shared ()`.
Store: the shared mutable association list is keyed only by model tool name.
Consumer: `Keeper_tool_approval_policy.undescribed_kind` consults this process
index on each call. Two Keeper catalogs declaring the same provider/tool name
can overwrite each other's annotations. A catalog projection therefore changes
policy behavior elsewhere in the process even when its returned value is unused.

The durable external-service Gate already captures each immutable `offered_tool`
and reads its own `read_only` value. This finding does not demonstrate bypass of
that Gate. The stale global index changes classification and explanations and
retains names after their offering disappears.

Catalog projection no longer registers anything. `Keeper_identity_tool_index`
is an immutable map built from `identity_allow.kept`, the same admitted offering
passed to bundle construction. Agent setup carries it in its result. Before
runtime dispatch the agent copies the stream gate with that exact index; the
driver binds the hook to the copied gate's index. Other gate values remain
unchanged. Policy calls require an explicit index, including an empty index for
built-in-only or unbound contexts.

Verification mapping:

- `agent_tools` -> immutable offered records -> admitted `identity_allow.kept`
  -> setup context/result -> copied approval gate -> driver pre-tool hook.
- `test_keeper_identity_tools` covers catalog projection, retained read/write
  declarations for the same tool name, absent tools, policy explanations, and
  a real approval hook with bound versus unbound gate observations.
- Existing policy, gate, bundle classification, native restart and readonly
  fixtures now supply explicit scope. Parsing and whitespace checks passed;
  behavior suites and type checking have not run.

Remaining audit work includes validating these source changes through the
repository's approved candidate checks and inspecting other state producers.
Neither draft PR nor syntax checks establish the complete requested outcome.

## Runtime boundary

Read-only `/health?full=1` observation on 2026-10-08 reported status `ok`, base path
`/Users/dancer/me`, runtime root `/Users/dancer/me/.masc`, and no root divergence.
This locates the requested runtime; it does not prove deployment of this patch.
No runtime-owned data or Keeper configuration was modified.
