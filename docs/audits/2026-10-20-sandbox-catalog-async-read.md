# Sandbox image catalogue: move blocking observation off the Eio caller

Source comparison base: `6b34097b1ec586d9b313974d2812e49135f800b1`.
This is source evidence, not a measured loading incident or runtime speedup.

Related PR: [#44236](https://github.com/jeong-sik/masc/pull/44236).

## As-Is / To-Be

The shared backend inventory already uses exact route and owner indexes;
continuation intake already shares declaration acquisition within a pulse.
Neither is replaced here. A different preparation boundary remained synchronous:
`Keeper_sandbox_image_catalog.read_snapshot_for_load` directly opened and read
the whole host catalogue with Unix/channel operations on its calling domain.
The normal factory reaches it while resolving the first guest image. Owned-job
preparation, boot admission, sandbox status/control and workspace resolution also
use this catalogue. None of those call sites needs to own its blocking syscalls.

Only that immutable host-file observation now uses the existing labelled
`Eio_guard.run_in_systhread` boundary. Open, read and close complete in the same
callback. Existing absence and typed unreadable results return to the caller.
Shipped catalogue lookup, TOML interpretation and all runtime/factory mutations
remain on the original caller. A non-Eio caller uses the existing inline policy.
No pool, worker cap, timeout, retry, environment setting or global cache is added.

| Boundary | Before | After |
| --- | --- | --- |
| Host catalogue load from Eio | Blocking open/read/close on the caller domain | Same file observation through the existing systhread guard |
| Non-Eio catalogue load | Inline read | Same inline read |
| Missing/invalid/unreadable catalogue | Original absence or typed refusal | Same result; never an image fallback |
| Turn factory's first image | Resolve once while holding its protected mutex | Same lifetime and original mutex; only file observation moves |
| Compatible sibling calls | Share the frozen factory result/runtime | Same result/runtime and original waiting rules |
| New factory after promotion | Read again | Read again; no cross-turn memoization |
| Change preparation | Original bytes become a compare snapshot | Same snapshot through the read boundary |
| Save | Current-byte comparison and replacement under the durable lock | Same transaction, including stale-writer refusal and durability errors |

For N catalogue loads from Eio callers, N raw file observations move off those
caller domains. The number of host-file reads remains N. There are now N guard
submissions on that path and associated scheduling/runtime-event costs. Outside
Eio there is no offload saving. Parsing, path/config resolution, later backend
inspection and protected factory waiting remain costs; they are not made
nonblocking by this change. No latency, allocation, throughput or speedup value
is asserted. The existing guard's suspension label identifies file-observation
waiting; it does not measure pure I/O, prove UI paint or establish useful work.

## Ownership and unsuccessful attempts

The worker callback contains only the original Unix/channel read and immutable
result construction. It cannot pick an image, mutate a factory, start a guest
or publish a new catalogue. No exception is caught to retry the read inline.
The original guard owns Eio/non-Eio routing and cancellation behavior; a blocking
system call and an already-protected factory can delay cancellation settlement.
This patch adds no early-release promise. Image refusal may still be cached for
that original factory as before; a fresh factory is required to observe repairs.

The save-time `read_snapshot` remains inside the existing durable transaction;
an earlier asynchronous observation never authorizes overwriting changed bytes.
This change does not repair or replace metadata, original Ask/Task/run binding,
continuation authority, directory/CLI identity or a shared backend's effect
checks. Held-job presence is still only a hint before full inspection.

## Compound scenario specification, unexecuted

Use the existing typed guest-target and actual public owned-job/nested
Composition fixtures, without starting a real daemon. Within an Eio runtime,
hold a catalogue file read at its real file boundary while an independent
control fiber progresses. Concurrent ordinary and nested callers using the
same factory must await the original observation, use one frozen image/runtime
and preserve their own source Task/run/input. Mutating the catalogue after that
observation must affect a fresh factory, not a sibling in the original one.
Keep a different backend/owner's work independent. After release, execute the
original typed target and validate the resulting backend argv and effect result.
For change preparation, preserve the original snapshot, commit a competing
promotion, then require the original writer's stale-byte refusal.

Repeat through missing, unreadable and invalid catalogue states and through
cancellation while waiting/reading, retaining real cleanup and next-scope
reacquisition evidence. Do not replace a failed original with a new job, infer
effect completion from a ready image, or use helper/count/UI text assertions.
This paragraph is a scenario specification; no new executable test was added
and no fixture, cancellation case or backend protocol was run.

## Evidence limits and remaining goal

Only changed OCaml parsing and source/whitespace inspection are authorized here.
No typing/build/test, CI dispatch/watch/poll, native/model/PTY/controller/report
run, install/restart/live write, independent approval or merge is claimed.
Actual Before/After must include catalogue acquisition/settlement and the same
original request's first useful work, alongside caller input/paint timing, with
failed/cancelled/interrupted/unfinished samples retained.

All six goal axes remain: original Ask/Task/useful work; exact preparation and
frozen discovery; ordinary/nested/dynamic/effectful Composition; held reactivation
and shared backends; cold input/TUI readability/visibility/observation; and
matched actual cohorts. This source unit improves one blocking preparation
boundary and does not establish any axis complete.
