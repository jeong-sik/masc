# Direct owner requests omitted shared Goal context

The fixed-candidate Keeper canary ran `dca2013ebf915a37631a5d95d305d226928c1b6f`
with local Ollama `qwen3:8b`. The latest retained provider input of owner turns
1 and 2 contains neither the workspace Goal ID, its criterion revision, nor
its recorded measurement ID. Autonomous turn 3 contains all three. The owner
requests supplied no Goal-ID hint. These observations establish a direct-path
delivery gap; they do not establish that the model will choose the correct
Task association or measure the Goal after receiving that context.

`baseline.json` records that read-only inspection. Reproduce it with:

```sh
python3 docs/evidence/2026-10-24-direct-goal-context/probe_snapshot.py CANARY_BASE_PATH
```

The probe verifies every inspected blob's recorded length and SHA-256. It
does not possess the raw HTTP body: the snapshot joins canonical model-input
parts to the SDK's exact pre-dispatch body digest and size. In source,
`keeper_agent_run.ml` captures the final model-input projection in the wire
observer and retains the latest request at turn completion. The SDK's
`complete_stream.ml` observes the serialized body immediately before sending
it. Consequently this evidence describes the latest retained request of each
absolute turn, not every internal provider request.

At repair base `915fcedb3f6`, `keeper_turn.ml` reads a direct world observation
but supplies only its approval authority to `Keeper_direct_turn_context`.
The direct preparer has no Goal input. The autonomous producer supplies
`Keeper_unified_prompt.active_goal_summaries`, which resolves the current
criterion and matching measurement from their authoritative stores. There is
no evidence that the initial absence of deferred Goal/create-Task schemas
caused the omission: the initial working loader advertises those names.

The repair passes the same typed Goal-summary result into immutable direct
preparation and shares the existing Goal renderer with the autonomous path.
It preserves failed source observations and leaves independent work valid.
The direct context remains in the ephemeral context carrier; the patch adds
no history write, store, mutation permission or completion gate.

`test_keeper_direct_goal_provider_wire` is a native regression with a local
HTTP receiver. It uses the real direct preparer, Keeper context assembler,
AGENT_CORE carrier and Runtime_agent serialization. Its five cases inspect
the received request for current Goal/revision/measurement, changed revision
without stale measurement, explicit measurement failure, explicit Goal-store
failure without recovery substitution, and independent work without a Goal.
It also checks the OpenAI-compatible returned checkpoint does not retain the
ephemeral carrier. This fixture exercises delivery with a deterministic peer;
it does not exercise a live Keeper's choice of tools or Goal completion.

Local checks: all seven changed OCaml interfaces/implementations parsed;
`git diff --check` passed. See `source-checks.json`. No local Dune build,
native typecheck, native receiver-test execution or post-fix Keeper canary was
run by this author. The parent integration session owns focused native CI and
the fresh exact-candidate live canary.
