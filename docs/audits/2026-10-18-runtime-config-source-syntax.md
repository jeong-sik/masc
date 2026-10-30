# Runtime raw Config: exact syntax sharing and effectful preparation

Source baseline: `322226ba37412faeb3a754dc05a859580bff65b9` (#43671).

## As-Is / To-Be

| Boundary | Baseline | This layer |
| --- | --- | --- |
| Raw source syntax for Keeper/Runtime | Each reader parses independently | One frozen syntax result reused only when both exact inputs match |
| Syntax parse calls when normalized/original inputs match, including normal LF source | Two | One |
| Syntax inputs differ after Keeper CRLF/trailing-CR normalization | Two reader-specific inputs | Still two; both established string/error semantics preserved |
| Source bytes and revision | Original observation/commit source | Same original bytes and source revision; no normalized source replaces the editor/CAS input |
| Validation | Keeper projection/validation and Runtime interpretation separate | Same separate results, with explicit scalar-root refusals at public parsed-document APIs |
| Raw response JSON preparation | Runs on HTTP caller fiber | Existing shared IO submission prepares it; auth and response writing remain on caller |
| Client snapshot preparation | Classified as environment-free shared CPU callback | Corrected to shared IO because Runtime credential home expansion reads environment |
| Diagnostics | No syntax-input reuse classification | Shared/reader-specific input mode in debug diagnostics and a runtime-config-response event scope |

These are source-derived call and boundary changes, not measured speedup. No
network round trip is removed. Source observation file loading, JSON serialization,
compression, HTTP response writing and existing commit/skill/audit effects remain
separate work. Shared-pool absent/non-Eio/already-worker inline policy remains.
The response scope includes pool wait, interpretation and IO observations; it is
not a pure CPU or painted-frame duration.

## Preserve the actual inputs

Keeper's existing parser normalizes physical CRLF/trailing CR before Otoml;
Runtime's parser uses original source bytes. Normalizing parsed strings would
also rewrite intentional escaped carriage-return/newline values, so it is not a
valid substitute. The new preparation retains those distinct frozen inputs and
compares complete bytes. Identical syntax input shares one AST or syntax error;
different input is parsed by each reader's established policy. No substring or
path heuristic decides reuse.

Keeper flattening preserves canonical quoted/dotted paths and returns its own
result. Runtime interprets the AST with its existing semantic validation and
home expansion. A semantic failure does not suppress the other projection, turn
into an empty successful config or erase original source. Malformed syntax stays
an error for each reader. The raw response's validation, account group/email,
application and commit receipt fields retain their existing wire shape.

The preparer retains original source text but does not claim to be pure: Runtime
can expand a file credential using the process environment. Response preparation
also observes current Keeper overlay/environment and account files. It therefore
uses the existing IO job boundary. Authentication, request/response handles,
commit application, write auditing and existing cancellation protection are not
moved into that job. Entered worker failures are not retried by new code; existing
pool cancellation/cleanup policy remains authoritative. No cache, timer, cap or
new permission/config knob is introduced.

## Correct the client boundary too

The preceding Config snapshot layer called the same Runtime parser indirectly
through its model-table projection, while its interface/guide called the whole
callback environment-free. That classification was wrong for home expansion.
This layer corrects the client loader to shared IO and updates its interface,
current guide/Skill and historical audit correction. Immutable source sharing,
workspace/read authority, read generation, model entry intent, raw draft owners
and unknown-save revalidation are retained. No new response or UI contract is
introduced.

## Evidence and remaining goal

Five feature scenarios are authored and **unexecuted**: shared LF input preserves
both reader results and quoted model IDs; physical CRLF plus intentional escaped
CRLF preserves the two reader policies; Runtime semantic failure keeps repairable
Keeper/source data; malformed syntax and scalar-root refusal; explicit HOME-based
credential expansion remains an environment effect. They inspect typed results,
source bytes and validation provenance. No TUI wording/layout/row-order/snapshot/
PTY or implementation-pattern check is added.

Only parser-only source checks, committed diff hygiene and changelog validation
run. Typing, feature execution, independent current-head approval, CI, native/model
runs, install/restart, runtime, paint and timing are unverified. No live product
login/config/prompt file or runtime was read or modified during this coding unit.

The full preparation/first-usable-input/readability/visibility/observability,
Ask-to-original-Task-to-useful-work, resource-owned ordinary/nested/dynamic/
effectful Composition, held-job/shared-backend and matched Before/After objective
remains open. Future comparisons must retain failed, cancelled, interrupted and
unfinished samples. This layer does not establish completion or production
readiness.

## Subsequent model-projection layer

The following server-owned model-projection layer removes Runtime source parsing
from Config snapshot preparation altogether. That new pure client callback can
use the shared CPU boundary; this historical layer correctly required IO while
it still interpreted Runtime source. Source-only form parsing and server Runtime
interpretation retain their environment effects. See
[the model-projection audit](2026-10-18-runtime-config-model-projection.md).
