# RFC 0026 — Audit Replay Timeline (extends RFC 0021)

- **Status**: Draft
- **Author**: Vincent + Claude (auto mode 2026-05-05)
- **Created**: 2026-05-05
- **Extends**: RFC 0021 (Anchored Thread Rail)
- **Depends on**: RFC 0021, audit ledger (`.masc/audit/*`)
- **Parent RFC**: RFC 0022 (IDE Plane Assembly v1)
- **GitHub Issue**: #13201

---

## 1. Motivation

post-mortem 디버깅이 "git log + grep" 조합에서 "코드 보면서 시간을 끌어서 봄" 으로 바뀐다. memory `feedback_compaction_summary_pr_number_hallucination` 의 reverse-direction (GitHub state 먼저 → transcript trace) 검증을 시각으로.

audit ledger / cascade_audit / decisions / anchored thread 모두 `ts_ms` 를 갖고 있어 timeline 슬라이더 한 축으로 통합 재투영 가능. 1단계 PR-bound replay (PR open~close 기간만), 2단계 free-range scrub.

## 2. Non-Goals

- audit ledger 자체 변경 (consumer only)
- write/mutating action (read-only)
- diff replay (별도 RFC; v1 은 thread/decision/cascade 만)

## 3. Public API

### 3.1 Timeline filter

```ts
// dashboard/src/components/ide/replay-overlay.ts
export interface ReplayWindow {
  readonly since_ms: number
  readonly until_ms: number
  readonly mode: 'pr-bound' | 'free-range'
  readonly pr_number?: number       // mode = pr-bound
}

export interface ReplayOverlayStore {
  readonly window: () => ReplayWindow
  readonly setWindow: (w: ReplayWindow) => void
  readonly threadsInWindow: () => ReadonlyArray<AnchoredThread>     // RFC-0021
  readonly decisionsInWindow: () => ReadonlyArray<Decision>
  readonly cascadeHitsInWindow: () => ReadonlyArray<CascadeHit>      // RFC-0023
}
```

기존 `anchored-thread-rail-store.ts` 의 `timestamp_ms` 필드를 filter 기준으로 사용. cascade overlay (RFC-0023) 도 같은 window 적용.

### 3.2 REST endpoint

```
GET /api/dashboard/audit-replay?since_ms=<ts>&until_ms=<ts>&pr_number=<number>
```

response (chunked):

```json
{
  "window": ReplayWindow,
  "threads": AnchoredThread[],
  "decisions": Decision[],
  "cascade_hits": CascadeHit[],
  "ts_index": [{ts_ms, kind, count}]    // for scrubber tick density
}
```

### 3.3 Scrubber UI

```tsx
// dashboard/src/components/ide/audit-replay-slider.tsx
interface Props {
  readonly window: ReplayWindow
  readonly onChange: (w: ReplayWindow) => void
}
```

placement: `ide-shell.ts` 의 editor 상단 (modebar 아래).

## 4. Scrubber behavior

- range slider (since/until 두 핸들)
- `ts_index` 의 density 를 background histogram 으로 표시 (어느 시점이 active 했는지)
- keyboard: `←/→` 1초 step, `Shift+←/→` 1분, `Ctrl+←/→` 1시간 (RFC-0012)
- 각 핸들 별 `aria-label="replay since"` / `"replay until"`

## 5. PR-bound mode

PR open ~ close (또는 현재) 의 `ts_ms` range 를 자동 결정:
- `gh pr view <pr> --json createdAt,mergedAt,closedAt,state`
- `since_ms = createdAt`, `until_ms = mergedAt || closedAt || Date.now()`

## 6. Re-projection

window 변경 → 모든 overlay (anchored-thread-rail, cascade-overlay-layer) 가 동일 store subscribe → 자동 re-render. inspector slot (RFC-0024) 도 BDI snapshot 을 *그 시점* 의 BDI 로 대체.

## 7. ARIA

- slider region: `role="region"` + `aria-label="audit replay timeline, {window summary}"`
- 각 핸들: `role="slider"` + `aria-valuenow={ms}` + `aria-valuetext="2026-05-05 18:30"`
- update: `aria-live="polite"` (window 변경 announce)

## 8. Test plan

- unit: `replay-overlay.test.ts` — window 변경 → store filter
- e2e: PR-bound 1개 사례 (#13174 같은 short-lived PR) 에서 thread/decision/cascade ordering 이 timeline 과 일치
- a11y: `jest-axe` + 키보드 navigation

## 9. Performance

- audit ledger 가 100k+ entries 가능 → server 측에서 PR-bound window 로 prefilter (1단계)
- ts_index 는 1분 bucket aggregate (scrubber 화면 분해능 충분)
- free-range (2단계) 는 server-side cursor pagination

## 10. Open questions

1. **future: live replay**: window upper bound = "now" 일 때 자동 update vs frozen 모드 선택. v1 frozen.
2. **inspector slot 시점 BDI**: 시점 BDI 가 server 에 보존되는지? v1: 미보존이면 "BDI snapshot at {ts} unavailable" fallback.
3. **scrubber density 색상**: density histogram 의 color band — keeper hue 평균 vs activity intensity vs status mix. UX 측정.
