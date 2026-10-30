# Latest actual 3014 Qwen cohort: G2 and G3 failed

Candidate `3014cfce79636f1e41cc39f6019a3428c6912145` ran as the separately
checked macOS server, SHA256
`bd9042e019d31c377e8c9ca72409bc5b152052dc79dd70621f027cc008c475b6`.
Local Qwen3:8b used digest
`500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41`.
Initial request and Keeper instructions match the earlier Qwen cohorts.

The latest acceptance ledger is **9/11**. G2 is reopened and G3 still fails.
The previously demonstrated **10/11 historical case coverage** is preserved,
but is not the latest candidate's acceptance. G1/G4 and A1–A7 retain the exact
source/native/runtime scopes listed in the campaign; they were not all rerun
at this head. No universal model reliability or full regression pass is implied.

## First request and G2

The first actual request included the current Goal/revision, the new Keeper
reporting sentence and canonical receipt description. The model nevertheless
created Task 001 without `goal_id` and never linked it before terminal.
The authoritative primary and mirror Goal link stores were absent. This is a
G2 failure. Earlier Gemma and candidate54 Qwen association passes remain
historical counterpoints, not a substitute for this run.

The model recovered from actual path/edit/schema errors, set only alpha true,
reread it and submitted verification `vrf-a7a1fde77b0d53ceae734673258aa74b`.
Its immutable submission matched the current file exactly: **42 bytes**,
SHA256 `394f8fa3779b4ede93235e973ace265bc4180f7558be5ef888b3bd15267bf093`.
The initial operation finished at **16:31:03 UTC**, with no pending provider
request. [Preapproval evidence](preapproval/README.md) preserves that boundary.

## Controlled G3 fixture

After the initial operation ended, the operator used public MCP
`masc_task_set_goal` at **16:33:01 UTC** to establish the linked-Task condition.
This controlled link does not satisfy G2. The operator inspected the exact
retained artifact and current bytes, then approved only the first Task at
**16:33:21 UTC**. The [fixture scope](operator/fixture-scope.json),
[link receipt](controlled-goal-link-receipt.json),
[inspection](operator/partial-inspection.json) and
[approval](operator/approval-receipt.json) distinguish setup from model behavior.
There was no postapproval Keeper message, additional approval or observer edit.
This operator proxy is not an independent LLM verdict or human Goal confirmation.

The approved Task outcome reached actual request 21 with Task, verification and
authority correlation keys. It was absent from subsequent requests 22–31,
while the older AwaitingVerification Tool result remained in history. That is
an observed input-retention defect, not proof of the sole cause of model failure.

The model temporarily overwrote the approved alpha result with all-false bytes,
then restored/reworked alpha. Request 29 successfully used the repaired exact-ID
default query and received the authoritative Done Task with its completion time.
Despite that explicit result, the model tried to resubmit the same Done Task.
The tool correctly refused; no new Task or remaining beta/gamma work occurred.

The final response ended at **16:40:35.695 UTC** and the queue acknowledged the
turn at **16:40:35.848 UTC**, pending zero. It described the Task as Done while
still awaiting its approval before beta/gamma work. No model Goal measurement
occurred; the only persisted measurement remained the operator's initial 0/3.
The final mutable file was alpha-only, **41 bytes**, SHA256
`d239f681909b88b3ff70e16acf658ed66b67bcc958bb57a983dea63884813aca`.

## Evidence and limits

[The diagnosis](postapproval/diagnosis.json) and
[observer report](postapproval/README.md) retain public calls, terminal response,
Task/Goal state and queue outcome. Immutable approved, regressed and final
artifacts remain distinct. Exact-ID Done lookup **worked in the real path**;
the model's next action still failed. Goal context and reporting instructions
were delivered, so the failure cannot be described as missing instructions.

The model never invoked the new measurement receipt. This run therefore does
not establish its live interpretation quality. The separate actual HTTP/MCP
receipt check and source/native results retain their narrower validity. The
next bounded source repair preserves the typed completion-authority observation
through the current turn's tool rounds. Its source/input result and future
model behavior must be measured separately.

These files exclude raw thinking and credentials. No production installation,
deployment, stack merge or human Goal completion occurred.
