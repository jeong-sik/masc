# Keeper Continuity Production Runbook

**Status**: production release gate
**Updated**: 2026-09-05

Keeper continuity means that one ordered Keeper lane can restore its agent core
checkpoint, consume typed wake events, and keep making observable progress
without blocking other Keeper lanes.

## Release Gate

Release only when all items are true:

1. checkpoint save and restore use agent core checkpoint primitives;
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

## Undecodable Stores at Boot

Boot decodes every keeper meta (`<base>/.masc/keepers/<name>.json`) and every
current Memory OS snapshot (`<base>/.masc/config/keepers/<name>.memory-current.json`)
before any Keeper lane starts. When a file does not decode with this build, the
process does not start. It exits 1 and the startup log carries one line per
file:

```
[FATAL] Critical startup failed before readiness; refusing partial BasePath ownership: Keeper persistence preparation failed: boot refused: 1 store(s) this build cannot read
  memory_current keeper=sound path=<base>/.masc/config/keepers/sound.memory-current.json: <path>: invalid JSON: ...
strip or repair the files and run `deployment_preflight_helper validate-stores` against this base path, or start with --accept-store-quarantine to move them aside and start those keepers with empty stores
```

The files are not touched. Two ways forward:

1. Repair or strip the files, then confirm with
   `deployment_preflight_helper validate-stores --base-path=<base>` and start
   again. This keeps the keeper's memory.
2. Start with `--accept-store-quarantine`. Each refused file moves to
   `<path>.rejected-<timestamp>` (kept as bytes), the snapshot's journal gets
   a `quarantined` line, and the keeper starts with an empty store. The flag is
   for one start; do not put it in a launcher.

`scripts/deploy.sh` never reaches this refusal: its `validate-stores` preflight
stops the deploy on the same files before the executable starts. A refusal
after a `deploy.sh` start means the preflight and boot disagree, which is a
defect to report, not a reason to pass the flag. Design: RFC-0420.

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
