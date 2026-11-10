# Cleanup conditions at the deletion decision

The cleanup tool selected immutable candidates by age, absence of comments/votes
and title/author text. Its deletion request retained only the reader. A comment
append could already hold persistence while cleanup selected an old zero-count
view, then finish before deletion entered. The refreshed deletion stage would
include that new child without rechecking the original no-comments condition.
This is a source counterexample, not an executed incident or backend reproduction.

## Source and scope

- Base: `4a3f017e9880c8556c969d877cc835c9d38cb518`.
- Lower source: `b1a60af068bab0d53d83090a0cd6146e30d93468`.
- Case source: `35584707bedb70a9a2e6bb5b4257c8067503dffc`.
- Native Stack #51177: #51175 then #51176; destination main, integrate whole through top.

`manifest.json` retains the 15 changed source/changelog paths and their hashes.
Subsequent evidence-only commits do not change these inputs. The complete stack
was rebased with `gh stack rebase`; its main base did not move during that rebase.

One opaque per-request conditions value holds the fixed created-before cutoff,
comment/vote flags and normalized optional text patterns. Candidate display and
decision admission use the same pure predicate. The actual reader remains a
separate calling-boundary value.

The deletion owner reevaluates canonical post fields, last-ID-row comment
children and, when requested, canonical post-vote existence. Persisted parent
counters may lag their child ledgers. Both Up and Down retain votes; a comment
vote does not make a post vote exist. All vote rows are decoded, including those
after a matching target. Typed keys retain their target across repeated rows,
so the existence result agrees with physical last-row loading.

The readset retains Posts, Comments and only conditionally Votes through marker
recording. Paths, snapshots, IO and workspace observations are captured before
the filesystem callback. Every workspace is revalidated, and actual guard
refusals notify only the exact current source owner outside the worker. The
worker performs filesystem effects only.

A refused guard means no marker callback. A known marker retains its receipt
and Decision_recorded state before reserved cleanup propagates, without starting
model projection. Actual unknown marker effects retain before/intended evidence
and cannot be replayed by ordinary retry/flush. Once recorded, recovery follows
the original fixed IDs; it never reevaluates cleanup conditions. Marker schema,
ordinary author/operator deletion and sub-board policy scope are preserved.

## Evidence and limits

`validation.json` and `manifest.json` are unchanged copies of local captures.
Ten changed ML/MLI inputs have successful parse-only receipts with OCaml 5.5.1
(repository target 5.5.2): eight exact-source receipts reused and two new parses.
Parsing does not establish types, warning exhaustiveness, dependency resolution,
linking or functional behavior.

Whitespace checking passed. Static Dune-source inspection found 948 active
includes, no missing/duplicate include and the new suite included once. Dune
was not run. Two independent local readers inspected all ten original lower
paths and three original upper paths, then the actual final delta. Their exact
pins, reuse scopes and source-only verdicts are in `source-reviews.json`.

Both readers found a possible record-label type inference error in the new
cleanup parent argument. It was explicitly annotated `~(post : post)` before
publication and rereviewed. The author also checked the distinct Dispatch
initialization_error rather than using the Board-error helper in its fixture.
These are source corrections, not observed compiler failures or red/green runs.

Thirteen authored, unexecuted feature cases cover:

1. Actual comment, post-vote, title and author changes between two candidates
   through the first deletion's public SSE hook (four cases).
2. Comment/vote condition overrides (two cases). The comment override also casts
   a real Down comment vote while post no-votes remains enabled.
3. Canonical comment/vote protection while the persisted parent counter remains
   zero (two cases).
4. A filesystem-only foreign vote append at the Posts data-FD close, with the
   Votes condition required or omitted (two cases). The latter distinguishes a
   known decision from a later leaf CAS refusal.
5. Known marker plus outer cleanup failure, original decision recovery and a
   later accepted child outside its fixed IDs (one case).
6. Actual marker durability-unknown fault, retained evidence and no ordinary
   replay (one case).
7. The actual Direct reader and a stored recipient (one case).

The six Tool cases inspect durable/refused/unknown counts and restart retention;
they do not directly assert Tool verdict/effect_disposition. No type/warning/
build result, backend execution, CI, browser/live Board HTTP, install or deploy
evidence is supplied. Local reviews are not formal GitHub approval or integration.

## Remaining root scope

Root #26378 remains open for this unit's formal review/integration, usage-based
retirement of the unused public Posts source-only settlement family, and backend
failure/multiwriter/restart execution. No automatic TTL selection-change
counterexample was confirmed: default TTL is zero and the existing sweep holds
persistence and state through selection/model removal. No TTL/pin/activity
expansion is added. Original #26415 remains behind the active root.
