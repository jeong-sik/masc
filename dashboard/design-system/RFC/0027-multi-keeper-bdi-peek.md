# RFC 0027 — Multi-Keeper BDI Peek (extends RFC 0024)

- **Status**: Draft
- **Author**: Vincent + Claude (auto mode 2026-05-05)
- **Created**: 2026-05-05
- **Extends**: RFC 0024 (BDI Inspector Slot)
- **Depends on**: RFC 0008 (AgentPresence), RFC 0019 (Keeper Line Ownership), RFC 0024
- **Parent RFC**: RFC 0022 (IDE Plane Assembly v1)
- **Replaces**: RFC 0024 §2 Non-Goal #3 ("multi-keeper compare view (single pin only; multi 는 별도 RFC)")

---

## 1. Motivation

RFC 0024 의 inspector slot 은 **single-pinned keeper** 만 다룬다. 그러나 IDE 사용 시 **co-located keeper 들의 BDI 를 동시에 비교** 가 자주 필요하다:

- **Cascade race 진단**: 같은 line 에 cascade 가 떨어진 후 두 keeper 가 같은 commit 영역을 다른 의도로 수정 — 의도 충돌이 conflict 의 cause.
- **Pair work 디버깅**: keeper-A 가 implementation 을 작성하는 동안 keeper-B 가 review 또는 test 를 동시 작성하는 경우, 둘의 belief / desire 가 align 되어 있는지.
- **Cross-keeper dependency**: keeper-A 의 desire 가 "wait for keeper-B's PR ready" 일 때 keeper-B 의 intention 을 같이 봐야 stuck 여부 판단.

RFC 0024 §2 Non-Goal #3 가 "multi-keeper compare view 는 별도 RFC" 로 deferred. 본 RFC 가 그 별도 RFC.

## 2. Non-Goals

