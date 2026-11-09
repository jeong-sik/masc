# Conversation-first consistency work

The operator accepted the conversation-first preview in #41685 and asked to
extend the same treatment consistently. This is the full scope of that work;
completing one row does not complete the overall request.

## Shared rules

- Lead with the object or content being read. Use one stable content column and
  whitespace between groups; the terminal controls font size and letter spacing.
- Keep normal text at the terminal foreground. Recede labels, separators and
  secondary facts. Reserve strong color for selection and actionable failures.
- Give each fact one owner. Working footers contain relevant actions, outcomes
  and warnings. System owns connection/build identity; Keepers and Activity own
  other Keepers' execution state. Do not fill wide terminals with extra telemetry.
- Preserve unknown, stale, failed and uncertain outcomes. Quiet presentation must
  not make unavailable information look healthy or a mutation look confirmed.
- Use existing navigation, source identity and keyboard contracts. Detailed
  inspection remains available without occupying the resting view.
- Count, render, scroll and hit-test the same rows. Preserve first/latest text,
  external speaker identity, drafts and the selected object at narrow widths.

## Coverage and evidence

| Area | Required result | Current evidence | Remaining work |
| --- | --- | --- | --- |
| Keeper chat | Small speaker margin, aligned prose, journal and metadata opt-in; local progress only | #41685 source and 12 pure layout checks; later current-head `dune build @check` succeeded | Executable/PTY and installed-screen validation |
| Shared footer | One quiet action row; no fleet broadcasts or passive identity repeated across views | Implemented in #41703; independent source review passed and 8 existing footer-fitting checks passed | Focused renderer execution and narrow warning/action checks |
| Shared headings/navigation | One title hierarchy and consistent spacing; no duplicate live clock or redundant labels | Keepers, Dashboard, Work and Task headings omit wall clocks; existing sidebar primitives remain shared | Remaining custom headers and actual rendering verification |
| Keepers list/detail | Readable names/current state; selected details and failures stay distinct from fleet diagnostics | #41712: name first, quiet title/table, composite execution fields owned by Info; a state test covers the queued Info reread folding into resume | Manual check in a rebuilt TUI pending; wide optional columns and remaining detail tabs need consistency audit |
| Dashboard/Work | Decisions, outcome and relevant work lead; optional metrics recede | #41723: decisions and continuation before passive context; Work uses compact rows at every width and preserves measured snapshot provenance | Manual check in a rebuilt TUI and installed rendering; remaining Work child headers |
| Board | Post/reply content and authors lead | Existing index/detail split | Apply reading width and section hierarchy |
| Usage | One account/window at a time; measurement provenance stays truthful | Usage studio documented | Inspect current renderer and align custom cards/headers |
| Workspace/System | Source, diff or effective setting leads; diagnostics remain findable | Existing surface studio; System receives connection identity | Align custom panels, fields and empty/error states |

Source, pure layout, browser preview, compiled fixture and installed runtime
are separate evidence layers. Only observed behavior supports a claim at that
layer. Keep this ledger current as each bounded stack slice lands; the whole
request remains open until the listed surfaces and shared states are coherent
and their actual renderings have been verified.

## 2026-11-09: simplify every operator surface

