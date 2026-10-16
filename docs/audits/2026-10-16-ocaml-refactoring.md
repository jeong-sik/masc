# OCaml refactoring: responsibility boundaries and review context

Audit date: 2026-10-16. Baseline: `47c1741f3b95b443591e1316f713b84d16098c43`.
Source coordinates and inventory below describe that baseline, before this work.
The [constitution](../constitution.xml) and
[contributor workflow](../guides/CONTRIBUTOR-WORKFLOW.md) govern execution.

## Baseline inventory

The tracked production source scope is `lib/` and `bin/`, excluding `test/`.
It contains 2,349 `.ml` files and 2,221 `.mli` files. The implementation files
contain 869,503 physical lines, including comments and blank lines. Paths were
enumerated with `git ls-tree -r --name-only` at the baseline; line counts were
read from the clean checkout of that head.

| Inspected implementation | Physical lines | Why it matters here |
| --- | ---: | --- |
| [keeper_memory_os_current.ml](../../lib/keeper/keeper_memory_os_current.ml) | 4,248 | Snapshot validation, journal decoding, recall projection, receipts, persistence, and publication share a module. |
| [runtime.ml](../../lib/runtime/runtime.ml) | 4,060 | Runtime publication and configuration edits share their policy and effect boundaries. |
| [runtime_toml.ml](../../lib/runtime/runtime_toml.ml) | 3,480 | Many independent configuration decoders; size alone does not show a faulty boundary. |
| [workspace_task_transitions.ml](../../lib/workspace/workspace_task_transitions.ml) | 1,153 | Lifecycle decisions, commit compensation, and post-commit projections interact. |
| [runtime_provider_usage_window.ml](../../lib/runtime/runtime_provider_usage_window.ml) | 1,008 | Provider decoders and the mutable observation store share a module. |

These counts describe the reading context. They are neither quality gates nor
targets for arbitrary file splitting. The selected Memory OS module also has an
859-line interface; preserving that public contract while narrowing internal
responsibilities is more useful than reducing a line count alone.

## Reference principles and their repository application

