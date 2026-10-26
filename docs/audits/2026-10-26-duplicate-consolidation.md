# Duplicate policy consolidation — 2026-10-26

Tracking issue: [#46156](https://github.com/jeong-sik/masc/issues/46156).
Native Stack: #46165, ordered #46158–#46164. Each layer removes one duplicated implementation group.

## Scope and preserved contracts

| PR | Canonical owner | Removed duplication | Contract retained |
| --- | --- | --- | --- |
| #46158 | Keeper_skill_async_delivery | Composition invocation equality and JSON encoders | Exact tool-use id, turn, schedule, completion and JSON field order |
| #46159 | Keeper_event_queue_state.equal_pending_selection | Owner/handoff comparators | Both admission revision and source snapshot identity; metadata remains diagnostic |
| #46160 | Executable_path.regular_file_is_executable | Browser setup/dependency file predicates | Direct path stat, symlink following and regular-file execute permission; lookup order and absolute reporting unchanged |
| #46161 | Mcp_error_code.is_http_error_response | Transport/route copies and forwarding interfaces | Explicit null id, recognized integer code and typed null-id policy; H1/H2 share the same predicate |
| #46162 | Channel_gate_binding_store.bind/unbind | Slack/iMessage/Discord mutation callbacks | Validation ordering, exact expected-owner match, sorted replacement, audit clock inside durable transaction and rollback |
| #46163 | Keeper_official_client_host | Antigravity/Muse message rendering, carried projection and prompt framing | Start/Resume context, Muse historical-task input, per-call buffers and front-then-window observations only after final projection succeeds |
| #46164 | Lane_addon_companion_persistence | Origin/publication owner checks, creation lock and existing-leaf predicate | Distinct publication-owner/JSONL lock inodes, before/held/after identity, caller-owned typed errors, release and cancellation semantics |

The scope is these seven groups. Connector stores, transports and status serialization remain separately owned. Telegram keeps its generic transaction API because its channel-id, absent-unbind and stale-owner behavior differs.

No new registry, runtime admission gate, budget, TTL, timeout or compatibility facade is introduced. The removed runtime test-only aliases are replaced by tests of the canonical production API.

## Verification

Two independent source-review sessions inspected all seven groups and their direct consumers. They reported no P0/P1/P2 findings. The 39 reviewed source-file contents were unchanged when the stack was rebased onto main; the reviews are source evidence, separate from formal GitHub approval.

Lightweight checks:

- Changed OCaml interfaces, implementations and directly affected tests parse under OCaml 5.5.1.
- Whitespace checks pass.
- Actual Mcp_error_code and Executable_path interfaces and implementations compile natively with the repository's strict production warning flags.
- The existing test_mcp_error_code suite passes **13 tests**, including assertions on actual generated null-id/version/identified-request wire envelopes.
- For the isolated test run only, the copied test's namespace line changes from "module C = Masc.Mcp_error_code" to "module C = Mcp_error_code". The compiled leaf is the actual changed production source. No assertions are removed or weakened.
- Test compilation uses the existing test/dune warning policy, including its test-only warning 4 override. Production leaf compilation retains strict root warnings.

The portable [native leaf receipt](../evidence/2026-10-26-duplicate-consolidation/native-leaf.json) records source hashes, commands and the namespace adaptation.

These checks do not compile or link the full server, browser or Keeper paths. Full Dune build, linked Keeper/connector tests, CI and live runtime/volume/deployment verification were not performed for this consolidation. Source review and the narrow native checks must not be reported as those broader results.

## Review focus

Recheck the exact current head, direct base and complete diff for every layer. A review of one layer is not approval of the entire stack. Any future native stack merge must include all seven reviewed layers through top PR #46164 once.

The highest-risk contract is Companion ownership: shared code must continue to validate the same stable inode around the admitted callback and must retain Commit_unconfirmed on uncertain release. Wall-clock age must not authorize releasing an unsettled operation.