Tracked in [#50676](https://github.com/jeong-sik/masc/issues/50676).

The current request covers all six entry points and all 23 surfaces in
[the screen map](SCREENS.md), including their child readings and input overlays.
It does not stop at the Task list. The operator asked for ordinary words and
information that matches the actual product flow, with fewer explanations of
internal fields. The [information architecture](OPERATOR-INFORMATION-ARCHITECTURE.md)
owns that rule; this table records the remaining scope.

| Entry point | Surfaces and child readings | Current work | Remaining evidence |
| --- | --- | --- | --- |
| Operations | Overview, Metrics; requests, account and call details | #50707 removes request IDs from summary labels while keeping the exact typed destination, and names continuation actions as conversation entry points. Normal current fleet scope/ok rows are omitted; retained scope, non-normal grade, counts and failure reasons remain. Main labels and key hints use the existing interface language. #50730 removes the Usage wall clock and repeated Plan heading, and chooses localized key hints from typed view membership so account controls are not promoted in Keeper/tool-call readings. Two local agent source reviews found no P0–P2 in Usage 53095e99 on Memory b5655270; these are not formal GitHub approvals | Matching-server candidate execution; account/call details and request input states |
| Work | Planning, Approvals, Verification, Harness, Board; Goal, Task, request, proof and discussion details | #50671 simplifies the Task list; #50688 wraps the goal and declared success criterion, retaining exceptional proof/binding notices and keeping identifiers in detail. Linked Task details qualify partial or retained observations rather than claiming absence or a complete count. Goal/Task entry, detail and return were observed with native TUI 8ebbe020 against the older server | Matching-server observations; other Work readings, installation and input/confirmation ownership |
| Keepers | Keepers, Memory, Schedules, Fusion, Changes; all six Keeper modes and detail tabs | Coordinate with existing Keeper Pulse and memory work (#50669, #50643) rather than duplicate it. #50708 aligns typed state/pass search and preserves refused fleet rows and retained observation scope; its b5655270 source was independently reread | Review those changes together in execution; chat, schedule, result and error states |
| Features and plugins | Lanes, Clients, Connectors, Resources, Tools; plugins, browser, tools, skills and result details | #50677 simplifies feature overview around purpose, standing, errors and existing actions. #50695 repairs the narrow summary priority found in a00f8aab; native TUI 8ebbe020 observations at 150×40 and 80×24 showed current fields before secondary action hints, against the older server | Matching-server observations; the other feature surfaces, input overlays and installation |
| Workspace | Repositories, Code; checkout, Git changes, files, history, diff and navigation overlays | #50704 leads repository selection with its scoped last Git observation and assigned Keepers, before registered defaults and the path. The normal explanatory question and repeated inner heading are removed; retained/failed reads remain visible. Rendering and cursor paging share the revised row budget. Two local agent source reviews found no P0–P2; their footer-language finding was repaired. These are local review results, not formal GitHub approvals | Candidate execution and navigation/return behavior; Code, history, diff and overlays |
| System | Config, Runtime, Acting, System_logs; all settings tabs, account/model forms and diagnostic details | #50690 puts validation and application before full source identifiers and key lists, retaining failed-refresh notices before previous status facts; two independent source reviews found no P0–P2. Native TUI 8ebbe020 showed application facts before source identifiers at wide and narrow sizes, against the older server | Matching-server observations, other System readings and save/uncertain-result behavior |

For each row, inspect wide and narrow native views, loading/empty/error and
retained observations, selection/scroll/return ownership, and applicable input
drafts and save receipts. Do not add tests for wording, layout or row order.
Source review, parsing, candidate build, observed rendering, merge and installed
runtime are separate stages. A baseline observation or a pending PR does not
complete a row. Keep the full request open until every row has current evidence.

The a00f8aab Work/Features native artifact came from `Minimal manual checks`
[run 42625264710](https://github.com/jeong-sik/masc/actions/runs/42625264710),
workflow `main` at 3d1271ef, with conclusion `success`. Its receipt names the
`detail-ownership` scenario and three completed suites; it does not cover the
later Goal or System layers. Manual PTY observations used the existing e2c38ca
server without installing the candidate, and are not same-version integration
or GUI screenshot proof. Raw captures stay private under `artifacts/` because
they contain workspace requests and settings. The Task list, narrow Task detail
entry and return were observed. The a00f8aab Task detail's identity-first order
motivated the subsequent #50698 request-first implementation.

## RFC-0519: four reading surfaces

[#50689](https://github.com/jeong-sik/masc/pull/50689) records the source audit
and the shared list/detail reading and language contract.
[#50698](https://github.com/jeong-sik/masc/pull/50698) builds on the existing
Task/Goal previews: requests, criteria and evidence precede diagnostics; Board
content has fewer repeated headings; Memory claims retain their read scope.
The existing KO/EN setting reaches target labels, key footers and prepared
Task/Board document identities. Authored content and raw diagnostics stay intact.

Independent source reviews covered the three ownership areas. The partial
fleet count and retained-scope defects found in review were repaired. This
records implementation and source review, not current-head CI, native
rendering, installation or completion of the broader 23-surface request.

[#50695](https://github.com/jeong-sik/masc/pull/50695) follows that implementation
with the narrow Feature summary finding from the a00f8aab PTY: current fields
precede secondary action hints. Labels, typed standing, failures, full detail
and existing key actions are preserved. Task detail uses #50698's implementation.
Native execution of this follow-up is still pending.

`Minimal manual checks` [run 42637409866](https://github.com/jeong-sik/masc/actions/runs/42637409866)
completed with conclusion `success`: workflow `main` at 174196c9, selected source
8ebbe020, scenario `detail-ownership`. The receipt records the TUI build and
three completed suites (`test_tui_detail_reading`, `test_tui_board_successor`,
`test_tui_usage_scope`), each with zero suite and log exit codes. The downloaded
TUI digest and embedded source commit were verified. This is an executable
candidate, not a visible-screen, same-version server, installation or full
regression result. Later Memory pass-label and Workspace changes are outside
that source.

The targeted `Test` [run 42637437417](https://github.com/jeong-sik/masc/actions/runs/42637437417)
also completed with conclusion `success` on `feat/tui-reading-priority-20261109`
at 8ebbe020. Its retained runner log records the three selected suites:
`test_tui_memory_facts_explorer` (9 cases), `test_tui_planning_detail` (8), and
`test_tui_task_document_style` (4). These are category-search, proof-boundary and
document-identity/style checks; they are not the complete TUI regression.

Manual native PTY observations of 8ebbe020 subsequently covered Operations,
Goal and Task entry/detail/return, Features and settings status, at wide and
narrow sizes. A separate Usage baseline covered Plan, Trend, Keepers and Calls.
These used the existing e2c38ca server, not a matching server build; the baseline
does not execute #50707, #50708 or #50730. Raw captures remain private under
`artifacts/`. Neither observation establishes installation or a visible GUI
screenshot. The 2026-11-10 health read reported server e2c38ca.

The stack now includes the Memory author's b5655270 update rather than replacing
it with a parallel repair. Two local source reviews covered its full
7175899d-to-b5655270 diff and the unchanged Usage diff on that base. Operations
7175899d also received an independent source reread against its current parent
and direct interfaces. Parsing and source reviews remain separate from fixed
toolchain compilation, native execution and formal current-head approvals.

## 2026-11-10: request reading

[#50740](https://github.com/jeong-sik/masc/pull/50740) leads each approval row with its original request/summary,
then its actor. Gate rows retain the actual automatic/human phase even when a
long tool name must shorten. Folded Asks show the first original question with
the asker, age and additional-question count. These are display projections;
the original row order, Ask keys, draft, source and approval authority remain.

The selected preview retains execution site, age, input and real expiry facts.
Call/approval/trace IDs move to the full reader; the reader also retains the
original reason and target ID. Missing, failed, retained and unavailable sources
are separate measured rows when they fit, before policy controls. The header
qualifies the observed count and names the number of sources not current; full
source details remain in the approval and question readers. The header count is qualified
as observed unless all four readers are current. Normal title breakdown and the
wall clock are removed, and an absent selected approval contributes no empty
detail rows. Header, selected context, questions, footer and queue window still
share the actual measured buffers. The selected question's compact allowance and
any armed approval notice are reserved before optional source rows and selected
context. When both need space, the question uses its existing shorter preview
before an armed/in-flight approval loses its decision notice. Context is clipped
only at complete prepared rows, with the full-reader hint when it has room.
Question diagnostics do not follow the active editor.

This is source work, not native or installed confirmation. Full question
answering/follow-up readers, Verification/Harness, and the rest of the 23-surface
scope remain open. Existing answer-receipt/origin blocks can themselves exceed a
short viewport; bounding those blocks remains a separate input-surface repair.
No wording, layout or row-order tests are added.

The [second four-surface source review](../../reports/2026-11-10-four-surface-reading-review.md)
keeps Memory health queries aligned with the displayed canonical/KO/EN state
and carries refused health rows into fleet fact coverage, including anonymous
refusals and retained results. Filtered listing counts are named separately from
store totals. New checks concern selected Keeper IDs and observation scope;
the [targeted execution record](../../evidence/four-surface-memory-validation-20261110/README.md)
keeps both failed runs and the later decoder-fixture repair. Memory's 13 cases
passed on b5655270; the decoder's 407 cases passed on f35a50b9. Only the decoder
test changed between those sources. This does not cover the later Usage layer
or establish a native capture of this follow-up.

## 2026-11-10: stack integration and next readings

The 14-layer native stack was rebased together onto main f7f30f94. It preserves
the Memory author's decoder repair and selected validation records. The parallel
local fixture repair was omitted because the same semantic repair was already
present. Usage's self-citation fix is in #50730 itself; the later documentation
layer no longer has to supply it. Captured source/run identities above remain
historical observations, not execution results for the rebased heads.

The Requests source passed independent rereview before restacking, and the three
product-source blobs are identical after restacking; review of the new base is
separate. Local OCaml 5.5.1 parsing and fragment checks differ from the pinned 5.5.2 build,
formal GitHub approval, native screen, installation and restart. No local Dune
build was run for this slice.

Verification and Harness are next. Source inspection found that Harness cursor
movement and rendering use different list heights, and both detail readers omit
the failed-refresh warning while retaining an earlier snapshot. Those repairs,
the oversized Ask receipt/origin case, and all remaining child/input readings
stay in the full 23-surface scope.

## 2026-11-10: verification and recorded verdicts

Task Review and Task Verdicts now lead each row with the original Task title
and its actual review/result label. Long identifiers, evidence counts and
evaluator metadata stay in the complete reading. Workspace-wide calibration
moves to the verdict detail, retaining the original denominator and unknown
ground-truth labels. The verdict's recorded timestamp remains there; age alone
no longer implies a running judge or a recording failure. The repeating wall
clock and the fixed linear completion explanation are removed.

Harness rendering and navigation use the same state-owned list bound, including
the overflow row. Its list no longer has uncounted aggregate/intro rows. Page
movement on both lists uses that actual content height. Each renderer also
brings the selected original row into the new viewport after resize. These
changes preserve request IDs, evidence keys, verdict/notes identity, ordering
and mutation authority. The old column APIs are removed with their last caller.

Refresh errors and in-flight reads qualify the previous snapshot in both list
labels and the complete detail documents. Verification evidence/image offsets
include those actual document rows; no cached authority or evidence is borrowed.
Original failure details remain reachable by scrolling.

Local OCaml 5.5.1 parsing and diff checks passed. No new wording, layout or
row-order tests were added, and no local Dune build or native execution of this
slice is claimed. The Requests candidate and its pending checks have a different
source. All six entry points, 23 surfaces and their child/input readings remain
the full goal; source changes alone do not establish native or installed parity.
