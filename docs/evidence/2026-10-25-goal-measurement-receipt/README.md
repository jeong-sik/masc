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
and the direct HTTP Goal fixture consume the changed typed result. Native
execution remains pending, as does the TOML schema parity suite.

`parse-check.json` records changed OCaml parsing, TOML parsing/schema-pin
consistency, Python parsing and diff checks. No local Dune, CI watch, publishing,
old-canary mutation, or model inference was performed by this author.

Changed interface trace:

- `Goal_measurement.record/record_json` → direct record fixtures and MCP/HTTP
  consumers → actual-source probe plus authored native Goal suite.
- `receipt_fields` → MCP handler and HTTP success payload → exact-source
  payload execution; full transport execution remains unverified here.
- Canonical tool TOML → embedded Goal schemas → updated existing parity pin;
  actual next-binary schema requires a fresh build.
- Keeper reporting instruction → next candidate prompt → future actual wire
  and model observation; source wording does not establish compliance.
