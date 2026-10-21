# Retained original verification selection

| Boundary | As-Is | To-Be in source |
|---|---|---|
| Failed Task refresh after a submitted Task was observed | Task value stays Stale, but verification candidates accept Ready only | Previously observed exact submission remains available for explicit read |
| Failed history refresh after stored submissions were observed | Stored prefix stays Stale, but its IDs disappear from candidates | Retained original prefix still supplies its known submission IDs |
| Selection provenance | Only Task/submission identity is pinned | Immutable source and selection-time observation state pinned alongside identity |
| Pending refresh/retry | Retained value can be shown without a distinct selected basis | Observed/refreshing/retained/retrying are distinct typed selection states |
| Later Evidence refresh | Same submission identity | Same exact identity and original basis, independent of later source suspension |
| Unknown source | No IDs | Same: no value means no invented submission |

The selected source audit found a real UI continuity defect while tracing
original Ask to exact Task/history/evidence. The fetched model preserves values
on failed refresh, but verification_candidates discarded every Stale value.
The inspector could show the original submitted Task/history while refusing to
open its already-known retained verification. The source no longer requires a
successful replacement read just to inspect that original submitted evidence.

Each private evidence anchor contains the existing Task/submission identity and
an immutable basis. The basis records original Task versus original stored
history, plus observed, refreshing, retained with typed error, or retrying with
typed prior error at selection. Values come from the existing same-original
source views; absent/loading/failed-without-value sources supply nothing.
Original Task-first/history order and exact submission-id deduplication remain.
The basis is captured before selection suspends other source requests, preserving
the original prior failure rather than a later Interrupted reason.

The Evidence document shows that selection basis beside its own independent
pending/failed/ready/stale reading. No selection does not imply no stored proof.
Selection-time source state does not claim current Task status, current backlog
membership, verification approval, useful work or Goal completion. A fresh read
of a retained submission does not make its original selection source fresh.
Evidence refresh keeps the same original anchor; explicit next selection makes
a new one. Existing exact response Task/submission checks, request generation,
original Ask/creation binding, workspace/read scope and late-result rejection
remain. Anchor equality uses identity; current ticket/binding still owns reply
admission, and selection metadata cannot grant effects or change reply identity.
The creation-root ready-receipt eligibility rule is unchanged.

No new endpoint, backend, process, retry, cache, timer, loop or numeric gate.
Previously blocked explicit evidence selection can now issue its ordinary exact
read, adding the intended request/decode/format work. Candidate pairs/basis
records and two document sections add allocation/formatting at source transitions;
error strings remain immutable references. The same anchor is retained across
Evidence refresh, not re-derived from replacement state or formatted each frame.
This source comparison is not an observed Loading/input/paint latency delta.

One existing actual resource case is extended, unexecuted. A real completed Task
and actual paginated stored history are read. A well-formed reply for another
actual Task is refused under the original request; the retained original history
must still open its exact stored submission and expose the original failure basis.
A new unexecuted compound case submits the actual original Task before a verdict,
rejects an actual foreign Task response, preserves its original submitted ID,
selects evidence after failure and during a pending retry, and reads the real
retained proof. Retired Task/evidence tickets must not replace that selection;
Evidence refresh keeps its exact basis. Canonical Task records and unrelated
operator input remain unchanged by the inspection reads. This is not HTTP/Main/
paint proof, and no claim is made about other resource files from Task-list checks.
No helper invocation-count, wording/layout/snapshot or PTY tests are added.

Validation: OCaml parsing only for three files, interface first, and source/diff
inspection. No typecheck/build/test/consumer/import/CLI/report/CI/native/model/
controller/audio/PTY execution, install/restart/live write, agents, approval or
merge. All six original axes and matched actual Before/After remain open. The
current offline follow-up report still treats source snapshots as opaque and
does not prove useful original Task work; this leaf repairs retained proof access
and its provenance, without substituting read completion for that broader goal.
