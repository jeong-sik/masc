# Regular session snapshots and private output creation

| Boundary | As-Is | To-Be |
| --- | --- | --- |
| Output creation | `open_out` reopens a fixed `.tmp` leaf, including FIFO/symlink | Exclusive fresh regular output in the original directory |
| Publication | Fixed temporary inode renamed after flush/finalizer | Fresh output must flush and close successfully before rename |
| Existing temporary resources | May be opened, truncated, waited on or renamed | Left untouched; only this writer's new output is cleaned on failure |
| Restore input | Existence stat, then path-based blocking JSON read | Regular leaf lookup, nonblocking open, descriptor kind/identity, same-channel JSON |
| Ready destination | Prior restore permission alone admits a write | Current nonregular leaf records typed refusal before output creation |
| Cancelled entry | Can reserve a restore token before cancellation is checked | Entry check precedes token reservation; completion check remains |

Review #44417/5588662113 section 5 describes a concrete source path: one writer
can rename a FIFO from the fixed temporary namespace into the authoritative
snapshot. A subsequent startup can then wait for its writer while holding the
shared persistence mutex and owner activation. A second writer in the previous
fixture replaced that FIFO with a regular file, leaving the single-writer case
unaddressed. No production occurrence or elapsed delay was measured here.

Output now uses OCaml 5.5 `Filename.open_temp_file` with the actual snapshot
directory and basename. Its installed implementation uses exclusive creation
and private default permissions. No preexisting `.tmp` path is opened or removed.
The original serializer/defaults/row order and independent immutable map captures
remain. Worker serialization still begins before capture and spans flush, an
explicit successful close and rename. On failure, descriptor cleanup and removal
apply only to this fresh output; the original exception/backtrace reaches the
existing typed host-error boundary. A completed rename is not rolled back. No
fsync or crash-durability guarantee is added.

The actual snapshot leaf must be regular. Directories, symlinks, FIFOs, sockets
and devices retain a typed `Non_regular_file` failure and remain preserved for
the process lifetime under the existing policy. Configuration-directory symlinks
are not globally prohibited; this rule concerns the final snapshot component.
A Ready path is checked again before output creation, so a new nonregular
destination cannot rely on a previous successful restore to authorize replacement.

Input lookup is followed by a close-on-exec, nonblocking read-only open and
descriptor inspection before JSON. Descriptor kind and device/inode must match
the regular leaf lookup; an observed identity change becomes a read failure.
JSON uses that same channel, which is closed on every return/failure. A FIFO
substituted between lookup and open therefore cannot wait for a writer at open;
this follows the [POSIX open contract](https://pubs.opengroup.org/onlinepubs/9799919799/functions/open.html).
This is not instantaneous disk/network-filesystem I/O or a lock against external
directory mutation. The shared host worker and caller completion/cancellation
boundaries remain. Already-cancelled callers now fail before reserving a token;
cancellation after admission still must not be inferred to mean physical exit.

The fixture now authors thirteen unexecuted actual persistence/resource cases.
Concurrent real saves publish a regular snapshot while a preexisting temporary
FIFO has no reader and remains untouched; a separate case retains a temporary
symlink and its target bytes. FIFO, directory/child evidence and symlink/target
snapshot leaves are refused and retain live session/profile authority. A Ready
destination replaced by FIFO is preserved. Normal regular-file cancellation is
tested before admission, followed by preserved original bytes and fresh restore.
Original round-trip, duplicate/optional policy, failed JSON/root preservation,
save-first and first-refusal behavior remain. A parent symlink loop exercises
actual read failure, and a dangling parent causes actual output creation failure
before repair and successful save/forget/load.

The unsupported FIFO-as-output and held-FIFO-as-input fixtures and native
condition/thread helper are removed. The cancelled-entry case does not prove
post-start physical read cancellation, and the removed connected-FIFO case is
not claimed as concurrent regular-read coverage. No replacement production I/O,
invocation-count/helper, UI wording/layout/snapshot or PTY test is introduced.
The target drops unused direct core/thread libraries; existing Eio/JSON/Unix
dependencies remain. No scenarios were executed.

Source quantities are one fixed output name replaced by a fresh exclusive name,
one additional typed restore/refusal category, and nine registered scenarios
reworked/extended to thirteen. These are not physical I/O counts, coverage or
speedup. New costs include fresh-name creation, current-destination lookup,
descriptor metadata/identity checks, explicit close and failure cleanup. Actual
worker dispatch, global mutex wait, read/decode, map/CAS, write and readiness
wait costs remain. No timeout, pool, cache, runtime knob or numeric gate is added.

Verification is parsing only for three changed OCaml files, whitespace checking,
source preservation and direct consumer/dependency inspection. No type/warning/
link check, Dune/build/test execution, CI dispatch/watch/poll, controller/native/
model/TUI execution, install/restart/live write, independent acceptance or merge
is established. All six original goal axes remain open: original Ask/Task useful
work, exact preparation/frozen discovery, Composition continuity, held/shared-
backend reactivation, cold usable input/TUI readability/visibility and matched
actual cohorts retaining failed/cancelled/interrupted/not-started/unfinished work.
