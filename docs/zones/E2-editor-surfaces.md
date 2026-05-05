# Zone E2 — E2 Editor Surfaces

**Phase**: phase3
**Source spec**: `dashboard/design-system/preview/scope-phase3.html` (anchor `#e2`)
**Status**: re-audited 2026-05-05 — initial audit was too pessimistic

## Re-Audit (2026-05-05, second pass)

The first audit pass (`rg -n attribution.gutter|3-way merge|blame.gutter`)
returned mostly false negatives because the actual implementation uses
CodeMirror state-field naming (`blameMarkerField`, `setOwnership`)
instead of the spec's freeform names. A drill-through of
`ide-editor-extensions.ts` shows substantial existing coverage.

## Feature Checklist (corrected)

- [x] **blame-gutter** — `blameGutterExt()` in `ide-editor-extensions.ts:130-143`
      registers a CodeMirror gutter that consumes `blameMarkerField`
      markers. Activated by `view='blame'` (`ide-editor.ts:101`).
- [x] **attribution-gutter** — Functionally equivalent to the blame gutter
      via per-line keeper ownership data. `pushOwnership()` dispatches
      `setOwnership` effects, blame markers are derived from ownership
      map (`blameMarkerField`'s update handler at line 107). Wired into
      `ide-editor.ts:159, 191` from `keeper-line-ownership-store.ts`.
- [x] **split-2-pane** — `view='split-diff'` (`ide-editor.ts:94`).
- [x] **unified diff** — `view='unified'` (`ide-editor.ts:27`).
- [ ] **3-way merge resolver** — NOT implemented. Scope spec wants 3-pane
      (base / ours / theirs / merged) — the existing split-diff is 2-pane
      only. Needs new component `IdeMergeResolver` + git API for
      conflict markers.
- [ ] **inline review** — `anchored-thread-rail-store.ts` exists with
      tests, but NOT mounted into the editor surface. Wiring needed:
      pass thread store into `IdeEditor`, render pinned threads at
      anchor lines via CodeMirror widget decorations.

## Existing References

- `dashboard/src/components/ide/ide-editor.ts` — main editor (4-view switch)
- `dashboard/src/components/ide/ide-editor-extensions.ts` — CodeMirror
  bundle (blame gutter, ownership state, language support)
- `dashboard/src/components/ide/keeper-line-ownership-store.ts` — line
  attribution data source
- `dashboard/src/components/ide/anchored-thread-rail-store.ts` — inline
  review thread store (NOT mounted)
- `dashboard/src/components/ide/ide-diff-view.ts` — split-diff renderer

## Backend Dependencies

- 3-way merge resolver:
  - `GET /api/v1/git/conflict?path={path}&branch={branch}` (NEW) —
    returns `{base, ours, theirs}` text + conflict markers.
  - Extension of `git_graph.ts` schema or new `git/conflict` schema.
- Inline review:
  - Reads existing review-thread API (already feeding
    `anchored-thread-rail-store`); UI mount only.

## Implementation Plan (revised)

1. **Inline review mount** (no backend change) — pass
   `anchored-thread-rail-store` into `IdeEditor`, register CodeMirror
   widget decorations at anchor lines. Smallest visible win.
2. **3-way merge resolver** (RFC required) — design the conflict-fetch
   API and conflict marker rendering. Tracks E2 + E4 (Git Graph)
   collaboration since merge state surfaces from worktree status.

## Related

- Spec source: `dashboard/design-system/preview/scope-phase3.html`
- Cockpit entrypoint aliases: `dashboard/src/cockpit-entrypoints.ts`
- Audit ledger: this commit corrects the 2026-05-05 first-pass audit
