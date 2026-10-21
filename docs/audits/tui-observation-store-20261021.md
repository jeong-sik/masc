# TUI structured observation storage boundary

## Confirmed source gap

The previous structured Ask writer correctly populated the client Log.Ring, but
Main only redirected stderr and initialized log levels. `Log.init_from_env`
configures a level; it does not initialize the file sink. The readable console
summary does not contain structured details. The server dashboard reads its own
process's ring. Therefore the client facts had no actual persistent production
path after exit. The previous actual resource scenario explicitly initialized a
sink in its fixture; that was not evidence that Main did so.

## As-Is / To-Be

| Boundary | Before this source change | After this source change |
|---|---|---|
| Main startup | stderr mirror and level initialization only | Process-owned structured sink initialized before TUI state and read producers |
| Exit evidence | Structured client facts only in volatile ring | Existing dated JSONL below a unique private local session directory when initialization succeeds and policy admits rows |
| Server isolation | No client JSONL sink | Client directory under `.masc/logs/tui/session-<pid>-*`; server root daily files are not selected or imported |
| Restart/PID reuse | No retained client dataset | Fresh directory from standard Filename.temp_dir; no earlier client history imported |
| Initialization failure | No production initialization attempt | Expected filesystem error becomes a warning and Error result; Main continues without gating TUI startup |
| Initialization cost | Absent | Explicit started/observed clocks around directory/sink work; no latency reduction claimed |

`Masc_tui_observation_store` owns directory selection and the existing sink's
lifetime boundary. It derives the root through Common from the opening local
base and uses standard private temporary-directory creation. Main calls it once
after stderr redirection and level setup. Original workspace/server provenance
inside each event remains separate from the local process's storage location.
No later server identity, input body or event string determines a path.

Only expected Unix/Sys filesystem failures are converted to an Error explanation.
Unexpected exceptions and cancellation propagate. Initialization logging occurs
outside that conversion, uses the existing lazy logger and shared redacted
console/ring/file backend, and cannot trigger a second initialization attempt.
The existing process owns the sink channel. No new backend, configuration,
worker, authority, retry, timeout, endpoint or cleanup/expiry policy is added.

## Added costs and evidence limits

Creating directories, making a private session directory and opening the daily
file is synchronous startup work. The fresh empty directory avoids importing
historical server/session records. Admitted log writes still perform existing
redaction, UTF-8 sanitization, JSON serialization and synchronous sink flush.
The initialization event clocks retain the setup interval even though existing
input-reader startup observations start later. Those later intervals cannot be
called full cold-start measurements or silently omit this earlier work.

A path returned by initialization proves only the source's successful setup
boundary. Rows can still be filtered, missing after interrupted execution or
affected by the existing sink's I/O policies; flush is not fsync. The server
API and visible Logs surface are not automatically joined to the client store.
The separate stderr mirror remains. No actual install, UI, measured Before/After,
useful Task progress, runtime speedup or whole-objective completion is claimed.

## Actual protocol/resource scenario extended, unexecuted

The existing actual canonical Ask/answer/Task/frame/decoder/retained-result case
now calls the same production store initialization as Main, replacing direct
fixture-only sink setup. Completed, actually disconnected and missing-switch
reads still traverse the real production emitter, daily JSONL, dashboard JSON
builder and TUI decoder in the scenario. It also writes an actual server ring
log first, starts a second client directory under the same PID, and verifies
that server daily files and first-session bytes are unchanged. The second store
is private and does not replay prior Ask records. A real regular-file blocker
causes initialization failure; a later actual original read still settles using
the existing current sink and canonical Task resources stay unchanged.

This is one extended actual resource case, not a new helper/count/layout/wording/
snapshot/PTY test. It is not executed. Same-process sequential sink rebinding in
the fixture does not prove live concurrent multi-process isolation. The changed
interface was authored first, and direct executable/scenario library dependencies
are explicit. Parsing-only evidence is recorded separately from type/build proof.

No local typecheck/build/test, CI dispatch/watch, native/model/controller/audio/
PTY run, install/restart, live write, self approval or merge. Canonical lower
stack head/base identities and existing ancestry/review issues are preserved.

## Remaining comparison work

A strict offline reader/report still needs to consume actual retained artifacts,
join by explicit event and original instance/read identity, and retain failed,
cancelled, withdrawn, unstarted, unfinished and incomplete physical/UI traces.
It must distinguish original Task progress from successful follow-up reads and
include initialization/capture costs in any end-to-end cold-start comparison.
Reported versions and artifact paths are not binary/install execution identity.
