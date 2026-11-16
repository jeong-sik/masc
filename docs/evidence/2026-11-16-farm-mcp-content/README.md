# Farm WIM-S04: attached MCP result preservation

This is a local source candidate, dated 2026-11-16. It does not establish live
MCP interoperability or complete WIM-S04. The remaining Farm scope is tracked
in the [execution record](../../reports/2026-11-16-agent-farm-execution.md).

## Candidate boundary

The parent is `f2d871b18cf41bb0140cf9c45acbfd5f1ad1838e`, above the WIM-S03
document capability changes. The implementation is on the local native stack
branch `feat/farm-mcp-content-20261116`, at source head
`fb6858311cc67bc743d7c0fcbe9165dbffc2dbc3`. Its three implementation commits are
`3ef8d223128c9d7322b1a1db1f83270433f488b2`,
`c98ac00e06953acf6f026e1e85f82594afa2ac08`, and that final head.

Previously, attached MCP results and their approved replays used a text-only
view. The candidate decodes the SDK's content variants through one shared
projection. It validates audience annotations before the SDK's permissive
decoder can turn an invalid audience into an unrestricted one. Duplicate
fields and malformed payloads return an explicit projection failure. Valid
generic binary resources remain byte artifacts, including missing MIME and
empty files; they are not coerced into native documents.

The received `content`, optional `structuredContent` and `isError` are stored
before model projection. This is the received field set exposed by `Mcp_client`,
not an exact HTTP response or complete JSON-RPC envelope: the client already
discards top-level `_meta`. The raw artifact has an empty preview and belongs
to the invocation's retained roots, or to the approval owner's replay-result
sidecar. Its reference is excluded from the immediate model result, producer
metadata and the latest-call status projection. Operator audit and telemetry
readers retain access; this is an audience projection, not a filesystem access
control system. Model artifacts contain only assistant-visible text or
individual visible media.

## Delivery and ownership

| Boundary | Candidate behavior |
| --- | --- |
| Ordinary invocation | Requires an execution identity before making the external call; registers received bytes with that invocation |
| Approved replay | Carries references from `Keeper_tool_execution` through settlement and pending repair into the existing replay-result sidecar; model/chat projections select only the visible output reference |
| Text and structured content | Both remain in authoritative blocks; large text becomes a retained text artifact reference |
| Native image | Requires frozen runtime admission, the Core wire capability where applicable, and a MIME type accepted by the existing image transport |
| Other visible media | Audio, PDF and unsupported images become references to their actual decoded bytes; original MIME remains in the description |
| Generic resource blobs | Preserve bytes and the original MIME declaration or its absence; reserved internal MIME labels are not granted to external bytes |
| User-only content | Retained for the execution owner; excluded from model text, blocks and model-readable artifacts |
| Resource links | Remain references; conversion performs no URI fetch |
| Remote error or local projection failure | Remains a failure with unknown external effect and no automatic retry; visible error media uses artifact references |
| Deferred tool loading | Resolves current and carried names to closures built for the selected runtime; receipt ownership remains shared |
| Client result size declaration | Attached media no longer claims the text threshold bounds the entire result; text externalization still uses the lane's threshold |

Public children are owned through the existing typed artifact-manifest format.
Only producer-created byte references enter its structured child list; remote
structured JSON stays text, and the private received envelope is excluded.
Canonical tool and approval inputs carry an exact marker, not only a reference
embedded in prose. Gate settlement reuses the explicit model artifact instead
of hiding its references inside another plain-text blob. The ordinary error
result's exact marker keeps the unknown-effect warning in its inline preview
and stored body. Gate normalizes reference previews to empty; its approved
replay still carries the stored warning and typed indeterminate outcome.

Official-client continuation does not write a Core checkpoint. Before a spent
sidecar retires, cleanup requires its public replay reference in the canonical
chat ledger, which is outside dated audit pruning. A new row must complete its
durable append; an existing ordinary/correction row is re-read under the held
descriptor, compared exactly and fsynced. Setup or confirmation failure leaves
the sidecar in place. Explicit Keeper removal keeps its existing semantics.