- [OCaml Programming Guidelines](https://ocaml.org/docs/guidelines) supports
  readable named functions, coherent modules with explicit interfaces, and
  exhaustive matching. Here, responsibilities should have small interfaces and
  domain alternatives should remain typed; implementation history should not
  obscure the current contract.
- [OCaml Error Handling](https://ocaml.org/docs/error-handling) describes `option`
  and `result` for expected failures. Here, malformed snapshots and journal rows
  must preserve their existing classified errors instead of becoming empty data
  or escaping through unrelated exceptions.
- Jane Street's [Effective ML](https://blog.janestreet.com/effective-ml/) lecture
  summary emphasizes readers, uniform interfaces, meaningful types, and
  exhaustiveness while cautioning against elaborate type tricks and purity for
  its own sake. Here, use ordinary records, variants, and collections to make
  data flow visible.
- [Real World OCaml: Files, Modules, and Programs](https://dev.realworldocaml.org/files-modules-and-programs.html)
  explains how signatures hide representation choices. Here, a codec or recall
  module should export only what its actual consumers need.
- [Real World OCaml: Imperative Programming](https://dev.realworldocaml.org/imperative-programming.html)
  explains both the reasoning benefits of pure code and the practical role of
  mutation and I/O. Here, immutable projections should return their results;
  locks, caches, atomic publication, and filesystem operations retain explicit
  effect-owning boundaries.

These are applications to MASC, not a request to add Base/Core, eliminate every
mutation, or introduce a generic parsing or persistence framework. Existing
libraries and simple local functions are preferred when they express the domain.

## Selected work: Memory OS current state

Status: **implemented in three source-review layers; type checking and execution remain unverified**.

At baseline, `keeper_memory_os_current.ml` combines the following responsibilities:

| Responsibility | Baseline source coordinates | Implemented boundary |
| --- | --- | --- |
| Snapshot wire format and consistency checks | Lines 816–1259 | [Snapshot codec](../../lib/keeper/keeper_memory_os_snapshot_codec.mli); field validation, fact order, canonical bytes and abstract rejection remain together. |
| Journal wire format and row classification | Lines 1299–1553 and 4165–4201 | [Journal codec](../../lib/keeper/keeper_memory_os_journal_codec.mli); committed, failed and quarantined rows, rewrite evidence and dashboard projection. |
| Successor traversal | Lines 3488–3558 | [Successor recall](../../lib/keeper/keeper_memory_os_successor_recall.mli); immutable revision Map, returned accumulators and explicit direct/following lineage. |
| Reads, writes, locking, recovery, and publication | Remaining persistence paths | Keep effect ordering and recovery authority in the current-state owner. |

The snapshot types already live in
[keeper_memory_os_current_types.ml](../../lib/keeper/keeper_memory_os_current_types.ml),
and support semantics already live in
[keeper_memory_os_support_core.ml](../../lib/keeper/keeper_memory_os_support_core.ml).
The new modules use these existing dependencies. The private type owner also
contains the admission binding and successor evidence/result types; the public
current-store interface remains unchanged.
The separate [keeper_memory_os_recall.ml](../../lib/keeper/keeper_memory_os_recall.ml)
is the recall rendering/revalidation consumer; it is not the journal reducer.

The successor projection replaces a local hash table and four references with
an immutable revision Map and fold results. Its internal `Direct | Following`
state replaces the independently optional original fact and path. Duplicate
rewrite validation, frontier ordering and unresolved-result deduplication retain
their previous meanings. Canonical JSON field-set validation replaces the
store and journal's repeated field-count logic. No Base/Core dependency was added.

Persisted data, authoritative reads, cancellation, receipt recovery and
notification ordering remain behavioral constraints. The store still owns
receipt codecs, publication recovery, journal traversal and cache updates; these
were not silently folded into this scope. The broader repository audit remains
open under [#41857](https://github.com/jeong-sik/masc/issues/41857).

Existing scenario coverage is in
[test_keeper_memory_os_current.ml](../../test/test_keeper_memory_os_current.ml).
Its cases include snapshot rejection, prepared-receipt recovery, unchanged
recommits, missing journal revisions, external cache invalidation, multistep
successor splits, and prevention of retired-fact revival. Those scenarios define
the relevant review surface; their presence is not a claim that they were run.

## Further candidates, outside this implementation

| Candidate | Concrete refactoring opportunity | Consumers and existing tests | Main risks |
| --- | --- | --- | --- |
| [Provider usage observations](../../lib/runtime/runtime_provider_usage_window.ml), lines 858–1008 | Replace nested mutable window/snapshot tables with an immutable per-scope reducer returning next state and accepted report evidence. Keep locking and observer delivery outside that reducer. | Writers: [runtime_provider_usage_read.ml](../../lib/runtime/runtime_provider_usage_read.ml), [keeper_codex_runtime.ml](../../lib/keeper/keeper_codex_runtime.ml), [keeper_claude_code_runtime.ml](../../lib/keeper/keeper_claude_code_runtime.ml). Scenarios: [test_provider_usage_windows.ml](../../test/test_provider_usage_windows.ml), especially lines 217, 509, 530, 927. | Preserve complete versus sparse reports, stale observation rejection, empty snapshots, and delivery after releasing the mutex. |
| [Task transitions](../../lib/workspace/workspace_task_transitions.ml), lines 86–734 | Return a typed commit receipt instead of communicating verification submission through the reference at lines 148, 428, and 694. Extend the existing pure [transition executor](../../lib/workspace/workspace_task_transition_executor.ml) with explicit projection decisions. | Consumers: [tool_task.ml](../../lib/task/tool_task.ml), [workspace_goals.ml](../../lib/workspace_goals.ml), [workspace_task.ml](../../lib/workspace/workspace_task.ml). Scenarios: [test_task_transition_broadcast.ml](../../test/test_task_transition_broadcast.ml), [test_verification.ml](../../test/test_verification.ml). | Preserve request compensation, cancellation propagation, and notification after an already committed transition even when a later projection fails. |
| [Runtime lane edits](../../lib/runtime/runtime.ml), lines 3270–3454, and [configuration text edits](../../lib/runtime/runtime_config_text.ml), lines 308–478 | Express create/set/rename/remove as typed pure edit requests and results. Resolve and rewrite references in one transformation; retain CAS, locking, and publication in Runtime. | Consumer: [dashboard HTTP routes](../../lib/server/server_routes_http_routes_dashboard.ml), lines 1092–1168. Scenarios: [test_runtime_per_keeper_routing.ml](../../test/test_runtime_per_keeper_routing.ml), lines 1219–1639, and [test_fusion_config_edit.ml](../../test/test_fusion_config_edit.ml). | Preserve lane/runtime name shadowing, default and Keeper assignments, Fusion references, inline-table refusal, and revision conflicts. |

These are inspected opportunities, not findings that their current behavior is
incorrect. Each needs its own bounded scope and current-head review before work.

## Evidence and verification scope

| Changed boundary | Direct consumer | Relevant behavioral suite |
| --- | --- | --- |
| Snapshot source/change/snapshot codecs | Store reads, snapshot digest and publication bytes | `test_keeper_memory_os_current` |
| Journal codec and dashboard rows | Append/recovery, revision evidence, dashboard journal | `test_keeper_memory_os_current`, `test_keeper_memory_journal_projection`, `test_librarian_journal_failures` |
| Successor projection | `read_successor_recall_for_keepers_dir` and resolved selection | `test_keeper_memory_os_current`, `test_keeper_memory_successor_selection`, `test_keeper_memory_resolved_selection_replay` |

Two store-level scenarios were added: identical versus conflicting duplicate
rewrite evidence, and simultaneous direct/revised/retired binding outcomes.
They extend the existing split/re-add/phantom-edge scenarios and have not been
executed in this coding session.

- OCaml 5.5.1 syntax parsing passed for changed `.ml` and `.mli` files using
  `ocamlc -stop-after parsing -impl <file>` or `-intf <file>`.
- Public `keeper_memory_os_current.mli` is byte-identical to the baseline.
- Snapshot source comparison found identical moved logic after explicit module
  qualification. Independent source review found no P0/P1/P2 in code commit
  `e47974bcaa2ab9628103e63242947534ff420894`; its later delta only removes an
  extra trailing blank and adds the PR changelog.
- Journal source comparison found 20 moved declarations and 166 remaining
  declarations unchanged apart from module qualification, plus the equivalent
  strict-field predicate. Independent source review found no P0/P1/P2 in
  `1d7548873c54e410b53515c7c7a7cdc82e23e1eb`.
- Independent successor code/test source review found no P0/P1/P2 in
  `07ce914351bf1259433c35ea71c2a261c924dea9`, including duplicate rewrite
  evidence, frontier ordering, mixed binding outcomes and moved type identity.
  That reviewer authored the initial audit prose; this is not an independent
  formal approval of the whole layer.
- `git diff --check` passed over the complete stack; all 31 local documentation
  links resolved. These checks do not establish type correctness or behavior.
- Type checking, compilation, focused test execution, CI, formal GitHub approval,
  merge, installation and runtime/UI behavior are **not verified** by this work.
  The external coding-session protocol excludes local Dune builds and CI polling.

The ordinary stack is ready for review of these boundaries. Before a release,
run the relevant suites through the repository release verification procedure.
Future-candidate coordinates above remain observations of the stated baseline;
re-read those sources and open PRs before starting a subsequent slice.
