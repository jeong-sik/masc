# C1 · Board Zone — Phase 2 reconciliation audit (2026-04-29)

Follow-up to `2026-04-29-phase2-implementation-gap.md`. The original audit
classified C1 Board Zone as a "zero-production-surface" zone in the
"15 zones with zero production surface" list. That classification turns
out to be incorrect — `dashboard/src/components/memory.ts` already
renders the board surface, just under a different label set. This audit
documents the actual gap so future Phase F work can target real misses.

## Methodology

1. Read the C1 preview spec (`design-system/preview/cb-group-e.jsx:7-180`)
   and capture the three variants verbatim.
2. Read the production board surface (`dashboard/src/components/memory.ts`)
   plus its state module (`memory-state.ts`) and traced the data path
   from `boardPosts` signal → `Memory()` → `CategorySection` → `BoardPostCard`.
3. Compare per-variant. Record vocabulary mismatch separately from
   functional miss — vocabulary differences are not gaps.

`rg` was used for symbol search. No production code was modified by
this audit; it is intentionally scoped as analysis-only.

## Summary

| C1 Variant | Production equivalent | Coverage | Gap kind |
|-----------|----------------------|----------|----------|
| C1-A Feed (hearth-grouped) | `Memory` + `CategorySection` (`memory.ts:192`) | **full** | vocabulary only — spec "hearth" = production "category" |
| C1-B Single post + thread | `PostDetail` + `BoardCommentThread` (`memory.ts:498`) | **full** | none — comment tree, vote column, markdown preview all present |
| C1-C Hot vs automation toggle | `SortBar` + category filter chips (`memory.ts:241`) | **partial — toggle UI different shape** | UX shape: spec uses 2-tab toggle, production uses sort-modes + per-category hide chips |

**Conclusion**: Phase F reconciliation work for C1 is **vocabulary-only**, not implementation. The original audit's "zero production surface" classification was wrong because it searched for component names matching the spec ("BoardFeed" / "BoardThread") rather than the actual production naming ("Memory" / "PostDetail"). All three spec variants have a working production equivalent.

The one surface where a small UX-shape PR could move things closer to spec is **C1-C** — adding a 2-tab "Hot vs automation" toggle as an alternate filter chip set on top of `SortBar`. Optional and small; not blocking.

## Detail — C1-A Feed (hearth-grouped)

**Spec** (`cb-group-e.jsx:7-89`):
- Posts grouped by `hearth` field (e.g., `merge-blockers`, `infra`, `goals`)
- Each group has a header + post list
- Post row shows `author`, `title`, `tags[]`, `votes`, `comment_count`

**Production** (`memory.ts:Memory` + `CategorySection`):
- Posts grouped by `category` (`ContentCategory` from `memory-state.ts`):
  enumerated set with metadata + icon + label + color
- Each group has a header + paginated post list with "show more"
- Post row (`BoardPostCard`) shows author + identity + title + tags +
  vote column + comment count + `created_at` + `flair` + `hearth` (yes,
  the field exists; production renders it as a small pill, not the
  grouping key)

**Vocabulary difference, not a gap**: spec's "hearth" is grouping; production puts grouping at `category` and treats `hearth` as a tag-like display field. Both achieve the same operator outcome ("scan posts by topical bucket").

## Detail — C1-B Single post + thread

**Spec** (`cb-group-e.jsx:89-127`):
- Header card: title + author + body + vote column
- Threaded comments with author + body + nesting

**Production** (`PostDetail` + `BoardCommentThread`):
- Header card: title + author + identity + body + tags + vote column +
  flair + hearth pill
- Threaded comments with `parent_id` nesting (`BoardCommentThread:498`)
- Markdown preview via `BoardMarkdownPreview:558`
- Edit / delete actions (production has more affordances than spec)

Production exceeds spec.

## Detail — C1-C Hot vs automation toggle

**Spec** (`cb-group-e.jsx:127-180`):
- 2-tab toggle: "Hot" | "Automation"
- Hot tab = direct posts only (no automation)
- Automation tab = automation-only posts

**Production** (`SortBar`):
- Sort mode buttons (recent / hot / popular — `SORT_MODES`)
- Per-category hide/show chips — operator can hide `automation` /
  `system` categories independently
- Net effect: hiding `automation` + `system` = "Hot" view; showing only
  `automation` = "Automation" view

**UX shape difference**. Production gives more granular control (per-category
chips); spec gives a 2-tab simplification. Both accomplish the same
filter intent.

## Recommendation

- **No reconciliation PR needed for C1-A or C1-B.** Functionally complete.
- **Optional** for C1-C: add a 2-tab "Hot / Automation" preset on top of
  the existing per-category chips. Small, ~50 LOC. Not critical because
  the underlying filter mechanism already exists.
- **Update the original audit's "zero production surface" list** —
  C1 Board Zone should be moved to the "partial coverage" bucket, not
  the "missing" bucket. (Cleanup PR can do this in passing or be
  bundled with the optional C1-C UX-shape PR.)

## Evidence — file references

Preview:
- `dashboard/design-system/preview/cb-group-e.jsx:7-180` — C1 spec block
- `dashboard/design-system/preview/cb-group-e.jsx:47-89` — C1-A Feed
- `dashboard/design-system/preview/cb-group-e.jsx:89-127` — C1-B Thread
- `dashboard/design-system/preview/cb-group-e.jsx:127-180` — C1-C Hot/Automation

Production:
- `dashboard/src/components/memory.ts:487` — `Memory` (board surface entrypoint)
- `dashboard/src/components/memory.ts:192` — `CategorySection` (group renderer)
- `dashboard/src/components/memory.ts:374` — `BoardPostCard` (post row)
- `dashboard/src/components/memory.ts:498` — `BoardCommentThread`
- `dashboard/src/components/memory.ts:558` — `BoardMarkdownPreview`
- `dashboard/src/components/memory.ts:241` — `SortBar`
- `dashboard/src/components/memory-state.ts` — `ContentCategory`, `boardSortMode`,
  `boardHiddenCategories`, `automationVisibleLimit`, `systemVisibleLimit`
- `dashboard/src/types/core.ts:121-145` — `BoardPost`, `BoardComment`
