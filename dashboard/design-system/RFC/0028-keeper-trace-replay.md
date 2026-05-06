# RFC 0028 — Keeper Trace Replay (synthesizes RFC 0021 + 0023 + 0024 + 0026)

- **Status**: Draft
- **Author**: Vincent + Claude (auto mode 2026-05-06)
- **Created**: 2026-05-06
- **Synthesizes**: RFC 0021 (Anchored Thread Rail), RFC 0023 (Cascade Overlay Layer), RFC 0024 (BDI Inspector Slot), RFC 0026 (Audit Replay Timeline)
- **Extends**: RFC 0020 (Layered Overlay System) — adds `keeper-trace` LAYERS entry
- **Depends on**: RFC 0019 (Keeper Line Ownership), RFC 0021, RFC 0023, RFC 0024, RFC 0026
- **Parent RFC**: RFC 0022 (IDE Plane Assembly v1)
- **Differentiation from RFC 0026 §6**: RFC 0026 의 "Re-projection" 은 각 layer (thread rail / cascade overlay / inspector) 가 독립적으로 ReplayWindow store 를 subscribe 한다. 본 RFC 는 한 단계 더 — **4 source 를 stitched 단일 layer 로 합성** 하여 cross-source 시간 상관 (예: "이 line 의 cascade hit 시점에 anchored thread 가 fired") 을 직접 보이는 새 IDE_LAYERS entry.

---

## 1. Motivation

`replay-overlay.ts` (RFC-0026) 가 timeline scrub 시 4 source 를 동일 ReplayWindow 로 필터한다. 그러나 4 source 는 **3개 별도 surface** (anchored-thread-rail, cascade-overlay-layer, inspector-keeper-bdi) 에 독립 표시되어 user 가 4 surface 를 동시 scan 해야 cross-source 상관 (causal chain) 을 발견한다.

**Use-case**: post-mortem 디버깅 시 "왜 이 line 이 비싼 모델로 들어왔지?" 답하려면:
1. cascade overlay 보고 cost band err 확인
2. timeline scrub 으로 cascade hit 시점 잡음
3. 그 시점 anchored thread (작성자 keeper id) 식별
4. 그 keeper 의 BDI snapshot 으로 의도 파악

4 surface scan = cognitive load 높음. **`keeper-trace` LAYERS toggle** = single chip click 으로 4 source stitched (line gutter chip click → tooltip 안 cascade hop chain + 그 시점 thread + BDI summary 한 번에 표시).

memory `feedback_compaction_summary_pr_number_hallucination` 의 reverse-direction (state → trace) 검증의 inline 버전.

## 2. Non-Goals