This preserves wire blocks where supported and exposes exact bytes elsewhere.
It does not automatically invoke an image/PDF/STT reader, add native audio or
document tool-result support to every provider, or prove that any provider
consumed the result. Approved replay conservatively uses media references.

## Review and checks

Independent reviewer `continuity_audit` bound its final source verdict to
`fb6858311cc67bc743d7c0fcbe9165dbffc2dbc3` versus the recorded parent. It found no
remaining actionable P0/P1/P2 in the 41 source/test files. The reviewer changed
none of those files. This is not a GitHub approval, typecheck or runtime verdict.
The combined binary diff SHA-256 is
`e2731b69f10a113c8cead0560f6645224b3ff708a873f9949e9c874eb4acc484`.

Source corrections identified during review
include the test module's wrapped-library alias, empty media, MIME case and
parameter handling, usable visible error media, status exposure of private
audit references, and retention loss in the production approval replay caller.
The follow-up also addresses child ownership after interim owners retire,
generic binary resources, and reserved MIME authority for external bytes.
The final correction covers visible-but-unsynced chat rows left by append and
rollback failures, rather than assuming that an existing row is durable.

All 38 changed OCaml files passed `ocamlc -stop-after parsing -c <file>` with
local OCaml 5.5.1; the repository pins 5.5.2. `git diff --check` passed.
The [syntax receipt](syntax-receipt.json) records all 41 source/test file hashes,
the combined diff and individual parse outcomes. It was captured before the
final commit, with parent `c98ac00e`; its content matches the committed head.
Its source manifest SHA-256 is
`8c993d3d1aed581224c7fbfe2ce8b456761ab6af30f614fc317fb0fa09a54193`.
The receipt is copied without modification from
`artifacts/farm-mcp-content-20261116/parse-results-8c993d3d1aed.json`.
Parsing is not typechecking.
No Dune build, executable OCaml test, real MCP service call, provider request,
restart, installed binary or UI check has run for this candidate.

Written focused cases cover decoder variants and malformed inputs, normal and
approved calls, user-only content, stored byte readback, post-tool log retention,
missing execution identity, remote errors, projection/storage failure, generic
binary resources, reserved MIME authority, truthful result bounds, history-only
ownership after interim stores retire, and chat fsync/rollback failure repair.
Planned executable targets are
`test_keeper_mcp_content`, `test_keeper_identity_gate`,
`test_keeper_identity_tools`, `test_keeper_identity_transports`, and
`test_keeper_attached_tools_lane_scope`, `test_keeper_gate_replay`,
`test_keeper_approval_queue`, and `test_keeper_approval_input_admission`.
These are not executed results.
The latest full regression run/head/TARGET_SUITES have not been verified in
this work unit; full regression for this candidate is unrun.

## Publication and remaining evidence

Earlier submission of this native stack failed with local GitHub CLI token
absence. In this agent command environment, a later `gh api user` failed to
connect, DNS lookup failed for both GitHub hosts, and the standard credential
lookup returned no token. `gh auth status` displayed an invalid-token message,
but these observations do not establish that the user's account or interactive
terminal login is invalid. Connector reads do not supply credentials to
`gh stack`. No PR,
GitHub approval, merge or deployment is established by this record. Refresh
remote main, native stack membership and overlapping work before publication.
The later connector snapshot of main was
`6a9d80085e11ee8a76eeae3e0841a38d8eb24313`, 18 commits after the shared
`85f2823f` base. It overlaps this candidate in `test/dune` and
`test/test_keeper_tool_dispatch_runtime.ml`; no integration/rebase verdict has
been issued for that snapshot.

Remaining evidence includes executable tests on this source, actual media from
an MCP service, provider requests and responses, restart and garbage-collection
retention, and multiple Keepers using independent execution identities. The
external interpretation path and other WIM-S04 requirements remain open.
