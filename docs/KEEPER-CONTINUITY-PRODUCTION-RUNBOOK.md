# Keeper Continuity Production Runbook

**Status**: production release gate
**Updated**: 2026-07-10

Keeper continuity means that one ordered Keeper lane can restore its OAS
checkpoint, consume typed wake events, and keep making observable progress
without blocking other Keeper lanes.

## Release Gate

Release only when all items are true:

1. checkpoint save and restore use OAS checkpoint primitives;
2. MASC owns domain transitions and exposes matching receipts/tool results;
3. the validation in
   [KEEPER-CONTINUITY-VALIDATION.md](./KEEPER-CONTINUITY-VALIDATION.md) passes;
4. lane isolation is proven under a busy turn, provider failure, and restart;
5. load/save/receipt errors are observable and actionable;
6. dashboard and status surfaces report typed lifecycle/checkpoint facts only;
7. no prompt, parser, sidecar, API, or UI derives runtime state from assistant
   prose.

## Evidence Bundle

Attach the exact validation command and artifacts for:

- Keeper identity, trace, generation, and turn IDs;
- input event delivery/queue evidence;
- checkpoint loaded/saved manifest rows;
- terminal execution receipt;
- domain transition receipts when mutations occurred;
- restart restore result;
- independent-lane progress during the tested lane's stall.

Do not substitute screenshots or narrative summaries for machine-readable
artifacts.

## Monitoring

Monitor per Keeper lane:

- checkpoint load/save outcomes;
- event queue age and delivery outcome;
- terminal turn outcomes and typed blockers;
- provider attempts and asynchronous completion wakes;
- time since last successful lane progress;
- other-lane progress while one lane is stalled.

A failure in one lane must not pause the fleet. Preserve the failed event and
surface its error; let unrelated lanes continue.

## Containment and Rollback

If checkpoint continuity regresses:

1. stop admitting new work to the affected Keeper lane only;
2. preserve its queue, checkpoint, manifest, and receipts;
3. keep other Keeper lanes running;
4. revert or forward-fix the checkpoint adapter that failed;
5. rerun the full typed validation before re-admitting the lane.

Do not reconstruct state from assistant text. Do not copy a prose summary into
task/goal/lifecycle storage. Do not silently discard the event that exposed the
failure.

The ownership and forbidden-protocol rules are normative in
[KEEPER-STATE-OWNERSHIP.md](./KEEPER-STATE-OWNERSHIP.md).
