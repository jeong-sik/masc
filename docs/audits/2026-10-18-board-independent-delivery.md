# Independent Board posts and hearth delivery

Source baseline: `cf6e5421fb8686414df7f9cd47a3d791c4f7b4c0` (#43720).

## As-Is / To-Be / Before and After

| Aspect | Baseline | This layer |
| --- | --- | --- |
| Posts return before hearth census | Wait for pair before dataset publication | Publish posts on their own completion |
| Other Board reader completions required before publishing ready posts | 1 | 0 |
| Existing Board HTTP reads | 2 | 2 |
| Board logical sources | 1 | 1 |
| Board publication slots per request | 1 combined | 2 typed independent slots |
| Only posts delivered before terminal bundle | Combined ownership could not represent it | Terminal admits only the missing census, not posts again |
| One child fails after its sibling was admitted | Publication waited for both | Failure consumes only its own dataset; received sibling retained |
| Navigation or filter refresh supersedes Board | Replaces combined source owner | Replaces both typed dataset owners under one new request |
| Old collector finishes | Releases its remaining owners | Same identity rule; successor slots and collector survive |

These are source-derived dependencies and ownership counts, not measured latency.
No HTTP request, health probe, screen row, pool, retry, timeout, path or config knob
is added. Parallelism already existed in `Masc_tui_loader.read_pair`; this layer
moves dataset publication into each real child, without changing the read values.
The physical reader and progress boundaries added in #43720 remain.

## Request, workspace and data ownership

`Surface_read_order` now distinguishes logical source from actual dataset keys.
Board expands to posts and hearths; every other scoped family still has one key.
The public logical source enum, surface needs and pending-source displays retain
their meaning. Pending Board remains while either key has an owner. A typed key is
consumed once by its original opaque request owner. Failures settle ownership too;
they do not imply success or completion of another reader.

`take` returns only the remaining owned dataset keys. All terminal application
consumers, including independent Logs, use those keys. This prevents the terminal
copy from replacing an already delivered posts result while still admitting a
missing census. Navigation replaces both Board keys; unrelated datasets retain
their original owners. Duplicate results and cleanup cannot release another
request's slots. Data admission and collector lifetime are separate operations.

Each Board child calls the existing workspace-bound publication wrapper. The
same captured canonical base/root, GET precondition and server read receipt are
required. UI admission retains refresh ticket, immutable authority, server identity,
local workspace match and opaque dataset owner checks. A child outcome in the
diagnostic ledger alone never grants data authority. Cold initial acknowledgement,
final identity checks and non-Eio terminal-only application remain.

## Failure and interaction continuity

Existing list application preserves identity-based cursor/detail selection and
does not clear unrelated compose input. Posts failure retains the existing list
error policy; a failed census retains its last successful value. A successful early
dataset remains when its sibling fails or the collector is interrupted, subject
to the existing workspace withdrawal rules. Census may be the previous observation
while fresh posts are visible, as it could already be after census failure. Neither
two parallel reads nor the former pair produced an atomic backend snapshot.

Dataset payloads still use the bounded async mailbox. Progress uses #43720's
separate atomic inbox. Thus removing sibling completion as a dependency is not a
promise of instantaneous UI delivery, paint, action availability or useful work.
New logs distinguish logical source and concrete dataset under the same request
and start clock. An early failed sample is failure admission, not usable data.

## Evidence and remaining scope

Three protocol/ownership scenarios are authored, unexecuted: both Board arrival
orders across full/navigation collection with terminal remainder and no replay;
partial delivery followed by navigation supersession and old cleanup; and foreign
workspace, superseded refresh and authority withdrawal rejection. Three existing
dataset/decode scenarios adapt to the new dataset API. These inspect admission
decisions and retained owner state, not rendered text/layout/row order or PTY output.
They do not execute the private TUI producer/application loop or prove paint.
Five changed OCaml files passed parsing-only checks; exact-head source hashes and
diff/changelog metadata are recorded separately at publication. Parsing is not
typing, scenario execution, independent approval, merge, installation or runtime.

The full goal still includes preparation/discovery attribution and reuse,
cold-start input/readability/observability, Ask answer to original Task/useful work,
resource-owned ordinary/nested/dynamic/effectful Composition, held-job/shared
backend batches and matched Before/After retaining failed/cancelled/interrupted/
unfinished samples. No measured speedup or whole-goal completion is claimed here.
