# RFC 0019 — Keeper Line Ownership

- **Status**: Draft
- **Author**: design-system stewardship
- **Created**: 2026-04-30
- **Depends on**:
  - RFC 0010 (Collaboration Cursor — keeper identity primitive)
  - RFC 0001 (Headless Foundation — `IdGenerator`)
- **Consumes**: `--color-keeper-N-glow` (semantic), `--k-N` (raw fallback) for blame strip color encoding.
- **Blocks**: editor `blame-by-keeper` overlay (Stage 5 IDE plane PR-5), audit-aware diff strip, refactor attribution surfaces.

---

## 1. Motivation

The IDE mockup (`design-system/audits/2026-04-30-ide-mockup-vs-v0.4-mapping.md` §2) shows each editor line carrying a left-rail keeper ownership label (`nick0cave`, `sangsu`, `masc-improver`) and a colored dot for change. The cockpit `IdePlane` prototype (`ui_kits/cockpit/Planes.jsx:155`) names the same surface `IxEditAttrib` ("attribution") but does not yet specify a data model.

Today the dashboard knows about keeper events through `keeper-state.ts` and `sse-store.ts`, but no store is line-indexed. Computing ownership at the editor surface (file path + line) requires:

1. A canonical event shape so multiple producers (server, future webhook ingest, replay) can populate the same store.
2. An accumulator that derives `Map<lineNum, KeeperId[]>` from a stream without re-reading the whole event history per render.
3. A stable mapping `KeeperId → keeper hue (1–12)` that survives keeper additions and removals.

Without RFC 0019 every consumer (editor blame strip, refactor attribution, audit ledger) reinvents this accumulator with subtle drift.

## 2. Non-Goals

- Wire format definition. The server-side event source (Git blame replay, runtime keeper edit stream, MCP tool action) is owned by the backend RFC track (Provider-C Phase 1–3, gap_analysis Gap-001). This RFC defines only the in-dashboard contract.
- Authorship resolution conflicts (two keepers claiming the same line). Resolved by `last-event-wins` in v1; multi-author overlay is a follow-up.
- Persistence across page reloads. v1 rebuilds ownership from the live event stream at mount.
- Editor rendering. Headless — the consumer owns the gutter / strip DOM.

## 3. Public API (sketch)

```ts
// src/components/ide/keeper-line-ownership-store.ts

import type { ReadonlySignal } from '@preact/signals'

export interface KeeperEdit {
  readonly file_path: string
  readonly line_start: number       // 1-indexed, inclusive
  readonly line_end: number         // 1-indexed, inclusive
  readonly keeper_id: string
  readonly timestamp_ms: number
  readonly kind: 'edit' | 'create' | 'refactor' | 'revert'
}

export interface LineOwnership {
  readonly keeper_id: string
  readonly hue_index: number        // 1..12, stable per keeper_id
  readonly last_edit_kind: KeeperEdit['kind']
  readonly last_edit_ms: number
}

export interface KeeperLineOwnershipStore {
  readonly ownership: ReadonlySignal<ReadonlyMap<number, LineOwnership>>
  readonly eventsForLine: (line: number) => ReadonlyArray<KeeperEdit>
  readonly knownKeepers: ReadonlySignal<ReadonlyArray<string>>
  readonly ingest: (event: KeeperEdit) => void
  readonly reset: (filePath: string) => void
  readonly dispose: () => void
}

export function createKeeperLineOwnership(
  filePath: ReadonlySignal<string>,
): KeeperLineOwnershipStore
```

The store uses `@preact/signals`; its accumulator remains framework-agnostic in
`headless-core/keeper-line-ownership.ts`.

## 4. Hue assignment

`hue_index` maps `keeper_id → 1..12` deterministically:

```
hue_index(keeper_id) = (hash(keeper_id) % 12) + 1
```

The hash is FNV-1a (32-bit) so that two dashboards mounting the same keeper see the same hue. The mapping is also re-exposed through `knownKeepers()` so the blame strip can render a legend without duplicating the hash.

The 12-slot palette is `--color-keeper-1-glow` … `--color-keeper-12-glow` (semantic). Raw fallback is `--k-1` … `--k-12`. Components must consume the semantic tier per SPEC §3 / audit §3.

## 5. Test plan

- Property test: feeding N events from M keepers produces a `Map` whose size equals `count(unique line)` and whose values reflect the latest event per line.
- Determinism test: `hue_index('nick0cave')` is stable across runs; collisions in 12-slot space are surfaced via `knownKeepers()` (consumer can warn).
- Reset test: `reset(filePath)` empties the accumulator without disposing the signal so subscribers continue receiving updates.

## 6. Migration & rollout

- Phase A (this RFC): land the headless accumulator + Preact adapter + 1 unit test.
- Phase B (PR-5): wire the editor blame strip to the store.
- Phase C: extend the store with an audit-export selector for the audit ledger (separate RFC).

## 7. Open questions

- Should the hue assignment be configurable per project (e.g., a pinned mapping for long-lived keepers)? Defer to a follow-up if real keeper rotation reveals collisions.
- Multi-line ranges with overlapping keepers — current model picks last-event-wins per individual line. A "co-owned" representation is possible but adds rendering complexity; defer.