- write/mutating action (read-only — RFC 0026 §2 와 동기)
- per-token cost (line 단위 — RFC 0023 §2 와 동기)
- realtime 합성 (1단계 historic only; live replay 는 RFC 0026 §10 #1 후속)
- diff replay (코드 변경 자체의 시간순 재생 — RFC 0026 §2 와 동기)
- 새 데이터 source 도입 (4 기존 source 의 stitched view 만; backend 변경 0)
- arbitrary 시간 해상도 (1초 step 기본; RFC 0026 §4 ScrUbber keyboard 와 동기)

## 3. Public API

### 3.1 KeeperTraceEvent shape (composed)

```ts
// dashboard/src/components/ide/keeper-trace-store.ts
export interface KeeperTraceEvent {
  readonly ts_ms: number
  readonly file_path: string
  readonly line_start: number          // 1-indexed inclusive
  readonly line_end: number
  readonly source: TraceSource
  readonly summary: string             // 1-line human-readable
  readonly raw: TraceEventRaw          // discriminated union, full payload
}

export type TraceSource = 'cascade' | 'thread' | 'bdi' | 'decision'

export type TraceEventRaw =
  | { readonly kind: 'cascade'; readonly hit: CascadeHit }                // RFC 0023
  | { readonly kind: 'thread'; readonly thread: AnchoredThread }          // RFC 0021
  | { readonly kind: 'bdi'; readonly snapshot: KeeperBDISnapshot }        // RFC 0024
  | { readonly kind: 'decision'; readonly decision: Decision }            // RFC 0026

export interface KeeperTraceStore {
  readonly window: () => ReplayWindow                                     // RFC 0026
  readonly eventsForLine: (path: string, line: number) => ReadonlyArray<KeeperTraceEvent>
  readonly eventsForFile: (path: string) => ReadonlyArray<KeeperTraceEvent>
  readonly subscribe: (listener: () => void) => () => void
}
```

`KeeperTraceEvent` 는 4 store 의 데이터를 시간순 통합한 derived view. 새 store 가 아니라 **4 store 의 join read** — 새로운 server 데이터 0.

### 3.2 REST endpoint

**없음**. 4 기존 endpoint (`/api/dashboard/cascade-overlay`, `/api/dashboard/audit-replay`, `/api/dashboard/keeper-bdi/<id>`, anchored thread store) 를 client-side join. RFC 0026 §3.2 의 `/api/dashboard/audit-replay` 가 이미 `threads` + `decisions` + `cascade_hits` 한 response 로 chunked 반환 — `bdi` 만 per-keeper fetch 추가.

### 3.3 LAYERS entry

`dashboard/src/components/ide/ide-toolbar.ts` 의 `IDE_LAYERS` 배열에 entry 추가:

```ts
{
  kind: 'keeper-trace',
  label: 'Keeper trace',
  description: 'stitched cascade + thread + BDI per line, replay-window aware',
  mutuallyExclusive: false,
  conflictsWith: ['cascade'],   // RFC 0023 cascade chip 과 같은 gutter 위치 — 동시 활성 시 keeper-trace 우선
}
```

`mutuallyExclusive: false` 는 다른 layer (Time/Parallel/Tools/Approve/Notes/EXPLODE) 와 동시 활성 가능. `conflictsWith: ['cascade']` 는 같은 gutter 위치라 visual collision 회피. 사용자가 둘 다 켜면 keeper-trace 가 cascade 를 hide.

### 3.4 Stitched component

```tsx
// dashboard/src/components/ide/overlay-keeper-trace.tsx
interface Props {
  readonly store: KeeperTraceStore
  readonly visibleRange: { lineFrom: number; lineTo: number }
}
```

placement: editor gutter (RFC 0023 cascade chip 과 같은 위치). `cascade` layer 와 mutual hide.

## 4. Composition algorithm

`KeeperTraceStore.eventsForLine(path, line)` 가 return 하는 list:

```
1. ReplayWindow 의 since_ms ~ until_ms 범위 안의 event 만 필터
2. 4 store 에서 (path, line) 매치하는 event 수집:
   a. cascade.hitsForFile(path).get(line) → CascadeHit[]
   b. thread.threadsForLine(line).filter(t => t.anchor.file_path === path)  → Thread[]
   c. decision.decisionsInWindow().filter(d => d.affected.file === path && d.affected.line_in_range(line))  → Decision[]
   d. bdi: thread author 의 keeper_id 별로 그 시점 BDI snapshot fetch (별도 batch)
3. event list 를 ts_ms 오름차순 정렬
4. 각 event 의 summary 1-line 생성 (source 별 template)
```

**Time bucket coalescing**: 같은 line 에 50ms 이내 burst event 는 single composite chip 으로 묶음 (visual noise 회피). 사용자 hover 시 expand.

## 5. Rendering

editor gutter (line number 옆) 에 stacked chip:

```
   42  | ◆◆· bar()      (3 events: 1 cascade + 1 thread + 1 bdi)
   43  | ◆ ·  baz()      (1 event: 1 cascade)
   44  | ◆◆◆◆ qux()     (4+ events: stack cap 3 + overflow indicator)
```

- **chip color**: 각 source 별 token. cascade `--color-keeper-N-glow`, thread `--color-status-{kind-color-map}` (RFC 0021 §5), bdi `--color-fg-secondary`, decision `--color-status-info`.
- **stack cap 3**: 같은 line 에 events ≥ 4 면 첫 3 + `+N` overflow indicator.
- **hover tooltip**: 시간순 list. 각 row = `<icon> <ts_relative> <summary>`. 50ms coalesce 된 composite 는 indented sub-list.
- **click**: scrubber 가 이 event ts 로 jump (RFC 0026 ReplayWindow 갱신). 4 다른 surface (rail / overlay / inspector) 도 동기 update.

cost band (RFC 0023 §5) 는 cascade chip 에 한정; thread/bdi/decision chip 에는 적용 안 함.

## 6. ARIA

- gutter region: `role="region"` + `aria-label="keeper trace overlay, {N} events in view"`
- chip group (per line): `role="list"` + `aria-label="line {N} trace, {M} events"`
- chip: `role="img"` + `aria-label="{source}: {summary}, {ts_relative}"`
- tooltip: `role="dialog"` + focus management (RFC 0006 Tooltip + RFC 0009 Task-queue patterns)
- click → scrubber jump: `aria-live="polite"` 한 번 ("replay window jumped to {ts}")

## 7. Replay sync

`KeeperTraceStore.window()` 가 `ReplayOverlayStore.window()` (RFC 0026 §3.1) 를 직접 reference — 동일 source of truth. user 가 RFC 0026 scrubber drag 하면 keeper-trace overlay 가 자동 re-render.

**Inverse**: keeper-trace chip click 으로 scrubber 가 이동 (§5 click action) — 4 surface 가 그 시점으로 동기.

## 8. Test plan

- unit (`overlay-keeper-trace.test.ts`):
  - 4 store mock 으로 시간순 정렬 검증
  - 50ms coalescing burst 검증
  - stack cap 3 + `+N` overflow
  - `conflictsWith: ['cascade']` 활성화 시 cascade chip hide
- e2e (Playwright):
  - PR-bound replay 1 사례 (#13174 short PR) 에서 keeper-trace gutter chip + scrubber click → window jump 확인
  - chip hover tooltip 의 source-별 row order
- a11y (`jest-axe` + `axe-playwright`):
  - chip group navigable
  - tooltip focus trap
  - reduced-motion 시 chip 등장 fade-in 즉시
- perf (lighthouse-ci):
  - 100k event ledger 의 file-level filter < 50ms / scrub
  - 50ms coalescing 알고리즘 main-thread blocking < 16ms / 60fps

## 9. Performance

- **client-side join**: 4 store 가 in-memory 라 join 자체 cheap. ReplayWindow filter 가 가장 큰 비용 — RFC 0026 §9 의 PR-bound prefilter 적용.
- **lazy BDI fetch**: thread author 의 BDI 는 hover 시점에 fetch (chip 표시 시점 안 함). 5초 TTL cache (RFC 0024 §3.2) 가 흡수.
- **viewport culling**: `visibleRange` (Props) 안의 event 만 chip render. line scroll 시 store subscription 으로 incremental.

## 10. Migration from RFC 0023 cascade layer

**Backward-compatible LAYERS state**: 사용자가 v1 에 `cascade` layer 만 enable 한 상태에서 본 RFC 머지 후 `keeper-trace` 추가 표시. user gesture 없이 자동 enable 안 함.

**chip position 충돌**: §3.3 `conflictsWith: ['cascade']` 가 둘 다 켜진 상태 visual stacking 회피. 사용자가 cascade 만 보고 싶으면 keeper-trace toggle off 한 번.

**Data source 호환**: cascade store 의 `CascadeHit` 가 v1 그대로. keeper-trace 는 join read 만 — schema 변경 0.

## 11. Open questions

1. **Composite event 의 author**: 같은 line 에 cascade hit (provider X) + thread (author keeper Y) + bdi (keeper Z) 가 동시 있으면 chip 의 author hue 가 누구? **v1 = 가장 빈도 높은 keeper_id** (event count 기준). 동률 시 thread > bdi > cascade priority. v1.1 측정 후 조정.
2. **stack cap 3 의 정당성**: gutter 폭 (line number 16px + chip 24px × 3 = 88px) 가 한도. cap=4 면 영역 부족. v1 = 3 fixed; v2 측정 후 조정.
3. **PR-bound 외 free-range 의 join 부하**: 100k+ event 의 client-side join 이 60fps 를 넘는지 perf §9 측정. 초과 시 server-side join + denormalized response 검토 (RFC 0026 §9 prefilter 확장).
4. **decision source 의 anchor 모델**: `Decision` 이 line 단위 anchor 를 갖는지 확실하지 않음 — RFC 0026 §3.1 의 `Decision[]` 가 file/line affected 필드 보장? **v1 시작 전 RFC 0026 author 와 confirm 필요**. 미보장 시 keeper-trace 의 'decision' source 제외 (3-way join).
5. **inspector slot (RFC 0024) 와의 통합**: keeper-trace chip click → 그 keeper 의 inspector slot 자동 pin? 또는 별도 user gesture 필요? **v1 = 별도 gesture** (chip click = scrubber jump only); v2 후보.

## 12. References

- RFC 0019 — Keeper Line Ownership
- RFC 0020 — Layered Overlay System (parent of LAYERS framework)
- RFC 0021 — Anchored Thread Rail (thread source)
- RFC 0022 — IDE Plane Assembly v1 (parent)
- RFC 0023 — Cascade Overlay Layer (cascade source, conflictsWith)
- RFC 0024 — BDI Inspector Slot (bdi source)
- RFC 0026 — Audit Replay Timeline (ReplayWindow source of truth)
- RFC 0027 — Multi-Keeper BDI Peek (sibling v1.1)
