# Completion-authority observations survive this turn's tool loop

## Candidate review status

Candidate `2be9d21697fb4c9da9aafd769f5fa691bae2e757` is **source FAIL, P2**.
Its product and direct-test files match author e9f72f1. Independent execution
found that Official Start puts the event in the vendor's fixed System; when
the next local turn has no event, Resume sends no corresponding observation.
The initial System event can therefore outlive its intended current-turn scope.
The ordinary HTTP retention result remains narrower evidence. The
[independent finding](independent-source-review-e9-fail.json) and
[lifetime counterexample](independent-official-lifetime-counterexample.json)
are preserved while the Official carrier is repaired.

Native run [40114401559](https://github.com/jeong-sik/masc/actions/runs/40114401559)
at this candidate stopped during compilation: the new fixture used unqualified
constructor `Text`. None of the six selected executables ran. This is recorded
in [the native receipt](native-result-2be9.json), not counted as six behavior
failures. The new carrier and fixture corrections require their own review
and check results. Latest actual acceptance remains **9/11**.

## Repair implementation and scoped checks

The retained Qwen canary has an actual Task-approval notice in request 21,
including its Task, verification and authority correlation keys. Requests
22–29 omit that notice while older AwaitingVerification tool feedback remains.
`baseline.json` retains these presence observations after checking all nine
raw request SHA-256 values. It also preserves the counterevidence: the later
known-ID Task query returned authoritative `done` and its completion timestamp,
but the model still called `keeper_task_done` again. Input loss is a real
delivery defect; it does not alone explain the model's choices. This repair
does not establish a successful Goal measurement or follow-up model decision.

At repair base `cc5104805e3963a9ef1a4fcb0013145514466a91`, the existing typed
`Completion_authority` world layer combines approval and rejection renderers.
It reaches the initial Dynamic carrier, then disappears because post-tool
requests omit Dynamic context and preserve only the Goal System observation.

The repair keeps that producer and its exact partition. The request assembler
extracts only uniquely attributed Goal and Completion Authority sections with
matching renderer bytes. A closed `system_observation` type admits these two
kinds. The private issued System record owns their immutable list, effective
bytes and physical partition. This replaces the Goal-only field; it adds no
event store, mutable mirror, source-text classifier or permission authority.
Later tool requests reuse only this turn's issued observations. A fresh turn,
missing/mismatched partition or duplicate Dynamic IDs cannot borrow them.
Task, Gate, Lane and clock context retain the task-514 suppression policy.

The new logical block is carried through receipts, source binding, forecasting,
TUI identity labels and the dashboard's closed decoder. Official-client
Resume preserves the original completion-authority `Sent_every_resume` event
semantics. Its source proof selects the exact observation's unique span in the
issued System partition. Missing, stale or absent issuers stay unavailable;
an unrelated Goal receipt cannot prove a completion-authority observation.
Goal held omission and `None` versus an empty prior override remain distinct.

Executed checks (no local Dune):

- `python3 docs/evidence/2026-10-25-completion-authority-retention/probe_retention.py`:
  exact pure modules, actual sanitizer and request-assembly function before
  and after; 70 baseline and 74 repaired checks across all four Goal/authority
  combinations, repeated tool rounds, fresh-turn reset, unknown/duplicate
  partition controls, overrides and physical span hashes.
- `python3 docs/evidence/2026-10-25-completion-authority-retention/probe_official_retention.py`:
  24 actual-source projection/codec/source-binding checks. Explicit unreachable
  notice/log dependency ports are listed in the receipt. This does not run
  Host preparation, SDK, vendor process or a transport.
- Dashboard turn-record decoder: 127 tests passed.
- Changed OCaml files: parse-only checks; see `parse-check.json`.

The existing native HTTP receiver test now has approval and rejection cases:
typed event → real world renderer → request assembly → actual provider HTTP
with a deterministic Read tool port → next request. The port supplies the read
result; this fixture does not perform filesystem IO. It checks correlation keys,
System receipt bytes, one authority
span, latest Tool feedback, no durable-history observation and unchanged
supplied event-queue value. The event is an explicit fixture input; this test
does not execute a completion judge or prove persisted queue acknowledgement.
The existing Host fixture additionally checks held authority retransmission
and exact System-derived source binding. These native fixtures were authored
but not run locally. Full native typing/linking, the actual production hook
path and post-fix model behavior remain for the parent integration session.
