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
| Work | Planning, Approvals, Verification, Harness, Board; Goal, Task, request, proof and discussion details | #50671 simplifies the Task list and request preview; Goal previews still prioritize clipped metadata over the request | Goal and other Work readings; candidate execution and installation |
| Keepers | Keepers, Memory, Schedules, Fusion, Changes; all six Keeper modes and detail tabs | Coordinate with existing Keeper Pulse and memory work (#50669, #50643) rather than duplicate it | Review those changes together; chat, schedule, result and error states |
| Features and plugins | Lanes, Clients, Connectors, Resources, Tools; plugins, browser, tools, skills and result details | Simplify feature overview around purpose, standing, errors and existing actions; retain full diagnostics in detail | Candidate build/execution; the other feature surfaces and input overlays |
| Workspace | Repositories, Code; checkout, Git changes, files, history, diff and navigation overlays | Registration and current Git readings remain distinct; inspect the repeated explanatory header and selected content next | Source audit, candidate execution and navigation/return behavior |
| System | Config, Runtime, Acting, System_logs; all settings tabs, account/model forms and diagnostic details | Inspect effective settings and pending application before source revisions and raw keys | Source audit, candidate execution and save/uncertain-result behavior |

For each row, inspect wide and narrow native views, loading/empty/error and
retained observations, selection/scroll/return ownership, and applicable input
drafts and save receipts. Do not add tests for wording, layout or row order.
Source review, parsing, candidate build, observed rendering, merge and installed
runtime are separate stages. A baseline observation or a pending PR does not
complete a row. Keep the full request open until every row has current evidence.
