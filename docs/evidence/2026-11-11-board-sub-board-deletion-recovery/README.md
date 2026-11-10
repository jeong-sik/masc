# Sub-board deletion and canonical comment admission

This records an ordinary source-review candidate for #26378, not root-issue completion.
The previous admission bundle remains an unchanged historical record of its known
hearth-unlink P2. This new candidate fixes that source defect and the findings from
subsequent independent review.

## Captured source

- Base: `da220af2151d63ad50166edd251ac741d3333099`.
- Lower production source: `4d730fd9c0f9a90e6c670da1c683fa14eaddc201`.
- Upper test source: `542d8d8ee44b73ce9c4e02f1f013025e5ac1a4a7`.
- Native Stack #51148, ordered #51146 then #51147; merge scope is the whole stack.

The evidence-only commit containing this directory changes none of the 59 captured
OCaml inputs or four captured frontend inputs. `validation.json` contains their
SHA-256 values and the commands actually executed.

## Resulting behavior and review

Sub-board deletion records the original board ID, slug and fixed post IDs while
holding canonical Posts and Policy guards. It durably unlinks those posts and
removes the board policy through the existing owned deletion recovery path. A
shadowed board does not unlink the active winner's posts; removing the active
winner preserves physical row order and rebuilds the remaining policy index.

Unknown writes remain owned by the deletion operation, even after a source-only
readability settlement. Restart recovery uses the fixed identity set and retains
later foreign posts or a replacement board. Typed capture failure keeps the dirty
obligations and actual model-applied progress. Actual inner Policy guard refusal
notifies its exact source owner; an outer guard refusal does not revoke Policy.

The HTTP and tool boundaries distinguish durable completion, a pending decision,
and model application whose persistence is pending. Dashboard decoding preserves
that distinction. Its pending notice keeps the original board identity after a
refresh removes the list row, and pending operations do not repeat automatically.

Two independent local agents found no additional confirmed P0-P2 at the source
pins above after their findings were addressed. Read `local-source-reviews.json`
for the inspected scope. This is source review, not a formal GitHub approval.

## Executed checks and limits

- 59 changed ML/MLI files parsed successfully with OCaml 5.5.1. The repository
  targets 5.5.2. This does not establish typing or warning correctness.
- The two named frontend files passed 105 Vitest cases. Dashboard `tsc --noEmit`
  and ESLint for the four named source/test files returned zero. The exact final
  frontend hashes still match; no dependency installation was performed.
- Earlier frontend failures are retained. The original component incorrectly
  showed success for pending deletion; the first fix then lost notice identity or
  the whole notice when the row disappeared. A later test selector also needed
  the accessible name to distinguish pending status from the empty-state status.
  These historical runs have different test/source versions, not a claim of one
  identical byte-for-byte red/green experiment.
- Backend cases: comment admission 10, retained deletion recovery 16, filesystem
  guards 5 and sub-board deletion recovery 9: **40 authored, zero executed**.
  Dune include counts are a source census only; Dune was not run.
- No new Chromium screenshot for the sub-board pending flow is included. Earlier
  vote/reaction screenshots do not prove this new flow.
- No backend typing/build/runtime, live HTTP, CI, installation, deployment or
  full #26378 completion is claimed. Source review and integration are separate.

`frontend-results.json` holds command/exit receipts. The four frontend text logs
are documented derivatives with one host-path substitution; original and retained
hashes are in `manifest.json`. The parse validation is copied without editing.

## Remaining root scope

#26378 remains open for actual post-creation policy readsets, existing-parent
existence/readership dependencies for votes and reactions, cleanup selection
changes, usage-based disposition of source-only Posts settlement, and actual
backend failure/multiwriter/restart evidence. #26415 remains the next original
issue after #26378 reaches a supported disposition.
