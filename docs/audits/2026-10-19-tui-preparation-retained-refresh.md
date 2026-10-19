# Keep original preparation evidence through an explicit recheck

Comparison base: `4777eb9a8bb4d550e1997e3dac67c4be6c3ccafb` (#43943).
This is a source/state comparison. No TUI, PTY, input or timing trial was run.

## As-Is / To-Be

Force-refreshing Keeper history previously replaced preparation details with
`empty` before the new read. The known report disappeared while waiting; a failed
replacement showed only an error. This also invalidated the selected preparation
read when the forced history refresh concerned another Keeper.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Explicit same-Keeper refresh | Discard request and all known reports | Retire its request/freshness and retain its last successful original snapshot |
| Before replacement request | No known preparation evidence | Retained snapshot with recheck pending |
| Owned replacement read | Generic loading | Retained snapshot with recheck in progress |
| Replacement fails | Only failure | Same original snapshot plus failed recheck; never fresh confirmation |
| Replacement succeeds | New completed snapshot | New completed snapshot; previous retained value released from state |
| Another Keeper's history refresh | Clear these details too | Preserve this selection's read/freshness |
| Unknown/no prior successful evidence | Pending/loading/error | Same states; no fabricated previous or empty evidence |
| New execution/journal/revision/workspace | Original selection and request checks | Same exact checks; retained evidence cannot enter the new selection |
| Hidden owned read completes | Cache without displaying | Same original-source cache behavior |

The new closed `recheck` type separates pending, loading and failed rechecks. The
existing view adds `Retained` carrying that state and the original immutable
snapshot. This is local TUI observation state, not a server outcome or Task phase.
Forced refresh changes only the requested Keeper's cached freshness and pending
capability. Reopening the visible selection creates a new nonce; old responses
cannot settle it even when they name the same original execution.

The model retains one successful snapshot through this lifecycle rather than
copying reports into another cache. Its exact target still requires journal
object identity and revision, Keeper, Turn_ref and operation. No Keeper-name,
timestamp or current-Task substitution supplies a missing link. A changed target
can start a read but cannot display the previous target's retained report. A
matching success replaces the retained snapshot; a matching failure preserves
only the same original target. Workspace retirement still uses `empty`.

The display renders retained reports through the same report/issue projection
as confirmed reports, with an explicit earlier-observation/recheck note. Partial
scan/return, malformed scan rows, excluded reports and recorded unfinished scopes
remain unchanged. The existing synchronous status projection receives the actual
emitted rows for history/menu measurement and drawing. No layout cap, word
heuristic, timeout, retry interval or automatic recheck loop is added.

This addresses visibility when a read is slow or fails. It does not diagnose or
repair backend Loading latency. The earlier owned-job scheduling change (#43943)
has its own source comparison and independent execution limits.

## Before / After boundaries and costs

For an already-observed exact target, retained successful snapshots after force
refresh change from none to the same one immutable observation. Prior content
remains explicitly unconfirmed through three recheck states. A target without
prior success still has no retained snapshot. This is state coverage, not a
measured report count, memory saving or elapsed-time improvement.

Same-Keeper explicit refresh still requests a fresh owned read. An unrelated
Keeper refresh no longer invalidates this preparation selection. Workspace and
HTTP expected-root/receipt checks, runtime-trace decode, original execution
binding and worker result admission keep their existing paths. Retaining reports
through failure extends their lifetime and adds state/row work; net memory,
render time, HTTP timings and keyboard/paint responsiveness are unmeasured.

Any matched Before/After trial must retain failed/cancelled/interrupted reads,
unfinished requests and unconfirmed source states. Record read completion,
state admission and actual visible paint separately; none is useful Task work.

## Evidence and remaining scope

The existing original-preparation/read-ownership scenario is extended with
same-source pending/loading/failure, replacement request retirement, successful
hidden completion, unrelated Keeper refresh, another execution, changed journal
revision and workspace retirement. It uses original decoded writer evidence;
the assertions inspect read capability/state and original snapshot identity,
never screen wording/layout/order or paint. These scenarios are authored and
unexecuted. Existing workspace/HTTP admission scenarios keep exhaustive handling
of the added local observation state.

Changed OCaml files are checked with parsing only, plus whitespace and the
unchanged changelog checker. No typecheck/build/test, CI dispatch/watch,
native/model/PTY/controller/report execution, install/restart, live config/prompt
write or own merge is performed. Independent source approval, runtime behavior,
actual input/paint and matched performance remain separate requirements. The
full original Ask/Task, preparation, Composition, held/shared-backend, cold-start
TUI and matched failed/unfinished cohort objective (#42799) remains active.
