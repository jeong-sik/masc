# Durable scheduled requests: source repair and actual runtime limits

This bundle keeps source approval, focused tests, native production and actual
behavior separate. **The scheduled Job feature does not have an overall PASS.**
The new DeepSeek run exposes a real request-scope failure even though its durable
queue and three intended note writes complete.

The [59-row behavior audit](../../audits/2026-10-26-scheduled-job-coverage-update.md)
retains its original row IDs/order and earlier counterexamples. This update
adds evidence to rows 36 and 50; it does not promote the remaining UI, external
delivery, multi-account or long-running calendar gaps to verified behavior.

## Which source ran

Original delivery PR [#46272](https://github.com/jeong-sik/masc/pull/46272), head
`2d8fa7543519c5c58be056f3460a2a06e76c2730`, moves the admitted exact scheduled
request from transient world context into ordinary durable user input. It adds
instance identity to the existing formatter; it does not introduce another
scheduler, retry policy, effect permission or cancellation mechanism.

The separate frozen Draft [#46274](https://github.com/jeong-sik/masc/pull/46274),
head `a3950a189b9cc5a7ce82cb725699455d79923f42`, is a **duplicate-source proof
candidate, not a merge target**. Twenty original commits from six source PR
slices were replayed without conflict resolution on base
`9377c7f3025d68e3856d2afd3762468dabc77813`. Each commit and complete PR slice
matches its original raw path/mode/blob identity. Selection and assembly are
retained in the [candidate assembly bundle](https://github.com/jeong-sik/masc/blob/a3950a189b9cc5a7ce82cb725699455d79923f42/docs/evidence/2026-10-27-schedule-durable-candidate/README.md)
on the frozen candidate branch. Final candidate raw diff identity is
`f788700dc3d98107279cd5010816ee9f8d8e6be1d6de1a3495949819db970e59`.

Every actual run below used that candidate's server SHA256
`1622a35d1082da4fe24d9effb05aec11918d9444288441049c8d6d30cedb415c` in a fresh
owned workspace and port. The operational primary was not replaced or installed.

## Results and their boundaries

| Evidence | Observed result | Limit |
| --- | --- | --- |
| [Focused CI](focused-ci/README.md), Test40394461863 on original source head `2d8fa754…` | 44 + 66 = **110 PASS**, fail0/skip0 | Two selected suites; not full CI or a combined-head test run |
| [Native producer](producer/README.md), Minimal manual checks40396800146 | Successful macOS artifact; original archive/receipt hashes and actual server/TUI CLI build commits match | Execution definition is main `9377c7f…`, explicit source input is `a3950a1…`; Addon scenario success is not scheduled-model success |
| [Actual settlement fault trial2](settlement/README.md) | Queue permission refusal and primary-ledger staging failure; same PID preserves pending intent, settles original Retry after repair, then next cadence admits exactly one fresh attempt | Bounded actual PASS; no model execution or process-death survival of in-memory intent |
| [Actual GLM trial1](glm/README.md) | Exactly A1/B/A2; original A is retained/readmitted; A3 reads the canonical B-result blob before writing A2; post-discovery input retains the exact requests | Original observer **FAIL remains**: it only accepted a redundant fresh notes_list. Separate saved-evidence review establishes the canonical read and selected lineage; it does not manufacture an original normal-exit controller PASS |
| [Actual DeepSeek trial1](deepseek/README.md) | Exactly three notes/calls and correct source retention/readmission, but **A2 is executed inside B turn2**, before A readmission; resumed A turn3 has no execution IDs | Original **FAIL is a real request-scope failure**: B explicitly forbids performing A's remaining steps. Count-correct effects are insufficient |

Both models retain the scheduled body in their available latest post-tool
provider-input snapshots. The old D9 GLM request-loss and DeepSeek fourth-write
counterexamples in the [earlier bundle](../2026-10-27-schedule-after-effect-models/README.md)
remain unchanged. A new run does not erase those results.

The DeepSeek failure is distinct from a new security-authorization bypass.
The current collaborative note API stamps the caller as author and checks
schedule existence; it does not enforce a typed current-scheduled-source-only
append permission. This run establishes a behavior-scope violation. A proposed
active-work identity must remain separate from Gate/effect authority; merely
adding a prompt reminder cannot establish hard isolation. Blanket restrictions
on cross-schedule notes would change the existing collaboration contract and
require a separate design decision.

The observed request-scope gap is tracked in
[issue #46281](https://github.com/jeong-sik/masc/issues/46281). Its reproduction
retains B's explicit restriction and the A2/B-turn execution identity; a later
repair must not reduce the oracle to three-note cardinality alone.

## Reviews

Original source #46272 has current-head guard-backed APPROVE
[5658809011](https://github.com/jeong-sik/masc/pull/46272#pullrequestreview-5658809011),
base `25b6f164b20610e6b301810d00c23e386fa6e332`, raw diff identity
`a810a02864fc3afe78c7279e83e65663843a151bd960334a6959b58e788103c1`.
The earlier Draft-only COMMENT and procedural correction remain distinct from
that approval. The reviewer subsequently verified the focused-test archive and
counts. Source approval does not certify either model's task semantics.

Independent local review checked the full combined source and metadata at
`a3950a1…`; separate reviewers inspected the actual GLM canonical-read chain,
the actual settlement causes and state transitions, and the actual DeepSeek
turn/source failure. The controller author is not presented as its independent
reviewer. MASC received the new DeepSeek counterexample for a further exact-head
scope review; a queued or running request is not its completed verdict.

## Capture and retention

The subdirectory manifests distinguish byte-exact copied captures from selected
or sanitized derivatives and record consumed original hashes/lengths. An
original controller capture may itself contain selected/sanitized data; the
word `original` does not make it raw HTTP. Full private prompts, reasoning,
credentials, health documents and checkpoint histories are not published.

Exact executed controller versions are retained as text for review. New runs
belong under a checkout's ignored `artifacts/`, with fresh owned output paths;
do not run these retained sources in place or rewrite their original outcomes.
Preflight-only checks do not start a producer or access model credentials.

Earlier full checkpoint files were overwritten or pruned. Historical hashes
and original selected lineage captures remain observations, not reconstructed
bytes available for independent replay. Snapshot-part verification covers the
available latest captured requests, not every provider request, first complete
wire body or provider acceptance. A repeated A request in the third turn's
durable history is not claimed to appear exactly once across all turns.

After each model observer stopped with FAIL, root independently observed both
exact sources Completed, target idle, no pending entries and three notes, then
sent SIGTERM only to that verified owned experiment. Process disappearance and
no forced kill are recorded. Root was not the producer's parent: **producer exit
status is unknown**, not exit0. The separate settlement controller observed its
own child exit0 and restart count0.

No operating installation, merge, visible TUI/F9/OS notification, arbitrary
external-effect exactly-once, multi-user security isolation, model/account
failover or whole-feature completion is claimed.
