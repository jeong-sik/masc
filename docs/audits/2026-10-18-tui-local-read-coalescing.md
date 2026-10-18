# Local read demand, creation coverage and cache source identity

Source baseline: `9bb7fb3f72014c0c1dcb0e08b313790253470333` (#43626 merge).
This is source implementation; timing and installed behavior remain unmeasured.

## Before / after

| Boundary | Before | After |
| --- | --- | --- |
| Refresh during a local read | Supersede ticket, cancel and start another worker | Keep active read and merge later demand into one follow-up |
| Completed read while newer demand exists | Replaced reads are discarded | Current read may publish an observation, but later demand remains pending |
| Read failure with queued refresh demand | Each request creates another worker immediately | Preserve the failure and start the accumulated follow-up after settlement |
| Creation during an earlier read | Immediate supersession protected the new chat | Each Keeper requires a read covering its creation demand; earlier absence cannot close its chat |
| Multiple pending creations | One name-valued wait slot | Separate Keeper-owned demand barriers |
| Metadata cache | Keeper name + file stat | Resolved metadata file path + existing stat checks |
| Archive cache | mtime + size | Actual archive path + mtime + size |

For a finite trace of one active read and three refresh requests while it remains
active, the controller's dispatch shape changes from four launches plus three
cancellation requests to two launches with no refresh cancellation. These are
source transition counts and authored scenario expectations, not executed native
counts or measured speedup. Metadata and Work still have independent controllers,
cache mutexes and payload types; they can run independently.

## Ownership and freshness contract

The previous source layer treated every explicit refresh as a new active owner.
This layer changes that policy: the same active owner remains until settlement;
additional actions request a later observation instead of replacing the active
read. Old/duplicate results still cannot settle a genuinely newer request.
Source/workspace/path admission checks remain. This is a state-machine change;
the earlier parse-only verdict is not behavioral proof of either policy.

A source-demand revision is an internal ordering of accepted read demands. It
is not a filesystem storage revision, timer, cumulative turn/token budget or
model-progress signal. Completing a read records its captured demand coverage;
it never clears demand that arrived afterwards. Success and failure both reach
the follow-up dispatcher. Withdrawal/clear retires active tickets, coverage,
pending demand and cancellation ownership, preserving monotonic ticket identity.

Every created Keeper captures its own required demand revision after its creation
refresh is requested. Presence in an earlier observation alone cannot authorize
that new input. Until a covering metadata read arrives, an earlier absent row
cannot close the explicit chat or drop its draft. Concurrent creations retain
separate barriers; later creates cannot overwrite earlier waits. Work cannot
provide metadata coverage or replay input/Task wake. Original Task, queue and
request identities continue through the existing metadata-admission handler.

A worker releases its cancellation slot after I/O returns and before mailbox
delivery, so a normal follow-up does not count as cancellation of already-read
work. Workspace cancellation still owns workers blocked on delivery. The common
executor owns actual worker cancellation/cleanup. No deadline or queue cap added.

Cache keys identify the read's actual file path. The metadata inventory prunes
entries outside the current observed paths; it is not a cross-workspace cache
fleet. Archive storage holds one path-stamped completed reading. Existing stat
invalidation semantics are retained; this does not prove arbitrary rewrites that
preserve every stat field are detectable.

## Evidence and continuation

Changed OCaml files receive parser-only checks. Three lifecycle state cases are
rewritten: refresh bursts/current observation/follow-up, creation input coverage
with both earlier presence and absence, and confirmed deletion. Three new cases
are authored but unexecuted: failure/follow-up plus withdrawal, concurrent creation
barriers, and physical archive files with equal size/mtime and different contents.
These assert requests, persisted state or resource ownership; no wording/layout
or PTY tests are added. Metadata path-key change is source-inspected; there is no
executed metadata/store comparison in this unit.

No typing, scenario execution, real executor-load/cancellation run, CI,
installation, runtime frame or painted UI proof. Pool/cache/mailbox contention,
source freshness under production load and measured latency remain unverified.
A future matched comparison must keep failed/cancelled/unfinished samples and
separate first input, source observation, full refresh, paint and useful tool
commit. Fewer launches do not establish lower end-to-end latency.

Continue first-usable-input independence, removal of remaining synchronous
creation HTTP/detail-log paths, exact Task/Skill/tool preparation reuse and clearer
descriptions, resource-owned nested/dynamic/effectful Composition, held-job shared
backend batching, Ask-to-original-Task useful-work continuity and matched
Before/After with runtime/UI evidence. The full objective remains active.
