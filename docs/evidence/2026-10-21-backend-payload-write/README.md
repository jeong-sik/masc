# Backend payload writes and scheduler availability

## Problem and scope

The live server at `8c2b56cb19a9f44397aa876a81396ad872ba5ec0`
showed shared request delays during a read-only TUI observation. Between
2026-10-20 16:31:04 and 16:32:10 UTC, 24 independent fresh HTTP requests per
route produced these observations:

| Route | Median | Maximum | Transport failures |
| --- | ---: | ---: | ---: |
| Full health | 239.65 ms | 9255.08 ms | 0 |
| Keeper memory journal | 340.62 ms | 15001.09 ms | 1 |
| Keeper child-content hints | 338.015 ms | 15001.40 ms | 1 |

The last two maxima are the observer's 15-second timeout, not successful
endpoint durations. Existing clients and Keeper lanes remained active. This
is neither a controlled before/after comparison nor evidence that the TUI
caused the delays.

A 10-second macOS process sample starting at 2026-10-21 01:31:52.441 KST
contained 749 main-thread observations, of which 685 had a `writev` leaf
under Eio POSIX. Those are sample counts, not durations of one syscall.
The descriptor type/path was not captured; socket and pipe writes share
this implementation. Raw runtime logs and process samples stay private.

Source inspection nevertheless identifies a blocking-file boundary:
`Backend.FileSystem.set` and `set_if_not_exists` called `Eio.Path.save`.
The installed Eio implementation performs regular-file `writev` on the
calling scheduler thread. A blocking disk write can therefore delay all
fibers on that scheduler. This PR changes that boundary; it does not claim
that these particular calls caused the recorded live stalls.

## Change

Both operations retain their existing capability-based path resolution,
striped writer mutex, compression, file mode, close, temporary-file rename,
key-index update and error cleanup. Only payload writing moves to a Unix
system thread. `Fd.use_exn` pins the already-open capability descriptor
for that worker; no ambient path is reopened. Short writes and EINTR
continue the same write, while zero progress and other failures propagate.
The worker finishes before the caller closes, renames or cleans up the file.
Resources without a Unix descriptor retain the previous Eio flow writer.

No new timeout, concurrency limit, durability promise or public API is added.
Compression and reads remain outside this change.

## Verification

`python3 docs/evidence/2026-10-21-backend-payload-write/probe.py`
extracts the private writer verbatim and compiles only that fragment against
installed OCaml 5.5.1 and real Eio/POSIX file capabilities. Eight scenarios
passed: empty, UTF-8/binary, multi-megabyte contents, short writes plus EINTR,
zero progress, ENOSPC, scheduler progress while a worker write is held, and
caller cancellation while that worker is held. Faults and the blocking hold
are injected around Unix writes in the probe only. See `probe.log`.

This is a narrow source-extraction experiment, not a local Dune build or
full Backend linkage. The descriptor-free fallback is source reviewed,
not exercised by this probe. Existing `test_backend` and
`test_backend_coverage` are the requested native verification targets for
public set/get, compression, errors, concurrent operations and atomicity.
A source approval, native result, installed artifact and observed live
performance remain separate evidence.
