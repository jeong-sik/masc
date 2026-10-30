# Session save completion, preservation and host failure

| Boundary | As-Is after #44435 | To-Be |
| --- | --- | --- |
| Save return | Unit for both actual replacement and preservation | `Saved`, `Skipped reason` or `Save_failed error` |
| Preservation reason | Boolean permission and generic path warning | Existing original unobserved, restore unsettled, or original typed refusal |
| Refusal evidence | Path refused without its cause | First recorded read/JSON/root cause retained for that process/path |
| Expected write errors | Exceptions; reap catches only `Sys_error` locally | Typed system/Unix write failures, warned without creating a restore refusal |
| Repeated preservation | Warn on each skipped save | Startup warning explains memory-only sessions; repeated skip uses routine log |

An authoritative stack refresh found concurrent #44435 while a separate
owner-capability approach was being prepared. The competing approach was kept
only in a private local commit, without publication or lower-ref pushes. The
current native stack was imported with `gh stack`; this unit builds above
#44435 and retains its process/path refusal, save-first admission, pending-token
ownership and read/write host mutex. It does not publish a duplicate preservation
fix or change the process-restart requirement after failed restore.

Save now returns three closed outcomes. Only `Saved` follows completed original
flush/close/rename and the caller's cancellation check. `Skipped` carries why
the original was preserved before any output is opened: an existing original
without restore, a restore without successful settlement, or a typed refusal.
Unsettled includes a cancelled restore whose successful authority was never
published; it does not assert a physical worker is still running. Save-first to
a genuinely missing path retains its original CAS admission.

The existing refusal state now retains the first failure recorded by its CAS.
Later read/JSON/root errors remain actual observations of their own attempts,
but do not replace the reason that originally refused writes. Read failures
while checking a save-first path also retain their original cause. Other paths
retain independent policy, although the existing host mutex still serializes
physical persistence work. No additional registry, timer, numeric gate, cache,
environment variable or quarantine operation is added.

Expected `Sys_error` and `Unix_error` from the host operation become structured
write failures and receive a warning with their path and cause. They do not set
restore refusal; after the real resource is released the next normal save may
succeed. Cancellation and unexpected exceptions still propagate. A failed write
does not promise rollback or removal of all temporary residue; the original
writer's cleanup/rename behavior remains. No fsync guarantee is added. Reap
consumes all typed outcomes after save has emitted its observation, rather than
equating a unit return with replacement or catching only one host-error form.

Startup failure warns that the original is preserved and new live sessions
remain memory-only until repair and process restart. Repeated skips use the
existing routine log level and retain their reason in the API. This keeps
failure evidence while avoiding a warning per maintenance skip. It does not
establish a successful reboot, session continuation, input or UI observation.

One new unexecuted actual-resource case creates a directory at the real
temporary output path, observes `Save_failed`, keeps live initialize/profile
authority and no completed snapshot, removes the blocking fixture, then requires
actual save/forget/load to restore that same authority. Existing real FIFO
cancellation and save-first scenarios assert distinct unsettled/unobserved skip
reasons. Actual invalid JSON/root cases retain typed failure reasons, original
bytes and usable live session authority through reap/save. The real directory
read-failure case retains the first read refusal after a later JSON failure,
preserves both replacement bytes, and permits an independent healthy path.
All eight previous scenarios retain their original resource/protocol purpose.
No scenarios were executed, and no invocation-count/helper, UI wording/layout/
snapshot or PTY test is introduced.

Source quantity is one undifferentiated return replaced by three save outcomes,
three skip categories and one new actual write-resource scenario. These counts
are not physical I/O, elapsed time or speedup. Error/cause storage, result
allocation, CAS retries and diagnostics have costs; worker dispatch, mutex
wait, read/decode, restore map application and actual write costs remain.

Verification is parsing only for the three changed OCaml files, whitespace
checking and source preservation/consumer/dependency inspection. No type,
warning, link, Dune/build/test execution, CI dispatch/watch/poll, controller,
native/model/TUI execution, installation/restart/live write, independent review
acceptance or merge is claimed. Bootstrap, maintenance callers, re-export
inclusion, runtime prompt and Dune remain unchanged. All six original goal axes
remain open: original Ask/Task useful work, preparation/frozen discovery,
Composition continuity, held/shared-backend reactivation, cold usable input/TUI
readability/visibility and matched actual cohorts retaining failed/cancelled/
interrupted/not-started/unfinished attempts.
