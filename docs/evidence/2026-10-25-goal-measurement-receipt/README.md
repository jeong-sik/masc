# A Goal measurement receipt reports the actual lifecycle

Repair base: `1c6205ea60bd6fc225450fdda1b9c691b92aa3a2`.

The actual candidate54e8 Qwen run continued real beta/gamma work after Task001
approval and recorded a3/3 measurement. Its final public response27 then called
the Goal verified/achieved, incorrectly described approved Task001 as awaiting,
and predicted that Task approval would complete the Goal. The actual API said
`verification: reported_only`; persisted Goal phase remained `executing`.
The canonical tool description and runtime prompt had already delivered the
observation-versus-completion distinction. This was not missing documentation
on the wire, and the strict G3 case remains a failure until a new actual run
satisfies its full contract.

Read-only failed-run evidence:
`/tmp/masc-goal-54e8-qwen-postapproval/20261024T154010576374Z.json`, SHA256
`deade748cbf2802db9b283289e17d2d2064a98cf919ef5d26012550b9025017c`.
No raw thinking is copied into this change.

## One transaction, one receipt

`Goal_measurement.record` and `record_json` now return a private receipt with
the measurement and immutable `goal_at_recording` from the same existing
`Goal_store.transact_goal` result. The transaction already holds the Goal lock
while recording the observation. There is no second Goal read, new store,
phase copy in the durable measurement schema, comparison with the target, or
completion transition.

MCP and HTTP success paths use the same `receipt_fields` serializer:

```json
{
  "measurement_status": "reported_only",
  "measurement": { "...": "the unchanged observation schema" },
  "goal_at_recording": { "...": "the actual Goal, including phase" },
  "completion_effect": "unchanged"
}
```

Each existing transport keeps its success envelope. There is no ambiguous
`verification` field in this receipt. Completed and Dropped Goals still accept
observations and report their actual phases; suspension restore states survive.
The typed API cannot construct a receipt outside its producer. Criterion
changes still refuse stale measurements.

The tool description names the receipt and separate verifier/human steps.
The existing Keeper Goal paragraph gains one reporting sentence tied to the
actual returned phase and subsequent observed transitions. This changes no
Task approval or Goal completion policy and adds no runtime gate.

## Verification scope

`probe_receipt.py` compiles and executes the full actual Goal measurement
implementation and interface, actual lifecycle source/interface, pure evidence
grammar, Goal record/serializer source, MCP measurement handler, and HTTP success
payload expression. Named in-memory ports replace transaction/lock/backend,
identifier, clock, logging, context and transport envelopes. It does not execute
the actual Goal-store lock, filesystem writer, HTTP server, SDK or model.

The21 checks include the exact baseline payload, all11 lifecycle values,
post-unlock interleaving, immutable later serialization, no subsequent Goal
read, stale revision refusal, unchanged durable row shape, rejected requests,
and optional frozen-canary measurement/Goal identity preservation. The full
measurement module is compiled with its private interface and warnings4/32/69
as errors. `source-check.json` records compiled input hashes and results.

Run the ordinary19-check source probe from any checkout location:

```sh
python3 docs/evidence/2026-10-25-goal-measurement-receipt/probe_receipt.py
```

For a controlled inference-only comparison, pass a read-only frozen observation
snapshot with `--canary-snapshot` and a private output with `--receipt-out`.
The two additional checks preserve the existing captured measurement identity,
value, actor and time while emitting the actual new serialized MCP payload.
This output is source execution with effect ports, not a new server response
or actual G3 proof.

The existing native `test_goal_verification_gate` consumer exercises real MCP
dispatch/storage. Its new case covers all11 lifecycle values, Goal primary and
mirror byte preservation, unchanged durable schema, immutable receipt after a
criterion edit, and stale criterion rejection. Existing evidence/phase tests
and the direct HTTP Goal fixture consume the changed typed result.

