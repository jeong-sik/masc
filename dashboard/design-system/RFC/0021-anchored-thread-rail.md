# RFC 0021 — Anchored Thread Rail

- **Status**: Draft
- **Author**: design-system stewardship
- **Created**: 2026-04-30
- **Depends on**:
  - RFC 0010 (Collaboration Cursor — keeper presence + line-anchor base)
  - RFC 0014 (TreeView — for grouping threads by file in cross-file views)
- **Consumes**: `--color-status-{ok,warn,err,info,stalled}` (per thread kind), `--color-bg-elevated`, `--color-fg-secondary`, `--color-keeper-N-glow`.
- **Blocks**: editor CONVERSATION rail (Stage 5 IDE plane PR-6), cross-file review feed (follow-up RFC).

---

## 1. Motivation

The IDE mockup right rail carries five kinds of conversation cards anchored to specific lines:

```
[FLAG]     nick0cave   router.ts:34   if:provider-b-tool-choice         01:41:18
           "This is exactly the schema error we're seeing in prod —"
           2 replies · open

[QUESTION] operator    router.ts:26   fn:resolveRuntime               01:39:02
           "Should normalizeTools also handle tool_choice=none?"
           1 reply · open

[APPROVE]  operator    router.ts:60   fn:nextStep                     01:22:41
           "Budget guard reads well. Ship it when tests pass." · open

[NOTE]     operator    router.ts:35   token:log.warn                  01:18:04
           "telemetry event name needs to match the lifeline schema"

[SUGGEST]  masc-improver router.ts:16 fn:normalizeTools               01:14:52
           "Could you collapse the rest-spread into a small helper?"
           3 replies · open
```

Each card carries: (a) a **kind** (FLAG / QUESTION / APPROVE / NOTE / SUGGEST), (b) an **anchor** (file path + line range or symbol), (c) **author** (keeper id), (d) **timestamp**, (e) **body**, (f) optional **reply count and resolution state**.

RFC 0010 defines the keeper-presence anchor primitive but does not cover thread aggregation, kind taxonomy, or the editor↔rail click-to-scroll workspace collaboration. This RFC fills that gap so all three consumers (CONVERSATION rail in the IDE, audit ledger, cross-file review feed) share one model.

## 2. Non-Goals

- Conversation persistence and event sourcing. Backend RFC track owns it (Provider-C gap_analysis Gap-001 / Gap-006).
- Inline rendering inside the editor (e.g., per-line balloon). The rail is the v1 surface; per-line balloons are a follow-up.
- Threading depth beyond reply count. Replies render as a flat list in v1.
- Editing threads. Read + create + resolve only; in-place edits are a follow-up.

## 3. Public API (sketch)

```ts
// headless-core/anchored-thread-rail.ts

export type ThreadKind = 'flag' | 'question' | 'approve' | 'note' | 'suggest'

export interface ThreadAnchor {
  readonly file_path: string
  readonly line_start: number | null      // null = file-level
  readonly line_end: number | null
  readonly symbol_hint?: string           // optional 'fn:resolveRuntime' / 'token:log.warn'
}

export interface Thread {
  readonly id: string
  readonly kind: ThreadKind
  readonly author_keeper_id: string
  readonly anchor: ThreadAnchor
  readonly body: string
  readonly created_ms: number
  readonly resolved: boolean
  readonly reply_count: number
}

export interface AnchoredThreadRailController {
  readonly visibleThreads: ReadonlyArray<Thread>      // current-file scope
  readonly threadsForLine: (line: number) => ReadonlyArray<Thread>
  readonly focusedThreadId: string | null
  readonly focusThread: (id: string) => void
  readonly clearFocus: () => void
  readonly subscribe: (listener: () => void) => () => void
}

export function createAnchoredThreadRail(opts: {
  filePath: () => string
  threads: () => ReadonlyArray<Thread>
}): AnchoredThreadRailController
```

Adapter: `headless-preact/use-anchored-thread-rail.ts`.

## 4. Editor ↔ rail workspace collaboration

Two flows must work without coupling consumers:

1. **Click thread → scroll editor**. The rail emits a `focusThread(id)` event. The editor host subscribes to focus changes and scrolls the visible viewport so `anchor.line_start` is in view; if anchor is `null` it scrolls to the top of the file. The scroll behavior (smooth / instant / centered) is the editor's choice.
2. **Click line → highlight related threads**. The editor exposes `currentLine: Accessor<number | null>` (from cursor position). The rail uses `threadsForLine(currentLine)` to render the related-threads strip at the rail head. When `currentLine` is `null`, the strip is empty.

Both flows are mediated by the controller — no direct DOM coupling between editor and rail.

## 5. Kind taxonomy and color encoding

| Kind     | Status semantics       | Token                       |
|----------|------------------------|-----------------------------|
| FLAG     | blocking, requires action | `--color-status-err`        |
| QUESTION | open clarification      | `--color-status-info`       |
| APPROVE  | passed review           | `--color-status-ok`         |
| NOTE     | observational           | `--color-fg-muted`          |
| SUGGEST  | optional improvement    | `--color-status-warn`       |

The author keeper hue (RFC 0019 `hue_index`) is rendered as a left border on each card so an operator scanning the rail sees both kind (chip color) and author (border color) without reading text.

## 6. Test plan

- Filter test: feeding 30 threads across 3 files, scoping to one file path returns only that file's threads in `visibleThreads`.
- Line lookup test: `threadsForLine(L)` returns threads whose `[anchor.line_start, anchor.line_end]` range includes `L`.
- Focus test: `focusThread(id)` sets `focusedThreadId`; `clearFocus()` resets to `null`; subscribers fire on each change.
- Resolved filter test: a `resolved=true` thread is still in `visibleThreads` (consumer decides hiding); `reply_count` is exposed for filter chips.

## 7. Migration & rollout

- Phase A (this RFC): land headless controller + 2 adapters + tests. No surface wiring.
- Phase B (PR-6 of Phase 2): mount the rail in the IDE shell, fed by mock threads.
- Phase C: wire to the live thread store (backend RFC dependent — see Provider-C Phase 1–3, gap_analysis Gap-001).

## 8. Open questions

- Cross-file rail mode (a global review feed) — same controller with `filePath: () => null`? Or a separate controller? Defer until cross-file review feed has a concrete consumer.
- Reply rendering — flat in v1, but does threading depth ever matter? Probably no for code review; the SUGGEST/FLAG flow reads naturally as flat replies.
- Resolution: should resolved threads auto-collapse after T seconds? Defer to operator preference.
