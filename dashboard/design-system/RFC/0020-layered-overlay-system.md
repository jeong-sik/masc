# RFC 0020 — Layered Overlay System (LAYERS toggle)

- **Status**: Draft
- **Author**: design-system stewardship
- **Created**: 2026-04-30
- **Depends on**:
  - RFC 0015 (Tabs — multi-select activation variant)
  - RFC 0019 (Keeper Line Ownership — overlay data source)
  - RFC 0010 (Collaboration Cursor — keeper presence)
- **Consumes**: `--color-bg-elevated`, `--color-fg-secondary`, `--color-keeper-N-glow`, `--color-status-{ok,warn,err,info,stalled}`.
- **Blocks**: editor LAYERS toggle bar (Stage 5 IDE plane PR-3, mock; PR-5+ real overlays).

---

## 1. Motivation

The IDE mockup top of the editor pane carries a `LAYERS` toggle:

```
LAYERS  [Time] [Parallel] [Tools] [Approve] [Notes]   [EXPLODE]
```

Each toggle reveals a different overlay on top of the source view, scoped to the visible viewport:

| Layer    | Encodes                                           |
|----------|----------------------------------------------------|
| Time     | Recency gradient — how long ago each line was last touched, mapped to opacity. |
| Parallel | Lines currently being edited by ≥2 keepers in this run, highlighted with a striped gutter. |
| Tools    | Lines that triggered or were produced by an MCP tool call (refactor, search-replace, generator). |
| Approve  | Lines where any keeper logged an `APPROVE` thread (RFC 0021). |
| Notes    | Lines where any keeper logged a `NOTE` or `SUGGEST` thread. |
| EXPLODE  | Modal overlay that fans the file out into per-keeper "ghost copies" stacked vertically — read-only diff per keeper, useful for refactor review. |

The cockpit `IdePlane` prototype does not have this toggle; it is a mockup-introduced refinement (`design-system/audits/2026-04-30-ide-mockup-vs-v0.4-mapping.md` §2). Without an RFC each overlay is a one-off feature with its own state shape and toggle component, and the mockup's "compose 2–3 overlays at once" affordance is impossible.

This RFC defines the headless overlay system: a multi-select toggle primitive plus an overlay registration model so the editor can render any subset of registered layers without knowing which are active at compile time.

## 2. Non-Goals

- Per-overlay rendering. Each overlay's pixels are owned by its consumer (editor blame strip for `Time`, gutter striper for `Parallel`, etc.). This RFC defines registration and toggle plumbing only.
- Full-screen `EXPLODE` mode layout. Treated as one registered layer that the overlay host happens to render in a different DOM region; mode-specific layout is a follow-up RFC.
- Layer ordering / z-index. Default is registration order; consumer can sort.
- Persistence. v1 keeps active layers in URL query (`?layers=time,approve`) so deep links work; reload behavior is consumer-decided.

## 3. Public API (sketch)

```ts
// headless-core/layered-overlay.ts

export type LayerKind = 'time' | 'parallel' | 'tools' | 'approve' | 'notes' | 'explode'

export interface OverlayLayer {
  readonly kind: LayerKind
  readonly label: string
  readonly description: string
  readonly mutuallyExclusive?: boolean   // EXPLODE clears the rest when active
}

export interface LayeredOverlayController {
  readonly active: ReadonlySet<LayerKind>
  readonly toggle: (kind: LayerKind) => void
  readonly clear: () => void
  readonly isActive: (kind: LayerKind) => boolean
  readonly subscribe: (listener: (active: ReadonlySet<LayerKind>) => void) => () => void
}

export function createLayeredOverlay(layers: ReadonlyArray<OverlayLayer>): LayeredOverlayController
```

Adapter: `headless-preact/use-layered-overlay.ts` —
`signal<Set<LayerKind>>`-backed and returns the `active` signal directly.

## 4. Mutual exclusivity

`EXPLODE` is declared with `mutuallyExclusive: true`. When activated, all other layers are cleared. Activating any other layer while `EXPLODE` is active first clears `EXPLODE`. This keeps the `EXPLODE` modal from composing with the per-line overlays (which would visually conflict).

## 5. URL contract

The active set is persisted as a comma-separated query parameter:

```
#code/ide-shell?file=src/router.ts&layers=time,approve
```

Order in the query is canonicalized (alphabetical) so deep links don't churn. Unknown layer kinds are dropped.

## 6. Test plan

- Toggle test: `toggle('time')` flips presence of `'time'` in `active`; calling twice returns to the empty set.
- Mutual exclusivity test: activating `EXPLODE` after `time + approve` clears `time` and `approve`; activating `time` after `EXPLODE` clears `EXPLODE`.
- URL roundtrip test: `parse('time,bogus,approve') → Set('time','approve')`, `format(Set('approve','time')) === 'approve,time'`.
- Subscribe test: subscriber fires once per change with the *new* set, not the old one.

## 7. Migration & rollout

- Phase A (this RFC): land the headless controller + Preact adapter + tests. No editor wiring.
- Phase B (PR-3 of Phase 1): mount the toggle bar in the editor mock with all 6 layer kinds; overlays are no-ops.
- Phase C (PR-5+): wire each layer to its data source — `time`/`approve` to RFC 0019 ownership store, `tools` to keeper tool-event stream, etc.

## 8. Open questions

- Should the controller emit per-layer activation events (e.g., for analytics)? Defer until needed.
- Naming: "EXPLODE" reads dramatic — consider "Per-keeper view" if the metaphor doesn't survive contact with users.