Native run [40110334799](https://github.com/jeong-sik/masc/actions/runs/40110334799)
at published candidate `3014cfce79636f1e41cc39f6019a3428c6912145` passed all
50 Goal verification gate cases and the canonical tool TOML parity case. The
direct HTTP suite passed five cases and failed its old empty-Goal assertion:
the parent now deliberately delivers `Active Goals (0)`, while that assertion
expected no Goal heading. The existing assertion was corrected in test-only
`ec664e53b7eda6a7dae4eb09daa04b56ad98997d`.
Run [40111175993](https://github.com/jeong-sik/masc/actions/runs/40111175993)
then passed all six actual HTTP cases at that test-only head. Product input
trees match candidate 3014. These are separate run/head scopes; the entire list
was not rerun at one head. [The original result](native-result-3014.json) is
preserved rather than relabeled as a pass.

`parse-check.json` records changed OCaml parsing, TOML parsing/schema-pin
consistency, Python parsing and diff checks. No local Dune, CI watch, publishing,
old-canary mutation, or model inference was performed by this author.

Changed interface trace:

- `Goal_measurement.record/record_json` → direct record fixtures and MCP/HTTP
  consumers → actual-source probe plus authored native Goal suite.
- `receipt_fields` → MCP handler and HTTP success payload → exact-source
  payload execution; actual isolated transport observations are recorded below.
- Canonical tool TOML → embedded Goal schemas → updated existing parity pin;
  actual next-binary schema requires a fresh build.
- Keeper reporting instruction → next candidate prompt → future actual wire
  and model observation; source wording does not establish compliance.

Parent integration uses published baseline895df663fb303ee2fa95c38bbd28b571db9abb62 in the replay script. Its baseline workspace_goals.ml bytes equal author1c6205e; published-baseline-binding.json records the binding.

The root rerun in `source-check.json` contains the ordinary 19 checks;
`independent-root-source-check.json` contains the independent 21-check run with
the frozen canary identity control. The
[frozen inference results](frozen-inference/README.md) preserve both overclaiming
arms and the limited full-prompt improvement. They do not replace a fresh
actual Keeper run. The new isolated runtime selects candidate 3014 explicitly;
the test-only correction has identical product input trees. No production
installation, Goal proof or human confirmation follows from these checks.

macOS run [40110337126](https://github.com/jeong-sik/masc/actions/runs/40110337126)
completed successfully with explicit source 3014. Its workflow head is
`98a1508e6ecbda1d38d33aa7d0eb7f366b420ddf`, distinct from that source. The
[checked server](server-extraction-receipt-3014.json) has SHA256
`bd9042e019d31c377e8c9ca72409bc5b152052dc79dd70621f027cc008c475b6`.

## Actual HTTP and MCP receipt transport

A separate isolated server using that checked binary received two controlled
operator observations through the actual MCP and HTTP endpoints. Both returned
the same receipt fields, preserved the exact existing Goal with phase Executing
and said the completion effect was unchanged. Goal primary/mirror bytes stayed
unchanged. A stale HTTP revision returned 409 and the latest accepted observation
remained the MCP one. [The receipts and summary](http-runtime/summary.json)
preserve the requests, responses and final Goal detail.

This fixture created no Keeper and made no model call. It covers actual transport
with Executing, not every lifecycle or model compliance. The driver's two local
fixture-shape mistakes are disclosed in the summary/preflight record; the final
projection correction was read-only and did not repeat measurement effects.
The separate HTTP-only server was stopped after capture.

## Latest actual Keeper result

The [new 3014 Qwen cohort](../2026-10-25-goal-receipt-runtime/README.md)
completed with G2 and G3 failed. It omitted the Goal link; after separately
controlled link/approval it reworked alpha and resubmitted the Done Task,
without measuring the Goal or doing beta/gamma work. The new measurement
receipt was therefore not invoked. Its actual model interpretation remains
unmeasured. The latest campaign ledger is 9/11, with previous 10/11 coverage
kept as history. A separate source repair addresses loss of the completion
authority observation after the first tool request; no model success is
inferred from that input defect or repair.
