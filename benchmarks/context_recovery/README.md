# Context-recovery runtime benchmark

This benchmark measures whether a Keeper escapes stale recalled context when a
live repository contradicts it.  It reuses the coding-outcome runner so the
verdict remains a real workspace artifact, never a model judge or CI result.

The three cases mirror the STALE benchmark's dimensions:

- `l1-context-state-resolution`: select the live value over recalled state.
- `l1-context-premise-resistance`: reject a false premise repeated by memory
  and the task message.
- `l2-context-policy-adaptation`: make a downstream code decision from the
  live state without being told that the memory is wrong.

Each case has a `memory.json`.  The runner converts it into the production
`memory-current.json` wire shape and verifies through `/last-prompt` that the
Keeper actually received the stale claim.

`--memory-mode verified` also runs the case's deterministic `probe.sh` against
the copied live workspace and places its exact output in a one-turn operator
note.  Prompt capture must contain both the stale claim and live probe.  This
is the state-anchored PoC: the probe reads state; it does not grade the draft.

`--memory-mode filtered` runs the same live probe before the turn, retracts the
seeded claim from the current snapshot, and publishes the probe result as
revision 2.  The run stores before/after snapshots and the journal line;
`last-prompt.json` must contain the refreshed claim and must not contain the
stale one.  This is the model-before-filter PoC.

Run the no-memory control and stale-memory condition into separate evidence
directories:

```bash
scripts/harness_coding_eval.sh \
  --models ollama:qwen3:8b \
  --case-ids l1-context-state-resolution,l1-context-premise-resistance,l2-context-policy-adaptation \
  --memory-mode off --repeats 1 --out /tmp/context-recovery-control

scripts/harness_coding_eval.sh \
  --models ollama:qwen3:8b \
  --case-ids l1-context-state-resolution,l1-context-premise-resistance,l2-context-policy-adaptation \
  --memory-mode seeded --repeats 1 --out /tmp/context-recovery-stale

scripts/harness_coding_eval.sh \
  --models ollama:qwen3:8b \
  --case-ids l1-context-state-resolution,l1-context-premise-resistance,l2-context-policy-adaptation \
  --memory-mode verified --repeats 1 --out /tmp/context-recovery-verified

scripts/harness_coding_eval.sh \
  --models ollama:qwen3:8b \
  --case-ids l1-context-state-resolution,l1-context-premise-resistance,l2-context-policy-adaptation \
  --memory-mode filtered --repeats 1 --out /tmp/context-recovery-filtered

scripts/harness_coding_eval.sh \
  --models ollama:qwen3:8b \
  --case-ids l1-context-source-bound-refresh \
  --memory-mode source-bound --repeats 1 --out /tmp/context-recovery-source-bound
```

The report pass rate answers whether the final workspace is right.  The
`memory-seed.json` and `last-prompt.json` beside each run prove that the stale
claim was both written and injected.

`source-bound` uses `source-memory.json` instead of the ordinary snapshot. It
seeds a claim with the SHA-256 of the old source bytes, then copies a workspace
whose authoritative file has changed. The run is accepted only when:

- `last-prompt.json` contains no stale claim and does contain a typed
  `source_changed` invalidation,
- the ordinary workspace verifier passes, and
- `memory-source-final.json` contains one recreated fact whose source path and
  digest match the live file, with no pending invalidation.

This separates deterministic stale removal from model behavior. A model can
fix the workspace yet still fail the run by ignoring the requested
`keeper_memory_write(source_path=...)` recreation step.