- BDI **diff** view (두 keeper 의 belief/desire textual diff 자동 생성). 시각적 align 은 column layout 만 — semantic diff 는 v3 후보.
- BDI mutating action (read-only 유지, RFC 0024 §2 #2 따라).
- arbitrary 동시 keeper 수 — **본 RFC 는 cap=4** (하드 제한, §6 ARIA / UI density 정합).
- BDI snapshot 자체 정의 (`lib/keeper_status_bridge` owner — RFC 0024 §2 #1).
- Cross-keeper recent_token_spend rollup 의 **세션-누적** view (snapshot 시점 5턴만 — long-window 는 RFC 0026 audit replay 가 owner).

## 3. Public API

### 3.1 PinnedKeepersStore shape

```ts
// dashboard/src/components/ide/multi-keeper-pin-store.ts
export interface PinnedKeepers {
  // UI order, max 4. pinKeeper prepends; reorderPins may change order without changing pinned_at_ms.
  readonly entries: ReadonlyArray<PinnedKeeperEntry>
  // global cap; future RFC may parameterize.
  readonly cap: 4
}

export interface PinnedKeeperEntry {
  readonly keeper_id: string
  // millisecond timestamp; LRU evict picks min.
  readonly pinned_at_ms: number
  // user-visible alias; falls back to keeper_id if AgentPresence label missing.
  readonly display_label: string
  // present when pin was triggered by an editor line click; null when pinned via command palette.
  readonly source_line: {
    readonly file_path: string
    readonly line_number: number
  } | null
}
```

`PinnedKeepers.entries` 는 immutable; mutator 는 새 array 를 반환하는 store API 만 (`pinKeeper`, `unpinKeeper`, `reorderPins`).

### 3.2 REST endpoint

**기존 `GET /api/dashboard/keeper-bdi/<keeper_id>` 그대로 사용** — 새 endpoint 없음. Client 가 4 개 keeper 에 대해 4 concurrent fetch (browser HTTP/2 multiplexing 에서 단일 connection 으로 처리). server 부담은 keeper 당 5초 TTL cache 로 흡수 (RFC 0024 §3.2).

### 3.3 Multi-pin component

```tsx
// dashboard/src/components/ide/inspector-multi-keeper-bdi.tsx
interface Props {
  readonly pinned: PinnedKeepers
  readonly onUnpin: (keeper_id: string) => void
  readonly onReorder: (next: ReadonlyArray<string>) => void
  readonly onFocus: (keeper_id: string) => void
}
```

placement: RFC 0024 의 single-slot 위치 (`ide-shell.ts` 우측). single-pin component (`inspector-keeper-bdi.tsx`) 는 *대체* — `pinned.entries.length <= 1` 분기에서는 single-pin layout 을 그대로 렌더하여 v1 UX 회귀 0.

## 4. Pin behavior (multi)

| Action | Result |
|--------|--------|
| line click (RFC 0019 ownership) → `setPinnedKeeper(K)` | K 가 이미 pinned 면 기존 entry 를 제거하고 새 `pinned_at_ms` 로 head 에 prepend. `candidate = [entry(K, now), ...prev.filter(e => e.keeper_id !== K)]`; cap 초과 시 array tail 이 아니라 `min(pinned_at_ms)` entry 를 drop. tie 면 minima 중 current UI order 에서 가장 뒤의 entry 를 drop. |
| command palette `Pin keeper <id>` | 같은 reorder/cap 로직 |
| X 버튼 또는 `Esc` (RFC 0012) | 활성 pin (focus 된 entry) unpin. focus 없으면 head unpin. |
| drag (mouse 또는 keyboard `Alt+ArrowLeft/Right`) | `reorderPins` 호출, source_line 보존 |
| 같은 keeper 두 번 pin | head 로 reorder, no duplicate |
| AgentPresence 로 keeper offline 감지 (RFC 0008) | entry 유지, BDI snapshot 영역에 "offline since {ts}" stale indicator. unpin 은 user gesture only |

**Auto-pin opt-out**: RFC 0024 §4 ("auto-pin 옵션은 default off") 그대로 유지. multi-pin 도 user gesture only.

## 5. UI density

inspector rail 폭은 cockpit-kit 기본 320px. 4 keeper 동시 표시 시 column layout:

| Layout | Trigger | Per-keeper visible |
|--------|---------|--------------------|
| **Stacked (default)** | `entries.length <= 2` | full BDI panel (belief 5, desire 3, intention, recent spend 5턴, last_tool_call) |
| **Compact-fold** | `entries.length == 3 OR 4` | header (label + intention 1 line) only; belief / desire / spend 는 fold. user expand 가능 (RFC 0012 `Alt+Enter`) |
| **Focus-mode** | user click on entry header | 그 entry 만 stacked, 나머지 compact-fold |

cap=4 이 ARIA 에 정합:
- `role="region"` 4 개 nested 가 NVDA / VoiceOver 에서 navigable
- 각 region 의 `aria-label` 이 keeper_id + intention 첫 80 char (truncate) — screen reader 가 의도 파악 가능

스타일: 기존 `inspector-keeper-bdi.tsx` 의 토큰 (`--sp-*`, `--fs-*`, `--ease-*`) 그대로 재사용 — 새 token 추가 없음.

## 6. Polling

- 5초 주기 (RFC 0024 §5 동기), per-keeper 독립 — 4 keeper 면 4 concurrent.
- visibility hidden 시 모두 정지 (`document.visibilityState !== 'visible'`).
- reduced-motion 시 update 시각 effect 즉시 (애니 없음).
- **Throttling**: cap=4 라 동시 5초 주기 = 0.8 fetch/sec. 단일 client 가 single-keeper-mode 5초 주기 = 0.2 fetch/sec → multi-mode 가 4× 부담. server 5s TTL cache 가 흡수하지만 **per-client request rate 가 client-side budget 안에 들어가는지 §11 open question**.
- Pin transition 시 immediate fetch (5초 기다리지 않음). debounce 50ms (rapid pin/unpin race 보호).

## 7. Token spend rollup

`recent_token_spend` 가 per-keeper 5턴 list. multi-pin 에서 두 가지 view:

### 7.1 Per-keeper

기존 RFC 0024 와 동일 — each entry 의 BDI panel 안에 5턴 list.

### 7.2 Cross-keeper rollup chip

inspector rail 헤더에 chip:

```
total_in: 47.3K · total_out: 18.2K · spike: keeper-c (12.4K out)
```

- `total_in / total_out` = 4 keeper 의 `recent_token_spend.tokens_in/out` 합.
- `spike` = 단일 turn 에서 가장 큰 token_out 을 낸 keeper_id (4 entries × 5 turns = 20 turn 중 max).

rollup 은 client-side 계산 (server-side aggregation 안 함 — RFC 0026 audit replay 가 long-window 는 owner).

## 8. ARIA

- root region: `role="region"` + `aria-label="multi-keeper inspector — {N} pinned"`
- per-keeper region: `role="region"` + `aria-label="keeper inspector — {keeper_id} — {intention?}"`
- BDI list (per keeper): RFC 0024 §6 그대로.
- update: `aria-live="polite"` + `aria-atomic="false"` (RFC 0024 §6 동기). 4 keeper 가 동시 update 해도 polite queue 에서 직렬 announce.
- pin/unpin/reorder: `aria-live` 없이 즉시 — focus 가 keeper region 에 있을 때 reorder 시 `aria-live="assertive"` 한 번 ("pinned keeper {label} moved to position {N}").

## 9. Test plan

- unit (`inspector-multi-keeper-bdi.test.ts`):
  - empty → single → 4 → cap-overflow LRU eviction
  - pin same keeper twice → reorder, no duplicate
  - drag reorder
  - offline keeper stale indicator
  - rollup chip math (total_in/out, spike detection)
- e2e (Playwright):
  - line click 4 different ownership → 4 pins
  - polling 5초 후 4 panel update
  - focus-mode toggle
  - reduced-motion + visibility-hidden behavior
- a11y (`jest-axe` + `axe-playwright`):
  - 4 nested region 이 keyboard navigable
  - aria-live polite queue 가 burst 시 직렬 announce
- perf (lighthouse-ci):
  - 4 keeper polling 시 main-thread blocking < 50ms / 5초 cycle

## 10. Migration from RFC 0024 single-pin

**Backward-compatible UI**: `entries.length <= 1` 경우 single-pin layout 을 그대로 렌더 → RFC 0024 의 e2e/snapshot 테스트가 cap=1 시나리오로 그대로 통과.

**State migration**: 기존 `keeper-pin-store.ts` (single keeper id 를 hold) → `multi-keeper-pin-store.ts` 로 import path 변경. v1 에 stored single pin 이 있으면 startup 에 entries=[그 keeper] 로 hydrate (localStorage 호환).

**Hook entry point**: `setPinnedKeeper(K)` 시그니처 유지 (single keeper id 받음) — internally existing K 를 먼저 제거한 뒤 `candidate = [entry(K, now), ...prev.filter(e => e.keeper_id !== K)]` 를 만들고, cap 초과 시 `pinned_at_ms` 가 가장 오래된 entry 를 drop. tie 면 minima 중 current UI order 에서 가장 뒤의 entry 를 drop. repeated pin 은 duplicate 없이 single entry 를 head 로 promote. v1 caller 변경 없음.

## 11. Open questions

1. **Cap=4 의 정당성**: 320px inspector rail + compact-fold 로 4 까지 fit. 사용자 측정 후 cap 조정 가능 (5 또는 6). v1.1 = 4 fixed; v1.2 에서 측정 후 결정.
2. **Per-client polling budget**: 4 keeper × 5초 = 0.8 fetch/sec → 5분에 240 fetch. server 5s TTL cache 가 흡수하지만 multi-tab open 시 곱빼기. **`document.visibilityState` 외에 idle detection (mouse / keyboard 30초 무활동) 으로 polling 일시 정지 검토**.
3. **AgentPresence 와의 cross-store 일관성**: pin 된 keeper 가 RFC 0008 AgentPresence 에서 연속해서 offline 되면 entries 자동 prune? 또는 stale 표시만 유지? **v1.1 = stale 표시만** (user gesture 로 unpin); auto-prune 은 v2 후보.
4. **Drag 와 RFC 0019 line click 의 priority**: drag 도중 line click 발생 시 line click 이 새 pin 추가 (head)? 또는 drag 완료 후 처리? **v1.1 = drag 우선 (line click ignore until mouseup)**.
5. **RFC 0021 anchored thread 와의 cross-link**: pin 된 keeper 가 anchored thread 의 author 면 thread rail 에 indicator 표시? cross-RFC 통합 검토 필요. **v1.1 = no integration**; RFC 0021 author 가 본 RFC 인지 후 필요 시 sub-RFC 분리.

## 12. References

- RFC 0008 — Agent Presence
- RFC 0012 — Keyboard Shortcuts (`Alt+ArrowLeft/Right`, `Alt+Enter`, `Esc`)
- RFC 0019 — Keeper Line Ownership
- RFC 0022 — IDE Plane Assembly v1 (parent)
- RFC 0024 — BDI Inspector Slot (extended)
- RFC 0026 — Audit Replay Timeline (long-window spend owner)
