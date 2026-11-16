# Farm WIM-S04: attached MCP result preservation

This is a local source candidate, dated 2026-11-16. It does not establish live
MCP interoperability or complete WIM-S04. The remaining Farm scope is tracked
in the [execution record](../../reports/2026-11-16-agent-farm-execution.md).

## Initial candidate boundary

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
At that checkpoint no Dune build, executable OCaml test, real MCP service call,
provider request, restart, installed binary or UI check had run for this
candidate. The later Core media execution below does not execute these MCP
consumers.

Written focused cases cover decoder variants and malformed inputs, normal and
approved calls, user-only content, stored byte readback, post-tool log retention,
missing execution identity, remote errors, projection/storage failure, generic
binary resources, reserved MIME authority, truthful result bounds, history-only
ownership after interim stores retire, and chat fsync/rollback failure repair.
Executable targets planned at that checkpoint were
`test_keeper_mcp_content`, `test_keeper_identity_gate`,
`test_keeper_identity_tools`, `test_keeper_identity_transports`, and
`test_keeper_attached_tools_lane_scope`, `test_keeper_gate_replay`,
`test_keeper_approval_queue`, and `test_keeper_approval_input_admission`.
That list was not an executed result. The later projection-only execution is
recorded below; the remaining consumer suites are still unrun.
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

Remaining evidence includes the other consumer tests, actual media from
an MCP service, provider requests and responses, restart and garbage-collection
retention, and multiple Keepers using independent execution identities. The
external interpretation path and other WIM-S04 requirements remain open.


## Earlier rebased source checkpoint — 2026-11-16

The whole five-layer native stack was rebased onto
`e0e819e29968366c1dffb59ad625ba4e17d4ac22`. MCP source at that checkpoint was
`23508a998d3b559334c8b127cc14aad7c5244b82`; the integrated documentation checkpoint
reviewed before this evidence update is `980892260bf73193e8251b0ac1d54bedf6ad76f0`.
Independent changed-base review by `continuity_audit` found no actionable P0/P1/P2
in the complete 79-path scope and direct consumers. Seventy-three files retain
old bytes; six integration paths changed. The sole native rebase conflict was
resolved by keeping main's four appended test includes and the MCP include once.

The review retained main's connection-failure variants and official Gate resume
refusal. Transcript observation caching does not authorize replay-root cleanup:
that path still validates the held complete transcript bytes and confirms
existing storage before retiring the sidecar. Same-turn request stubbing does
not replace canonical media retention. These are source findings, not runtime
execution or GitHub approval.

The new receipt has five changed OCaml parses, a compiler-version check and a
whitespace check: seven successful commands. It does not re-run the old full
syntax set, compile types, execute the listed MCP suites or prove installed
behavior. Full-stack diff SHA-256 is
`ec79f302706a76e2f953b0436d27cff91831485b0fbc3db93fd78b81c41c9716`;
local rebase receipts are under the main worktree's ignored
`artifacts/farm-publication-rebase-20261116/execution-1/`.
The dated old-head evidence above is retained unchanged. No remote push,
submission, merge or runtime change was performed by this rebase.


## Stack checkpoint after the Core compile correction — 2026-11-16

The reviewed base is still `e0e819e29968366c1dffb59ad625ba4e17d4ac22`.
At that checkpoint Core was `db69904f29c6f4a6166957fbdffa4f7e8e910a7a`, MASC was
`01c94838471b1cbff986e5a78f2c14597a8df564`, and MCP source was
`e392aa3a7f8fafdfe18045c92bc0fe1d023e44b5`. The integrated top at that
checkpoint was `6134e0a42aae676f63143d1473aaeca7fb99053f`.

Three Core files were corrected after real compilation: the generic document
projection implementation/interface and its existing media test. The interface
file `api_common.mli` is an additional path beyond the earlier 79-path review.
The earlier changed-base review remains historical; separate independent reviews
cover these corrections. Current combined scope is 80 paths. Fixes belong to
the Core bottom layer, and `gh stack rebase --no-trunk` carried all five layers
without changing the reviewed base. MCP implementation bytes were not changed
by that correction. No push or new-main integration is implied.

