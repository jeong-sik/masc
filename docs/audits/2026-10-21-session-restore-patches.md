# Session restore map preparation and current-registry application

| Boundary | As-Is | To-Be |
| --- | --- | --- |
| Decode result | Separate decoded row list | Immutable maps for the five existing session fields |
| Caller application | Each valid row updates three mandatory and any present optional fields | Each nonempty prepared field map merges once into its current registry |
| Duplicate IDs | Last valid mandatory values; last present optional values | Same policy accumulated in original JSON row order |
| Concurrent unrelated keys | Per-row atomic updates retain current keys | Each atomic union retains current unrelated keys, including on CAS retry |
| Read/activation | Named host worker, cancellation check, pre-publication restore | Same owner, executor, cancellation and readiness boundaries |

The previous unit moved blocking read/JSON decode into the shared I/O executor
and restoration before owner publication/readiness. Its caller still walked an
additional decoded row list and built each live map through individual atomic
updates. This unit prepares immutable per-field maps during that same host
decode. The caller checks cancellation, then unions each nonempty map into its
current atomic registry, preferring the original restore values on same-key
collisions. It never replaces the entire live map with a pre-read capture.

Source quantity uses N accepted rows, including duplicate IDs, P rows with a
valid profile, and T rows with a present transport context. Caller update calls
change from 3N + P + T to one per nonempty field map among the five existing
registries. These are source calls, not physical I/O, CAS attempts, CPU time or
latency. CAS retry can repeat the union. Decode still makes per-row map additions;
patch allocations, executor dispatch and caller union costs remain. With an
empty destination, the installed OCaml 5.5 Map implementation reuses the
immutable source map; nonempty destinations still require merging. No numeric
gate, pool, cache, timer or runtime setting is introduced.

Supported protocol versions retain their original admission rule. An unsupported
protocol or non-object row contributes no fields. Missing/invalid timestamps
retain the existing zero and last-active defaults. An absent/invalid profile or
absent transport does not erase an earlier duplicate value or an existing live
value. A present partial transport replaces its whole earlier transport object;
its individual optional labels are not merged. The original exact root shape,
read/JSON diagnostics and decoded accepted-row count remain. That count includes
duplicates and never controls execution.

The five registries remain separate atomic values. This is not an atomic
transaction across fields and does not promise the same intermediate interleaving
as per-row application. The supported restore contract still requires owner
activation before HTTP/stdio state/readiness publication. Unrelated current keys
survive; same-key restore values retain their previous overwrite priority.
Cancellation observed before application prevents application but does not undo
application already begun or forcibly stop a started host operation. Correct
readiness still includes actual restore work and can be later than the former
premature readiness. No overall startup speedup is established.

Two additional unexecuted actual resource/protocol scenarios are authored. One
connects the production reader to a real FIFO, withholds JSON, registers an
independent live session, then releases the read and checks both sessions'
original initialize/profile authority. The other applies actual persisted
overlays with duplicate supported/unsupported rows, invalid profile, omitted
fields, existing optional authority and partial transport replacement. It checks
public profile gates and actual saved JSON using the unchanged serializer.
The connected cancellation case now shares the real FIFO fixture; its original
cancel-before-release, absent authority and successful fresh-restore checks
remain. Existing round-trip and concurrent-writer cases remain. These are not
replacement I/O, invocation-count, helper, UI wording/layout/snapshot or PTY tests.
They have not been executed.

Verification is three OCaml files parsed only, whitespace checking, direct
consumer inspection and source preservation comparison. No type/warning/link
check, Dune/build/test execution, CI dispatch/watch/poll, controller/native/model/
TUI execution, installation/restart/live write, independent approval or merge is
claimed. The public function signatures, writer, protocol/profile gates, owner
activation, maintenance, re-exports, runtime prompt and Dune dependencies are
unchanged in this unit. The OCaml Skill records the map and evidence boundaries.

All six original goal axes remain open: original Ask/Task useful work, exact
preparation/frozen discovery, ordinary/nested/dynamic/effectful Composition
continuity, held-job/shared-backend reactivation, cold usable input/TUI
readability/visibility, and matched actual Before/After cohorts retaining failed,
cancelled, interrupted, not-started and unfinished attempts. Source call reduction
does not establish physical cleanup, visible input/paint, useful work or measured
speedup.
