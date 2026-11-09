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
| Operations | Overview, Metrics; requests, account and call details | Inspect actual decisions separately from system diagnostics; remove repeated normal-reading chrome where useful | Current-source audit and candidate execution |
| Work | Planning, Approvals, Verification, Harness, Board; Goal, Task, request, proof and discussion details | #50671 simplifies the Task list; #50688 wraps the goal and declared success criterion, retaining exceptional proof/binding notices and keeping identifiers in detail. Linked Task details qualify partial or retained observations rather than claiming absence or a complete count | Goal candidate execution; other Work readings, installation and input/confirmation ownership |
| Keepers | Keepers, Memory, Schedules, Fusion, Changes; all six Keeper modes and detail tabs | Coordinate with existing Keeper Pulse and memory work (#50669, #50643) rather than duplicate it | Review those changes together; chat, schedule, result and error states |
| Features and plugins | Lanes, Clients, Connectors, Resources, Tools; plugins, browser, tools, skills and result details | #50677 simplifies feature overview around purpose, standing, errors and existing actions. The a00f8aab candidate was observed in a native PTY at 150×40 and 80×24; narrow secondary action hints still displace current execution fields | Fix narrow summary priority; the other feature surfaces, input overlays and installation |
| Workspace | Repositories, Code; checkout, Git changes, files, history, diff and navigation overlays | Repository selection now leads with its scoped last Git observation and assigned Keepers, before registered defaults and the path. The normal explanatory question and repeated inner heading are removed; retained/failed reads remain visible. Rendering and cursor paging share the revised row budget | Independent source review; candidate execution and navigation/return behavior; Code, history, diff and overlays |
| System | Config, Runtime, Acting, System_logs; all settings tabs, account/model forms and diagnostic details | #50690 puts validation and application before full source identifiers and key lists, retaining failed-refresh notices before previous status facts; two independent source reviews found no P0–P2 | Candidate execution, other System readings and save/uncertain-result behavior |

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
