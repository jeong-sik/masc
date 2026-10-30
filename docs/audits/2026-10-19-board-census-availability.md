# Board census availability and retained observations

Source baseline: `6e0667a1ddc203c9ce6db2bc294507f15bf0c675` (#43724).

## As-Is / To-Be / Before and After

| Aspect | Baseline | This layer |
| --- | --- | --- |
| Census storage | Raw list; empty also represented no successful observation | Existing Fetched observation states and independent pending dataset ownership |
| First read pending | Empty placeholder could look like nothing counted | Loading without an invented empty result |
| First read fails | Error discarded; raw list stays empty | Failed with the actual diagnostic and no observed zero |
| Received empty | Indistinguishable from unread/initial failure | Ready empty; a known zero when no census read is pending |
| Reread / failure after a successful census | Last value retained with no failure provenance | Retained value, pending status and last failure remain distinguishable |
| Header/sidebar totals during reread or failure | Could borrow retained counts as a current total | Use loaded-list count; retained census values remain explicitly last observed |
| Hearth palette/cycle | Uses raw last values | Same candidate values; palette qualifies retained observations |
| Owned collector ends or terminal reserves data without applying a census | No census failure recorded | Explicit unavailability while retaining an earlier value |
| Retired collector cleanup | Dataset owner protected | Same owner rule also protects a successor's availability |
| Workspace withdrawal | Census was not cleared with Board posts | Census values/candidates clear with Board data and read owners |
| Existing Board GET readers / added requests | 2 / 0 | 2 / 0 |

These are source-derived state/decision changes, not timing measurements. Five
existing Fetched view categories represent census observations; the pending bit
comes from the actual hearth slot. No second request generation, cache owner,
clock, timeout, action cap, retry or configuration knob is introduced.

## Storage, admission and lifecycle

`board_census` replaces the raw census field. A successful result records Ready,
including an empty list. Failure with a previous successful value records Stale
with that same value and the actual diagnostic; failure without a value records
Failed. A pending initial slot projects Loading. Retry preserves a previous
failure and retained values; receiving posts does not alter census state.

Result application still follows the original refresh/workspace/opaque dataset
owner checks. Census application itself does not grant authority. All full/scoped
terminal consumers use the shared state reservation helper. A reserved census
starts explicitly unavailable until an actual admitted result overwrites that
status. All production collector cleanup paths use the shared completion helper;
only a still-owned unconsumed census is marked missing. An old request cannot mark
a successor unavailable. No result is not evidence of physical worker exit or a
caught cancellation. The independent child diagnostic ledger retains that separate
meaning from #43720.

The census remains in the existing Board row; no screen row is added. Nonempty
last values remain available to list display, palette and previous/next hearth
selection. Stored empty and absent/unavailable remain distinct. Header and reader
index use a census total only for Ready without a pending hearth slot. Long error
text is terminal-sanitized and the label uses the existing width calculation.
Palette labels qualify retained counts without changing destination identity.

Workspace suspension and Board presentation withdrawal clear census observations
alongside read ownership/posts, preventing another workspace's hearth names and
counts from surviving in palette/cycle inputs. Ordinary census GET failure retains
the last successful census; workspace withdrawal has a different data boundary.
No posting permission, action token, source ordering or HTTP read proof is relaxed.

## Evidence and remaining scope

Three feature/state scenarios are authored, unexecuted: unread/loading/received
empty/initial failure with posts still pending; retained values through retry,
failure, missing result and actual terminal result; and superseded collector
cleanup plus workspace withdrawal. They exercise actual typed state transitions,
dataset ownership, candidate values and total-selection decisions. They do not
assert screen wording/layout/row order/snapshots or PTY output.

Seven changed OCaml files passed parsing-only checks. Source hashes and diff/
changelog metadata are retained separately at publication. No local Dune/typecheck/
tests, CI dispatch/watch, native/model run, install/restart, live prompt/config
write, runtime or paint verification is performed. Parsing is not typing,
scenario execution, independent approval, merge or installed behavior.

The full preparation/discovery attribution/reuse, cold-start input/readability/
observability, Ask-to-original-Task/useful-work, resource-owned ordinary/nested/
dynamic/effectful Composition, held-job/shared-backend and matched Before/After
scope remains active. Keep failed/cancelled/interrupted/unfinished samples. No
measured speedup or whole-goal completion is claimed.
