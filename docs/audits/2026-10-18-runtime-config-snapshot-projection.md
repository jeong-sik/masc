# Runtime Config: immutable source/model projection before UI admission

Source baseline: `96145753e8523d442b1f745e42f017726ebb41ae` (#43666).

## As-Is / To-Be

| Boundary | Baseline | This layer |
| --- | --- | --- |
| Raw response interpretation | Decode on the asynchronous request fiber | One existing shared CPU submission decodes and projects the immutable response |
| Whole-source lex/sanitization | Full source processed inside UI result admission | Prepared before enqueue; UI receives existing immutable tokens |
| Model table parsing | TOML parsed inside UI admission using that reading's groups | Prepared alongside source with the same exact groups and source |
| Heavy whole-source passes in ordinary successful Config result admission | One lex plus one model parse | Zero for these two projections |
| Refresh with unchanged retained draft | Draft lexed again; open comparison may lex current source again | Existing draft projection and matching source snapshot reused, including an equal-text successor with distinct editing ownership |
| Model/group interpretation failure | Source retained and model error visible | Same independent result; no fabricated empty model catalogue |
| Email observation failure | Separate account-email reading | Remains separate in the same source reading |
| Request ownership | Workspace/read authority, generation, requested model intent, queued follow-up | Same admission boundaries; no worker state mutation |
| Observation | Generic mailbox wait plus read state | Start, prepared-result and UI admission-decision clocks share generation/start identity |

These are source-derived dependency and immutable-sharing changes. Network work
is unchanged. No measured latency, CPU speedup or reduction in total read work is
claimed. A superseded or queued-follow-up read can finish pure preparation and
still be discarded by the existing policy. Existing absent-pool/non-Eio/already-
worker inline policy remains. New edits and non-snapshot changes can still lex
source on the UI path; cursor/jump scans, application state updates and rendering
remain separate work. The external editor is still its own terminal interaction.

## Data and effects

A private immutable snapshot stores one original decoded reading, sanitized
whole-source tokens and a model result. Model parsing uses only that reading's
source and server-owned account groups. Metadata/path/revision and account email
observations travel with it. A model or group error does not hide the source or
turn into a successful empty list. Exceptional decoding/projection failures
propagate through the existing request error boundary; no caller-side retry or
empty fallback is introduced.

The CPU function reads no UI state, credentials, environment, filesystem,
palette or request ownership. Token kinds remain palette-independent. Only the
UI thread mutates state, selects a model, retains a source observation or updates
a draft. Specialized document-only activity readers keep their existing read and
do not perform unused model/lex projections.

Snapshot token reuse requires exact path and full source bytes. Reusing existing
draft tokens additionally belongs to the original workspace/path cache entry.
Neither sharing path grants read or mutation authority. Equal text can share
immutable tokens while its later editing owner stays distinct. Observation
updates still preserve the input/basis owners, exact draft, original read
generation, comparison intent and uncertainty revalidation barrier. A projection
cannot choose a newer revision or bypass an unresolved operation.

The async completion retains the original read generation and captured model
entry intent, adding request-start and prepared-result clocks. UI disposition
records admitted, superseded or follow-up decisions with those clocks. They are
not commit, frame-paint, actual key-latency or useful-task-work observations. The
shared runtime event scope includes pool admission and caller scheduling; it is
not a pure CPU duration. Timing records include no source text or form fields.

## Evidence and remaining goal

Three feature/state scenarios are authored and **unexecuted**: source preserved
through unavailable group/model interpretation and malformed model source;
exact bindings/group membership with independent email failure and mismatched
cache-key refusal; immutable draft/current projection sharing while retaining
input/basis/read-generation and equal-text successor ownership. No wording,
layout, row-order, snapshot-output or PTY test is added.

Parser-only source checks, diff hygiene and changelog validation are the only
executed checks. Types, feature execution, current-head independent approval,
CI, native/model runs, installation/restart, runtime, paint and measured speed
remain unverified. No live prompt or runtime configuration was written.

The full preparation/first-usable-input/readability/visibility/observability,
Ask-to-original-Task-to-useful-work, resource-owned ordinary/nested/dynamic/
effectful Composition, held-job/shared-backend and matched Before/After goal
remains open. Eventual comparisons must retain failed, cancelled, interrupted
and unfinished samples. This layer does not establish goal completion.

## Classification correction in the subsequent source-preparation layer

Following the Runtime parser revealed that file credentials with a leading ~/
can call Env_config_core.expand_home_prefix. The model-table projection therefore
was not an environment-free CPU callback as described above at this historical
head. The follow-up source-preparation layer moves client snapshot preparation
to the shared IO boundary and corrects its interface, guide and Skill contract.
Immutable sharing and source/model admission stay the same; this is not executed
runtime evidence or a measured regression/speedup verdict.
