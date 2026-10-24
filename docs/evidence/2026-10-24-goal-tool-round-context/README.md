# Goal context survives the tool loop without replaying the whole world

Actual candidate `c6e54ff523772596ce70a9b158f89c74fedeab17` delivered the
current Goal in raw request 000002. After its first tool result, requests
000003 through 000010 contained no fresh system-context carrier and neither
the criterion revision nor measurement ID. The accepted Task-create response
000007 was therefore driven by a request without those Goal observations.
The Task was created with no Goal link. `baseline.json` aligns raw request and
response hashes, Goal markers and emitted tool names. It retains no provider
Thinking text. Goal ID alone still appeared elsewhere in later requests and
would falsely suggest the full snapshot was present.

The cause is the existing `Dynamic_context` post-tool policy. That policy
deliberately avoids rebroadcasting Task, Gate, Lane, inbox and other world
state, following the measured task-514 repeated-answer failure. Changing the
whole block to recurring would undo that decision.

The repair gives the real Goal producer its own `Active_goals` prompt block.
Unified world context already identifies that typed layer. Direct preparation
now projects its existing immutable `goal_context` as the same typed layer,
without parsing text or introducing another Goal renderer. Initial request
assembly splits that exact layer from the renderer-issued Dynamic partition,
so the Goal appears once. Later tool requests retain only the issued Goal
block from the existing per-turn assembly. No store is reread and the rest of
Dynamic context remains first-request-only. Operator notes keep their existing
mid-turn behavior and order. A new owner turn starts with a fresh preparation.

The closed block vocabulary is updated through OCaml codecs, request receipts,
official-client projection, forecasting, TUI inspection and the dashboard's
strict decoder/metadata. This changes context delivery, not Task association,
effect authority, Goal phase or completion policy. It adds no gate, prompt
warning, budget, mutable mirror or conversation-history write.

Executed checks:

- Read-only baseline: actual multi-request HTTP bytes establish the pre-fix
  loss, including the request that produced accepted Task creation.
- `probe_assembly.py`: 17 checks passed against the complete pure
  `Prompt_block_id`, `Keeper_context_layers`, `Keeper_context_assembly` modules
  and the exact request-assembly function slice. These check one issued Goal,
  retention through later rounds, no other-world replay, no borrowing another
  turn and no promotion from mismatched renderer evidence. This is not a
  producer-hook or SDK-network execution claim.
- Existing dashboard turn-record decoder tests: 126 passed, including every
  known prompt-block ID through the full decoder path.
- All 18 changed OCaml interfaces/implementations parsed; `git diff --check`
  passed. No local Dune build was run.

The native `test_keeper_direct_goal_provider_wire` feature regression is
extended to three actual HTTP requests: a metric Read, actual bundled Task
creation and the final answer. Its receiver checks the Goal ID, criterion
revision and measurement in every fresh carrier, other world/clock context
only on the first request, one authoritative Task/Goal link and an ephemeral
measurement snapshot absent from the returned checkpoint. Its local Read is
an explicit fixture port; Task creation uses the real bundled handler. This
deterministic peer does not prove that a model chooses the correct association.
The native receiver test and post-fix live Keeper canary were not run by this
author; the parent integration session owns that exact-build validation.
