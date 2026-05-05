# RFC 0024 — BDI Inspector Slot (extends RFC 0019)

- **Status**: Draft
- **Author**: Vincent + Claude (auto mode 2026-05-05)
- **Created**: 2026-05-05
- **Extends**: RFC 0019 (Keeper Line Ownership)
- **Depends on**: RFC 0008 (AgentPresence), RFC 0019
- **Parent RFC**: RFC 0022 (IDE Plane Assembly v1)
- **GitHub Issue**: #13199

---

## 1. Motivation

editor 에서 line click → 그 line 의 keeper id (RFC-0019 ownership) 가 결정된다. 그 다음 단계가 비어 있다 — keeper 의 *현재 의도* 를 모른다. Cognition plane (`cb-group-h.jsx::KeeperBDIPanel`) 이 BDI(belief / desire / intention) snapshot 을 표시하지만 *별도 plane 으로 이동* 해야 본다.

inspector rail 우측에 keeper-pin slot 을 두면 line 의 keeper 를 *읽을 때* 그 의도를 같이 본다. memory `reference_masc_keeper_memory_reinjection_path` 의 self-reinforcement chain 을 IDE 에서 추적.

## 2. Non-Goals

- BDI snapshot 자체 정의 (`lib/keeper_status_bridge` 가 owner)
- BDI mutating action (read-only)
- multi-keeper compare view (single pin only; multi 는 별도 RFC)

## 3. Public API

### 3.1 BDI snapshot shape

```ts
// dashboard/src/components/ide/keeper-bdi-store.ts
export interface KeeperBDISnapshot {
  readonly keeper_id: string
  readonly belief: ReadonlyArray<string>        // 최대 5 entries
  readonly desire: ReadonlyArray<string>        // 최대 3 entries
  readonly intention: string | null             // 단일 statement
  readonly recent_token_spend: ReadonlyArray<{
    readonly turn_id: string
    readonly tokens_in: number
    readonly tokens_out: number
    readonly ts_ms: number
  }>                                            // 최근 5턴
  readonly last_tool_call: {
    readonly name: string
    readonly args_summary: string
    readonly result_kind: 'ok' | 'err' | 'pending'
    readonly ts_ms: number
  } | null
  readonly snapshot_ts_ms: number
}
```

### 3.2 REST endpoint

```
GET /api/dashboard/keeper-bdi/<keeper_id>
```

returns `KeeperBDISnapshot`. cache 5초 TTL (RFC-0008 update cadence 와 동기).

### 3.3 Inspector slot component

```tsx
// dashboard/src/components/ide/inspector-keeper-bdi.tsx
interface Props {
  readonly keeperId: string | null
  readonly onUnpin: () => void
}
```

placement: `ide-shell.ts` 의 우측 영역, `IxPrHeader` / `IxPrChecks` 같은 슬롯 옆.

## 4. Pin behavior

- editor line click → ownership store 조회 → `setPinnedKeeper(ownership.keeper_id)`
- pin 변경은 명시 (auto-pin 옵션은 default off; user gesture only)
- unpin: slot 의 X 버튼 또는 `Esc` (RFC-0012 keyboard shortcuts)
- 다른 line 같은 keeper → no-op (이미 pin)

## 5. Polling

- 5초 주기 (`useEffect` cleanup with cancellation token)
- visibility hidden 시 정지 (`document.visibilityState !== 'visible'`)
- reduced-motion 시 update 시각 effect 즉시 (애니 없음)

## 6. ARIA

- slot region: `role="region"` + `aria-label="keeper inspector — {keeper_id}"`
- BDI list: `role="list"` + `aria-label="beliefs, {N}"` 등
- update: `aria-live="polite"` + `aria-atomic="false"` (Toast 패턴 참조)

## 7. Test plan

- unit: `inspector-keeper-bdi.test.ts` — empty pin, populated, polling lifecycle
- e2e: line click → pin → 5초 후 update 확인 (Playwright)
- a11y: `jest-axe`

## 8. Open questions

1. **BDI 미생성 keeper**: legacy keeper 또는 새 keeper 가 BDI 를 갖지 않을 수 있음 → fallback "no BDI snapshot · {snapshot_ts_ms}" 표시.
2. **spend window**: 5턴 vs 시간기반 (10분) — 작업 burst 시 5턴이 1분 미만일 수도. v1 5턴 fixed; 측정 후 조정.
