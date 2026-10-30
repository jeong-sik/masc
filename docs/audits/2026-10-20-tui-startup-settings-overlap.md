# Startup settings and terminal initialization

## Source finding

`main` synchronously resolved, read and parsed runtime settings before reading
termios, detecting the terminal profile, creating presentation/selection state,
preparing restoration and signal callbacks. Those independent terminal-initialization
steps do not consume the saved theme, opening, input-priority or voice-send choices.
The settings are required before setting-dependent output and the first key is
handled, not before all independent initialization.

This follows the workspace-access preparation source unit. It does not relabel
the already parallel HTTP collector or claim that the observed live Loading
incident is resolved.

## As-Is / To-Be

| Boundary | Before | After |
| --- | --- | --- |
| Settings read and independent terminal initialization | Settings complete, then terminal initialization | Original read prepares through the shared I/O pool while terminal initialization proceeds |
| First setting-dependent output/key handling | After settings application | Still after the exact original settings promise and application |
| Saved choices | Applied before operator interaction | Same; no delayed saved choice overwrites an operator edit |
| Normal settings file read and parsers | One load; existing TUI and voice parsers | Same one load and same parsers |
| Ownership | One synchronous call | One switch-owned child/result promise and immutable snapshot |
| Failure | Original load exception or typed field errors | Original exception in failed promise; typed field errors remain in the same snapshot |

In the source dependency graph, `read → independent setup` becomes two branches
joined before settings application and setting-dependent output. If both branches
can progress, the idealized joined interval changes from `read + setup` to their
maximum, plus handoff/observation cost. This is a dependency description, not a
timing estimate, speedup verdict or proof of simultaneous physical execution.
Shared-pool pressure, scheduling, metadata and CPU can prevent useful overlap.

The new work is one child/future per normal Eio startup read, pool submission,
immutable receipt and clocks. No new pool, cache, retry, timer, timeout or numeric
gate is added. A missing switch explicitly preserves synchronous reading. The
source does not reduce file reads, parsing passes or normal HTTP requests.
An independent terminal-initialization failure can abort while this read is
pending; the root switch still owns its physical settlement and the unfinished
settings attempt must not be reported as successful. Failure precedence can
therefore differ when both independent branches fail.

## Resource and application contract

`Masc_tui_config.prepare_startup_read` returns the standard Eio promise for this
read. The child uses the existing `Domain_pool_ref.submit_io_or_inline` policy;
only the loader is passed to the pool. UI state, theme application, terminal
control and decisions remain on the caller. The pool's existing cancellation and
physical-settlement behavior remains authoritative; the child is owned by the
supplied switch. A pre-scheduling switch check avoids abandoned preparation on an
already cancelled switch. Awaiting the result never retries the loader or borrows
a later read's data.

The saved-setting application block is moved without changing its assignments.
It runs before installing the session signal handlers or entering raw mode, and
therefore before `Frame_presenter.setup`, page-theme sync, capability probing and
ordinary key processing. A settings wait does not take terminal ownership or
replace the original pre-session interrupt behavior. The original settings
remain a prerequisite. This unit does not make
input usable while settings are indefinitely blocked, and it does not introduce
late-setting revisions or silently use temporary defaults.

Returned settings can still contain the original loader's typed field errors
and existing defaults; reader return does not prove healthy configuration.
Concurrent external edits can be observed before or after the original file
snapshot, as with the synchronous reader. The snapshot is not a current-file
mutation permission or an atomic multi-store observation. Existing Runtime config
writes still acquire their own lock and read current text. A retained startup
promise is local to that one read, not a global/process cache or fresh evidence.

## Observation and limits

Requested, actual reader entry/return, successful submission observation and UI
application are distinct events under existing routine/lazy diagnostics. The
immutable successful receipt carries reader entry/return and settings; the
request carries its original start clock. Reader time includes path resolution,
metadata, file loading and both parsers; it is not pure disk I/O. Submission
observation is the child resuming after the common pool, not physical worker
cleanup or UI application. Applied time is state application, not terminal
acceptance, paint, input latency or useful Task progress.

With diagnostics enabled a normal successful read has five detail event sites.
Default routine suppression avoids formatting/emission. Clocks, promise and
snapshot still add work; enabled logging uses the existing lossy console/ring
paths. Missing events remain unavailable. Raised/interrupted readers record their
own event; cancellation before reader entry can leave a requested-only sample.
There is no fabricated success, zero duration or completion for that unfinished
read. A failed promise or caller interruption never substitutes default settings.
No token, runtime TOML contents or voice secret is recorded by these diagnostics.

## Authored compound scenario

The existing unexecuted ordered-conversation/config-write scenario now obtains
the actual asynchronous startup snapshot while initializing its session state.
It then performs the original A→B→A visits and an intervening real Runtime edit,
drains the actual writer outcomes and reads current settings. Awaiting the
original promise afterward must still yield the original Last-Keeper snapshot
and original theme, while current disk retains the newer opening/theme and FIFO
visit receipt. This exercises the real loader, common pool, frozen observation
and durable writer boundary. It does not execute terminal initialization, force
physical overlap or validate a first frame/key. No helper/count, wording, layout,
row-order, snapshot-screen or PTY test is added.

Only parsing and source/diff inspection are performed here. No local build,
typecheck, test execution, CI, native/model/audio/PTY/controller/report run,
installation/restart/live write, independent approval or merge is performed.

## Original goal remains open

The complete goal still requires original Ask → original Task → useful work,
exact preparation attribution/frozen discovery reuse, ordinary/nested/dynamic/
effectful Composition resource continuity, held-job/shared-backend continuation,
cold usable input and TUI readability/visibility, and matched actual Before/After.
This unit changes one preparation dependency only. Actual comparisons must use
matched source/runtime/config/terminal cohorts, include the new work, and retain
failed, cancelled, interrupted, refused, not-started and unfinished attempts.
The current code-only restriction leaves those runtime outcomes unverified.
