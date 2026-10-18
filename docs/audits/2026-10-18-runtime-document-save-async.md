# Runtime source document: asynchronous save and exact draft ownership

Source baseline: `34103711a071a1b429a7d803b26782e20e316f41` (#43665).

## As-Is / To-Be

| Boundary | Baseline | This layer |
| --- | --- | --- |
| Config runtime.toml editor return / S | Inline workspace check, preview, identity recheck and commit | Retain exact source session and join the existing owned asynchronous save |
| Successful-path logical HTTP waits inside that key-handler chain | Four | Zero |
| Successful-path logical HTTP calls | Four | Four; document preparation does not add a raw-file GET or another health check |
| Pending sharing | Input cannot process a second submit during the inline chain | One shared pending write gate covers source documents and both structured forms |
| Refresh while saving | Inline flow prevents ordinary input/refresh continuity | Same draft ownership survives observations and error annotations |
| Later edit, adoption or replacement | Inline completion updates the retained draft directly | New editing ownership protects even an equal-text successor from late deletion/replacement |
| Unknown commit / durability | Error text and retained source; retry still available | Typed operation barrier requires a later-started source read and explicit basis choice |
| Comparison already held or request already running at uncertainty | No causal revalidation boundary | Comparison retired, read-generation floor retained; older/unstamped reads cannot revalidate |
| Another basis selected before the uncertain receipt, or cached reopen after discard | No retry provenance boundary | A new basis must itself come from a read started after the uncertain receipt's admission floor |
| Navigation / workspace withdrawal | Inline chain owns the visible source implicitly | Receipt and exact source belong to original workspace; only its draft owner can complete |

Counts describe source dependencies on the successful path. They are not a
measured latency improvement. External editor time and source lexing/admission
remain distinct work; this does not make the external editor asynchronous. The
existing model/account path retains its six-call dependency chain, with no new
round-trip reduction claim. Existing specialized editors/lane/other mutation
flows remain separate follow-up paths.

## Ownership and revalidation

Source sessions carry an editing owner and a chosen-basis owner. Observations,
failure annotations and uncertainty preserve both and the exact text. Editing
starts another editing owner while keeping the chosen basis. Explicit adoption,
replacement and a fresh document create new owners. Operation receipts can clear
only their original editing intent, independently of read authority and current
navigation. They cannot complete another workspace's draft or a later editing
intent, even when source text is equal. Original submitted/prepared source stays
in its session operation record; this is not a durable restart journal.

Uncertainty clears comparison data on the submitted basis, including a later
text edit on that basis, without replacing the later input. The existing TUI
source-read generation supplies a causal floor. A read already started when the
uncertain result is admitted cannot clear it. The last successfully observed
source generation is stored with its reading; opening a document does not use
the newest in-flight generation as provenance. Explicitly selecting a new basis
carries that reading's generation. A different basis chosen too early, or an
unstamped/cached reading, cannot bypass the unresolved operation's retry barrier.
The existing force-read follow-up supplies a later read when another is in
flight. No timer, arbitrary work cap, automatic write retry or separate raw-save
queue is added.

Preview, exact path/revision CAS and workspace checks reuse the same commit
helper as structured forms. Possible-dispatch cancellation stays unconfirmed;
pre-dispatch interruption remains not-sent. File commit, durability and runtime
application remain separate receipt facts. X discards local intent and retires
its recovery notice; it does not roll back or claim to cancel a server write.

## Evidence and remaining goal

Four feature/state scenarios are authored and **unexecuted**: frozen source and
revision with duplicate/cross-form sharing and refresh-preserved ownership;
equal-text successor plus foreign-workspace protection after authority change;
unknown commit revalidation; acknowledged commit with unknown durability. The
uncertainty scenarios include later text preservation, old/unstamped read
refusal, premature new-basis refusal, and explicit adoption after a later read.
No wording, layout, row-order, snapshot or PTY test is introduced.

Only parser-only source checks, diff hygiene and changelog validation run.
Typing, feature execution, independent current-head approval, CI, native/model
runs, install/restart, runtime behavior, paint and measured responsiveness remain
unverified. No live configuration or prompt writes occur in this coding unit.

The full preparation/first-usable-input/readability/visibility/observability,
Ask-to-original-Task-to-useful-work, ordinary/nested/dynamic/effectful resource-
owned Composition, held-job/shared-backend and matched Before/After goal remains
open. Failed/interrupted/cancelled/unfinished samples must remain in eventual
matched measurement. This document-save layer is implementation progress, not a
completion or production-readiness verdict.
