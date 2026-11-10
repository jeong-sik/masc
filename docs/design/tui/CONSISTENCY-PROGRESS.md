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
| Workspace | Repositories, Code; checkout, Git changes, files, history, diff and navigation overlays | #50704 leads repository selection with its scoped last Git observation and assigned Keepers, before registered defaults and the path. The normal explanatory question and repeated inner heading are removed; retained/failed reads remain visible. Rendering and cursor paging share the revised row budget. Two local agent source reviews found no P0–P2; their footer-language finding was repaired. These are local review results, not formal GitHub approvals. #50969 makes Code diff use each returned row instead of replacing its body with the independently read open file, and measures the displayed tab expansion for horizontal navigation. A matching 3a0737e3 native baseline showed a historical 1-to-2 change as 1-to-999, a changed server file as the earlier open contents, and a tabbed removal whose end was unreachable; those observations do not execute the repair | Candidate execution and navigation/return behavior; Code, history, diff and overlays |
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

The subsequent [Requests repair](https://github.com/jeong-sik/masc/pull/50802)
reserves the selected question, armed/in-flight
decision notice and footer before drawing bounded last-answer/source summaries.
The oversized block affected the compact question list; the active answer
editor already excludes those diagnostics. Browsing `v` captures the complete
last-answer receipt and retained typed follow-up in the existing scrollable,
searchable reader, with the original Ask/asker/turn and unflattened error text.
The captured document does not follow a changed question cursor or issue a
request. Gate-detail byte reading and answer-input ownership remain separate.
This is a source repair: native execution and installed GUI confirmation of
this follow-up are pending, and the full 23-surface scope remains open.

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

[#50743](https://github.com/jeong-sik/masc/pull/50743) makes Task Review and Task
Verdicts lead each row with the original Task title
and its actual review/result label. Long identifiers, evidence counts and
evaluator metadata stay in the complete reading. Workspace-wide calibration
moves to the verdict detail, retaining the original denominator and unknown
ground-truth labels. The verdict's recorded timestamp remains there, and the
list names its newest returned record in UTC without opening a verdict. Empty
pages and an unobserved snapshot differ, and a retained reading stays qualified
during refresh or failure. The producer's ambiguous zero timestamp is shown as
unobserved time, preserving its current identity. Age alone no longer implies a running judge or a
recording failure. The repeating wall
clock and the fixed linear completion explanation are removed.

Harness rendering and navigation use the same state-owned list bound, including
the overflow row and the timestamp row. Its list no longer has uncounted
aggregate/intro rows. Page
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
slice is claimed. The Requests candidate and its selected checks have a different
source. All six entry points, 23 surfaces and their child/input readings remain
the full goal; source changes alone do not establish native or installed parity.

## Requests candidate execution, separate from the verdict slice

`Minimal manual checks` [run 42665508654](https://github.com/jeong-sik/masc/actions/runs/42665508654)
completed with conclusion `success`: workflow `main` at ac37d6f0, selected source
c2fa4c88, scenario `workspace-files`. The receipt records matching TUI/server
builds and three completed suites (`test_repo_git`, `test_tui_workspace_entries`,
`test_workspace_file_confidentiality`), all with zero suite/log exit codes.
Downloaded hashes and both embedded build commits were checked; both binaries
loaded locally and exited successfully for their build-commit command. This is
not a running matching server, native screen, installation or restart result.

The targeted `Test` [run 42665507307](https://github.com/jeong-sik/masc/actions/runs/42665507307)
completed with conclusion `success` on `feat/tui-requests-simple-20261110` at
c2fa4c88, `minimal=true`. The actual retained runner log records
`test_tui_approval_authority` (15 cases) and `test_tui_ask_projection` (65 cases).
Those 80 cases check approval/Ask identity and decisions; they are not the whole
TUI regression and do not execute the later Verification/Harness changes.

## Feature route configuration is not runtime availability

The [feature state repair](https://github.com/jeong-sik/masc/pull/50811) gives
an exact model route with admitted candidates the shared `Configured`
standing. Configuration alone no longer produces `Ready` in the feature list,
its counts or the selected reading. The selected fields name model
configuration, and the full reading no longer calls an unobserved run history
normal readiness. Browser, machine and Add-on worker observations retain their
own readiness meanings; failures, disabled routes and missing observations
keep their existing states. These standings do not authorize execution.

The matching b9d9b809 native pair showed Librarian as ready in the 80x24 and
36x20 feature readings while the same isolated workspace reported an unattached
Memory execution Add-on. Those observations demonstrate the configuration and
execution distinction; that baseline does not execute this repair. The later
candidate observation below executes it separately. Installed verification
remains pending, and the full 23-surface goal is open.

## Feature child navigation

[#50855](https://github.com/jeong-sik/masc/pull/50855) makes the outermost return
from Clients, Resources, Channels and Tools use their existing typed surface
family, Features & plugins. Resources still closes its text before leaving;
Tools still closes an original Task, then its request, then its list. Browser
readings, input owners and explicit followed-reference returns keep their
earlier dispatch priority. The Help registry and committed key reference name
the same destination. The screen map also records the actual six empty-palette
destinations.

Local OCaml 5.5.1 syntax parsing and diff checks passed for the initial code
slice. They are not project type checking, tests or native execution of this
navigation repair. The earlier f89b3e6f matching native server/TUI observation
does execute #50811's configured-state repair, separately from this navigation
change. All 23 surfaces, their child/input readings, and installed verification
remain the goal.

## Matching feature-state candidate observation

`Manual probe artifacts` [run 42732829605](https://github.com/jeong-sik/masc/actions/runs/42732829605)
completed with conclusion `success`, workflow ref `main` at
4d532df1cecf3459959c423f80a8fb68c472cefb, selected source
f89b3e6fe22732f7b1ef0a8989317366b6b7b0cc. The GitHub artifact digest,
payload hashes, trusted Git source tree, embedded commits and bundled runtime
were checked before running the candidate. This was a native probe build,
not Full CI or Release verification.

The matching native server/TUI pair showed four exact routes as configured.
A 36x20 terminal viewport in a real Ghostty window showed Verifier as
`설정됨`, beside an unconfigured Candle Appraiser. The physical window was
larger than that viewport; it was not a 36-column desktop window. A separate
GUI capture showed the exact activity editor. Blank compositor captures are
retained as unsuccessful captures and do not prove screen behavior. Raw
observations stay private in `artifacts/native-tui-proof-42732829605/`.
This confirms those observed candidate views only, without proving production
installation, the new navigation repair, or the remaining child/input states.

## Resources save results (#51105)

The 072796b2 native baseline exclusively created the exact 393-byte fixture
report, then refused an explicit second save to the same existing path. The
36x20 success and refusal captures were identical: the footer had no space for
the result. The refusal also closed the path form, whose footer advertised
reader keys while printable keys still belonged to the path.

The source now retains each original report/workspace/path and typed save
outcome. The reader leads with the newest result for that exact report; `i`
also exposes diagnostics and earlier saves. A failed save retains editable
input, and a late result cannot close a replacement form or label an edited
path as saved. Issued writes keep their own frozen destination. Closing input
does not replay or cancel them, and their original receipt still settles after
workspace read authority is withdrawn. The form footer reflects its actual
keys; page keys can read a long result without editing the path.

The canonical filesystem boundary preserves the original publication failure,
target effect, lane-release value/failure and ordinary boundary exception.
Existing files remain protected by the same staged exclusive writer, recovery
registry and 0600 mode. None/unobserved and interrupted writes do not become
unchanged or successful results. A nonblocking source-review limitation remains:
plain cancellation after the wrapper observed creation can still be reported
as unknown when that observation is not carried into the cancellation payload.

Independent core/export and UI/state source reviews found no remaining P0-P2
in their recorded scopes after three UI findings were repaired. OCaml parsing
and diffcheck are separate from type/build/execution evidence. The changed Help
still needs its actual generated reference; semantic file-effect and receipt
ownership checks have not run for this source. The 6157b06b native results
belong to the body-reading parent, not this save change. Matching execution,
installation, GUI display and the rest of the 23-surface audit remain open.

## Feature child identity and resource body (#51023)

The matching be3302c2 server/TUI baseline at 120x36 and 36x20 showed a
Resources JSON body of `[]` entirely below fixed origin/About/URI/type metadata
on the narrow first page. Clients lost its child name to the family prefix and
Runtime menu, while Channels and Tools repeated render clocks and parent names.
The baseline is retained in
`artifacts/tui-feature-children-reading-20261110/baseline-observation.json`.

[#51023](https://github.com/jeong-sik/masc/pull/51023) gives those four children
short KO/EN titles beneath the existing family strip. Exceptional connection
evidence and each body's own missing/failed/retained reading remain separate.
Long connection evidence uses Board's existing bounded typed state/gap summary,
now shared rather than copied, so the failure is not lost beyond the frame.
Clients still derives row ages from its roster observation; channel state and
binding decisions are unchanged.

Resources now opens its admitted body with the selected original part target.
Full MCP/report metadata, including a known public URL, expands with the existing
`i` action. Read failures, report confirmation, unknown/uncertain sharing and
share recovery precede the body; original copy/export/share authority and bytes
are unchanged. Source anchors keep separate notice origins and continue at the
first actual document block when preparation chrome disappears. A returned
empty part list remains distinct from unread or failed content.

The d58145cf matching server/TUI reached the JSON body on the narrow first page,
and its report information/source actions remained readable. A nonempty private
report still had no body on the 36x20 first page: generated leading status space
and an absent image-selection paragraph occupied four rows. The source now omits
those empty pieces while preserving every confirmation and sharing notice.
The matching 6157b06b server/TUI now shows the report title and first body line
at 36x20. The unchanged before/after captures are retained in
[the evidence bundle](../../evidence/tui-feature-resource-body-20261110/README.md).

Local OCaml 5.5.1 parsing and `git diff --check` pass. The changed Help registry
now has its exact full generated key reference. `Minimal manual checks`
(`pr-check.yml`, `main@f5876874`, `resource-reading`) run 42789874637 succeeded
for source 6157b06b and its four existing targeted suites. The same native pair
also displayed the four short child names at both widths. During a controlled
fixture-server stop, the Clients title retained the failed/unconfirmed reading;
after the same server source recovered, the normal empty roster returned.
The narrow title reports workspace confirmation pending, while the wide title
also shows the HTTP read failure. These are native PTY observations, not GUI.
Independent review of the final documentation delta, remaining failed/retained
cases, installation and GUI display remain separate work. No wording/layout/
row-order tests were added, and the full 23-surface scope remains open.

## Tools catalog and volume reading (#50872)

The catalog's long periodic volume report moves to an explicit child reading.
The five Tools tabs remain unchanged. Catalog `V` captures its scroll position,
opens the volume reading and requests a report, unless a request is already
running. It never reuses an old reclaim arm. The child uses the existing
report/reclaim protocol, exact candidate names, workspace request owner and
uncertain-result messages. Esc returns to the captured catalog position.
Skill and Keeper action keys do not act on the volume report; its footer names
volume, scroll, refresh and return controls. Periodic inventory refresh does
not reset the reading. A newly answered operator request starts at the first
line, where an armed reclaim names its targets.

The f89b3e6f native baseline was reobserved at 36x20 and 80x24. The narrower
view contained no actual tool row; the wider view put a missing-image error
before the catalog. These are baseline observations, not execution of this
repair. Two independent source reviews covered the nine-file implementation
and its three-file follow-up. Their refresh-key and inflight-documentation
findings were repaired. Syntax parsing uses local OCaml 5.5.1; project type
checking, candidate execution and installation remain separate. No new screen
wording, layout or row-order tests were added. The full screen scope remains
open.

[#50996](https://github.com/jeong-sik/masc/pull/50996) follows the volume
separation with the five panes' remaining fixed explanations. A matching be3302c2
server/TUI at 36x20 showed eight wrapped explanation rows, then the count and
part of the table header, with no tool name on the first page. The other four
panes similarly put their fixed paragraphs before the observed reading. All
five now start with their original readings; the catalog keeps its process-wide
registered count. The existing section key's Help carries the scopes, recorded
evidence meanings and column legends, including the distinction from a Keeper's
callable surface and observed calls. Missing
inventory remains a missing reading, and independent pending/failure/retained
notices, Skill drafts and the volume child keep their existing owners.
The committed key reference is the actual generator's complete output from
source `072796b2`, SHA-256
`40fe09893eca59360482bdb88e60bfeba7f967f734a4ee66bc47f7a8a85b3a16`.
`Minimal manual checks` [run 42773110048](https://github.com/jeong-sik/masc/actions/runs/42773110048)
completed successfully on workflow ref `main`, workflow head
`fdde0336dd0166103aef3e470f0cacc85ee85c26`, selected source
`072796b22fe3c289f6c5f476e238d55ecaff6fb8`. The receipt records matching
server/TUI builds and the three workspace-file suites with zero suite/log exit
codes; this is not Full CI. Manual native PTY observations of that matching
server/TUI at 120x36 and 36x20 show all five panes leading with their actual
readings. The narrow catalog exposes tool names on its first page, and Help
search finds the relocated legends through its last page. A read-only volume
report exposes the server's missing-base-image refusal; returning preserves
catalog rows 10-19/451. Escape returns to Features with its selection intact.
The observation ledger is
`artifacts/native-tui-proof-42773110048/manual-coverage-tools.json`; it retains
startup/key-batching miscues separately from the observations above. Subsequent
changes add only generated/reference and progress/changelog documentation, not
executable source. Nonempty Keeper/async/Skill states, induced failure/retained
recovery, successful volume reclamation, installation and GUI display remain
unverified. The full 23-surface scope stays open.

## Operations action-reason reading (#50913)

The f89b3e6f baseline was observed at 120x36 and 36x20 with two actual server
reasons. The narrow Operations view showed the first and `+1 more`; Home
selection did not include those reasons. The global footer repeated an internal
code. This observation does not execute the following repair.

Operations `v` opens every reason from the last server rollup in the existing
immutable detail reader. Its original order and complete text are retained;
scrolling, search and resize use that reader, and Esc returns without an
approval, setting change or new request. Missing server/rollup observations do
not become an empty list. The common footer names the observed action count in
the selected UI language and points to Operations instead of repeating a raw
diagnostic. Its existing press target opens that destination.

The new key is in the canonical binding source and screen map. The committed
key reference is the byte-for-byte output of the actual generator built from
source `3a0737e3`, including previously stale rows from that registry.
`Minimal manual checks` run `42758272437` completed successfully on workflow
ref `main`, workflow head `4f1ac0e8`, selected source `3a0737e3`. It built the
matching server, TUI and generator and passed the three selected workspace-file
suites; this is not Full CI. The generated output's SHA-256 is
`f87a7e316dd705c9818cc4d1f892ac80f07cd1430e1250bdbf87618e75b68ca5`.
Operations interaction, installation, remaining Operations states and the full
23-surface scope remain open. No new screen wording, layout, row-order or PTY
assertion tests were added.

## Board title-first reading (#50883)

The Board list leads with each post's title and author. Compact technical IDs
no longer occupy a list column; the existing exact-reference copy action keeps
the selected post identity. The list, composer and reader use the same short
Board heading, without a repeating wall clock or healthy connection badge.
Exceptional transport, workspace, partial/interrupted/failed reads and event
loss retain the shared typed notice. The existing header fitter reserves its
width before the title, including in the composer and reader. Ordinary pending
reads keep the Board's own indications. When the complete warning cannot fit,
the existing typed compact state leads instead of clipping a failure word at
the end of a healthy HTTP prefix. Event loss remains a separate label. Sort,
hearth, observed counts, retained/failed reads, original timestamps, publication
receipts and the one-row cursor budget keep their existing owners.

The matching f89b3e6f baseline was observed with stored fixture posts, a comment
and a multiline draft at 120x36 and 36x20. The draft survived resizing, and its
explicit publication returned to the list with a published receipt. This
baseline exposed the ID-first wide list and the clock/HTTP heading in a narrow
list and composer; it does not execute this source change. Candidate execution
and installation, remaining Board input states and the full 23-surface scope
remain open.
