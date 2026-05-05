# RFC 0023 — Cascade Overlay Layer (extends RFC 0020)

- **Status**: Draft
- **Author**: Vincent + Claude (auto mode 2026-05-05)
- **Created**: 2026-05-05
- **Extends**: RFC 0020 (Layered Overlay System)
- **Depends on**: RFC 0019 (Keeper Line Ownership), RFC 0020 (Layered Overlay)
- **Parent RFC**: RFC 0022 (IDE Plane Assembly v1 — Umbrella)
- **GitHub Issue**: #13198

---

## 1. Motivation

RFC-0020 정의 LAYERS toggle 의 6 layer (Time/Parallel/Tools/Approve/Notes/EXPLODE) 에는 **Cascade** 가 빠져 있다. masc-mcp 는 매 LLM turn 마다 cascade router 가 provider/model fallback 을 처리하고, 그 결과(`cascade_audit/*.jsonl`)는 commit_sha 단위로 file/line 에 attribution 가능. line 별 cascade hit (provider/model/cost/latency) 을 line gutter chip 으로 overlay 표시하면 "이 라인이 비싼 모델로 들어왔는지", "fallback 에서 왔는지" 를 *읽을 때* 가 아니라 *돌아볼 때* 알게 된다.

이 패턴은 memory `feedback_wave_pattern_60_80_stale_resolved` 의 fix-the-fix 사이클을 시각으로 잡는다.

## 2. Non-Goals

- cascade router 자체 변경 (consumer of `cascade_audit` only)
- per-token cost (line 단위 가장 fine-grained)
- realtime cascade event stream (1단계 commit-snapshot, 2단계는 별도 RFC)

## 3. Public API

### 3.1 LAYERS entry 추가

`dashboard/src/components/ide/ide-toolbar.ts` 의 `IDE_LAYERS` 배열에 entry 추가:

```ts
{
  kind: 'cascade',
  label: 'Cascade',
  description: 'cascade hit per line (provider · model · cost · latency)',
  mutuallyExclusive: false,
}
```

### 3.2 Overlay store

```ts
// dashboard/src/components/ide/overlay-cascade.ts
export interface CascadeHit {
  readonly file_path: string
  readonly line_start: number       // 1-indexed inclusive
  readonly line_end: number
  readonly provider: string         // 'anthropic' | 'openai' | 'moonshot' | ...
  readonly model_id: string
  readonly cost_usd: number
  readonly latency_ms: number
  readonly cascade_step: number     // 0=primary, 1=fallback, 2=tertiary, ...
  readonly commit_sha: string
  readonly turn_id: string
}

export interface CascadeOverlayStore {
  readonly hitsForFile: (path: string) => ReadonlyMap<number, CascadeHit[]>
  readonly hitsForCommit: (sha: string) => ReadonlyArray<CascadeHit>
  readonly ingest: (event: CascadeHit) => void
  readonly setVisibleRange: (path: string, lineFrom: number, lineTo: number) => void
}
```

### 3.3 REST endpoint

```
GET /api/dashboard/cascade-overlay?file=<path>&commit_sha=<sha>
GET /api/dashboard/cascade-overlay?file=<path>&since_ms=<ts>
```

response: `{ "hits": CascadeHit[] }`

## 4. Data source

### 4.1 1단계: commit-level

`.masc/cascade_audit/*.jsonl` 을 server-side 로 인덱스. 각 entry 가 이미 `commit_sha` 와 `turn_id` 를 가짐. file_path 는 turn 의 tool_call (write/edit) 에서 추출. line_range 는 commit diff hunk 와 join.

1단계는 명시적 file-level hit 으로 wire 한다: `line_range` 를 `null` 로 두고, diff hunk join 이 가능한 2단계부터 1-indexed inclusive `{ line_start, line_end }` 를 채운다.

### 4.2 2단계: line-level

`git show --unified=0 <commit_sha>` 로 hunk 추출 + tool_call 의 edit range 와 cross-reference. 별도 PR.

## 5. Rendering

editor gutter (line number 옆) 에 cascade chip:

```
   42  | provider · cost   foo()
   43  | provider · cost   bar()
```

color: `--color-keeper-N-glow` (provider hash → 12 slot) + cost band:
- ≤ $0.001: `--color-status-ok`
- ≤ $0.01: `--color-status-warn`
- > $0.01: `--color-status-err`

hover: tooltip with full `CascadeHit` (model_id, latency_ms, cascade_step, turn_id link).

## 6. ARIA

- chip: `role="img"` + `aria-label="cascade: {provider} {model_id} ${cost_usd}"`
- gutter region: `aria-label="cascade overlay, {N} hits in view"`
- toggle (LAYERS): RFC-0015 multi-select Tabs 어댑터 그대로

## 7. Test plan

- unit: `overlay-cascade.test.ts` — ingest, hitsForFile, visible range filter
- e2e: 1 sample commit (`cascade_audit` jsonl) → overlay 활성 → gutter chip 표시 (Playwright snapshot)
- a11y: `jest-axe` + reduced-motion (chip 등장 fade-in 즉시)

## 8. Open questions

1. **provider hash → keeper slot collision**: provider 8개, keeper 12 slot. 충돌 시 hue stride 30° 보장 깨짐 → provider hash 별도 palette 또는 keeper slot 9-12 reserve.
2. **commit-level fallback 표시 방식**: line-level 아닌 1단계는 "whole-file glow" vs "first-line chip" — UX 측정 필요.