The complete existing Core media suite then passed all 18 cases under actual
OCaml 5.5.2. Its 118 source inputs and nine metadata inputs match the final
committed leaf; compilation/link failures from earlier runs remain recorded.
The exact scope, source/result hashes and ownership of reused objects are in
[the document-input record](../2026-11-16-farm-document-input/README.md#current-committed-core-correction-and-execution--2026-11-16)
and the document worktree's
`artifacts/farm-core-media-document-20261116/final-summary.json` and
`restack-3/terminal.json`.

Those tests exercise Core admission and codecs; they do not execute the MCP
consumer suites listed above, approval replay/restart/GC, a real MCP service,
provider HTTP, PDF/STT, installed MASC, UI or full Dune. The projection suite's
separate later execution follows below. The latest agent `gh api user` still failed to connect
(exit 1); it is an environment observation, not proof of invalid user credentials.
PR publication, GitHub approval, merge, deployment and original recovery are
not established. The full Farm scope and `U02:IA-S13` old-volume approval remain
unchanged in the [execution record](../../reports/2026-11-16-agent-farm-execution.md).

## Actual MCP content projection — 2026-11-16

The unchanged `test_keeper_mcp_content` suite passed all eight cases, with no
skips, at fixed head `ad6ba29aec18597a474bdaa717517ca5b3c1261c`. Final `run-4`
records 16 successful commands under OCaml 5.5.2. Its 239 original inputs are
89 ML files including the test, 144 original interfaces and six C files. Ninety
inputs belong to Core, but only 16 Core implementations enter the native runtime
closure. This is a bounded suite build, not the earlier 635-file inventory or a
whole Core/MASC build.

The cases exercise actual SDK decoding, mixed text/media/structured order,
audience filtering, malformed annotations and duplicate fields, resource links,
embedded binary resources, and diagnostics that do not echo payloads. The
captured SDK is `mcp_protocol v0.12.0-48-g24ee1d3`. `Agent_core.mli` remains the
real public interface; `Mcp_client` and other type-only dependencies use their
original interfaces. All required value dependencies use complete original
implementations. Normal namespace aliases preserve separate Core/Base/MASC
units; no partial facade, replacement implementation or extracted function was
used. Linking storage implementations does not mean these cases exercised
durable storage.

Three earlier compiler failures were missing-interface scheduling errors in
the standalone runner and remain recorded. No product change was needed.
Run-4 reused verified successful objects from earlier attempts in this unit,
then freshly compiled and linked the test with its normal empty executable
interface and test warning policy. It did not reuse Core18 or repository
`_build` objects. The repeated run-3/run-4 execution is eight cases, not sixteen.
All 377 final outputs had identical hashes before and after the final test;
318 imported CMI bindings were checked. Package content hashes were collected
after execution, while compiler environment and package discovery were recorded
before compilation. Standalone package visibility is broader than Dune's, so
this is not a Dune dependency-declaration verdict.

The local record is `artifacts/farm-masc-consumer-20261116/next-unit-2/` in the
document worktree. Its `receipt-manifest.json` SHA-256 is
`bbe257ca010dec201ae8eba6192b61c4d331af1f070e4603debd74782d2f3ff3`;
`run-4/source-manifest.json` is
`0b45ef55d1e125cf6750075f851034220930d4891729d4e37753a2d5aa7ce5fa`, and
`run-4/results.json` is
`88d020f9836a7e65a903f539fd0132c6c45749487d2837e02a368f18846266dc`.
The document update checked the 34 sealed receipt files and all 239 current
source hashes without rerunning tests. The separate `root-receipt-review.json`
also binds the 239 Git/copied/current inputs and 377 outputs to this execution;
it is a receipt review, not another run or a GitHub approval.

Normal MCP invocation, Gate replay/pending repair, raw/public artifact ownership
and GC, H5, official-client transport, real MCP/provider traffic, full TUI,
installation, Linux and full Dune/CI remain unexecuted by this suite.

The publication handoff preserves its original 53 files for Schedule3 plus
Document5. The separate main-checkout
`artifacts/farm-publication-handoff-20261116-update.json` records subsequent
documentation and owner-layer corrections with the current complete stack refs. The packet
and update note must be read together. Fresh remote main, exact refs/PRs, semantic duplicates and REST stack
inspection remain required before publication. The latest outbound handoff's
transport failed and delivery is unconfirmed; this local evidence does not
establish a PR, approval, merge or deployment.

The later MASC test correction restacked this unchanged MCP patch to
`4202159afd7cdbc9259296ceb09f7fa8f6c0d05f`; the resulting leaf before this
documentation update is `d18a8aa8eeb625087e8862fd4140efc23d658483`.
The complete tree delta from `d1ede6aa` is one Yojson match arm in the separate
provider materialization test. All 239 source inputs of the executed projection
suite still match the new Git head and worktree; this was a source binding check,
not a rerun. The [document-input record](../2026-11-16-farm-document-input/README.md#masc-test-correction-and-consumer-source-audit--2026-11-16)
holds that correction's independent review and limits.

A separate fixed-head source trace confirms that normal call roots remain in
the invocation carrier until the tool log commit callback clears them. The
current in-server blob sweep records candidates without deleting them. Neither
observation proves recovery across a crash between blob publication and durable
ownership, or the offline maintenance interaction. Local trace:
`artifacts/farm-mcp-retention-audit-20261116/`. The maintained identity-tools
40-case continuation stopped at the boundary described below. It has no
executed test result.


## Identity name-owner correction and compiler frontier — 2026-11-16

A sixth native layer follows the original five. Its source candidate before
this evidence update is `77ef965413357353084b6bd2d0833ddd8e5f41e3`, parent
`f50713a3bc9c55e7d542a0928ea0c7f20a94cd4a`. Three references in two files now
use existing defining modules: approval policy reads the validated public
search schema's name, and GitHub credential entrypoints use the public
Keeper name validator directly. No API, test fixture, permission rule or
registration source changed. The full two-file independent source review
found no additional P0/P1/P2; it does not certify every original stack layer.

The two actual product implementations and the entire original 40-case test
module compiled at that candidate. Product public CMIs are byte-identical;
new native imports remove the policy's direct Search implementation edge and
GitHub identity's direct Keeper_config edge. These are dependency facts, not
execution coverage or proof that every Runtime/Slack/SSE path is gone.

The first continuation passed the former policy→Search→Agent boundary, then
stopped because the standalone runner had not generated the real SSE type
module `Sse_event_t`. Its native graph also reached substantial lifecycle and
Runtime configuration code. It was not broadened into a full archive or a
fake implementation. The principal `Keeper_identity_tools.ml` implementation
has not yet been compiled by this unit. Final test linking remains incomplete:
**0 of the original 40 cases executed**. No subset was selected to claim a pass.

Inspection also found that earlier test ML compilation overwrote a separately
generated empty interface, producing an inferred CMI with 81 exports. The
original complete test was recompiled with normal `-intf-suffix .ml` metadata;
its CMI now has zero exports and is unchanged by implementation compilation.
Earlier receipts retain that interface limitation. The final check verifies
current interface imports and opaque native clients; historical complete
installed-archive byte identity and final link compatibility are not claimed.

Local receipts are under `artifacts/farm-mcp-identity-consumer-20261116/`:
`candidate-frontier-1/` retains the stopped broad graph, and
`owner-import-final-1/` retains the final bounded compile/import check.
The latter seal is
`2846a59cecb5c0cfd7bb15359b4bd08db84727a06ef5e48152c7661f6b27d30b`.
Source review is in
`artifacts/farm-policy-tool-name-20261116/independent-review-surface-2/`.
Publication must inspect the complete current six-layer membership, not submit
only the old five-layer packet. Publication and installed behavior remain
unconfirmed; the original Farm requirements and scale matrix remain open.
