---
id: RFC-0083
title: Dashboard system-actor convention typed unification
status: draft
created: 2026-05-15
authors: ["@yousleepwhen"]
related: ["RFC-0077"]
---

## Problem

`/goal` series (PR #15303~#15344, 18 PRs)으로 dashboard hardcoded value-level literal은 모두 박멸했으나 **type-level `'system'` literal**이 26 file에 분산 잔존:

```
src/types/core.ts:                  KeeperConversationRole = ... | 'system' | ...
src/types/core.ts:                  KeeperConversationSource = ... | 'system' | ...
src/types/core.ts:                  post_kind?: 'direct' | 'automation' | 'system'
src/types/sse.ts:                   kind?: ... | 'system' | 'oas'
src/live-store.ts:                  LiveFilterKind = 'broadcast' | 'tasks' | 'keepers' | 'system'
src/live-store.ts:                  new Set(['broadcast', 'tasks', 'keepers', 'system'])
src/store.ts:                       new Set(['system'])  // boardHiddenCategories
src/api/board.ts:                   rawKind === 'system'
src/sse.ts:                         addTypedJournalEntry(..., 'system', ...)  // 5 sites
src/mission-normalizers-entities.ts: origin_kind === 'system' ? 'system' : 'human'
... 16 more files
```

이 literal은 *backend semantic convention*:
- "system" = system-originated entry actor (사용자/agent와 구분되는 system 발신자)
- type union member, equality narrowing, Set 멤버십, FilterKind 분기 등 다양 사용처

각 sites는 *동일 의미*를 *literal 반복*으로 표현 — Magic 룰 위반이나 *agent 직접 박멸*은 *시맨틱 위험*:

| 위험 | 사유 |
|---|---|
| Type union 변경 | `'system'`을 constant로 binding하면 union member 변경, TypeScript compile-time enumeration 의미 변경 |
| Cross-file dependency | `types/core.ts → 26+ caller files` 의존성 추가 (cycle 위험) |
| Backend contract 변경 | JSON payload의 `"role": "system"` 등 backend와의 wire format 영향 가능 |

PR #15341 (SYSTEM_ACTOR_NAME constant)은 **3 fallback site만** 박멸 (`?? 'system'`). type-level + equality + Set 멤버십은 *intentional convention*으로 분류하여 유지.

## Proposal

`'system'` literal을 *typed branded value*로 통일:

```typescript
// src/types/core.ts
export const SYSTEM_ACTOR_NAME = 'system' as const
export type SystemActorName = typeof SYSTEM_ACTOR_NAME

// usage
type KeeperConversationRole = 'user' | 'assistant' | SystemActorName | 'tool' | 'other'
```

`as const` typed alias로 literal 값 보존 + 사용처 모두 named binding. TypeScript 컴파일 결과 *동일 wire format* (`"system"` string), 백워드 호환.

### Migration plan

| Phase | 작업 | 위험 |
|---|---|---|
| 1 | `SYSTEM_ACTOR_NAME` + `SystemActorName` export (PR #15341에 이미 부분 처리) | None |
| 2 | Type union member 26 file replacement | Cross-file dependency, *compile-time only impact* |
| 3 | Equality narrowing site replacement (`rawKind === SYSTEM_ACTOR_NAME`) | None |
| 4 | Set membership site replacement | None |
| 5 | `addTypedJournalEntry(..., SYSTEM_ACTOR_NAME, ...)` | None |
| 6 | Backend wire format audit (JSON serialization 영향 없음 검증) | Backend contract |

각 phase 별도 PR 권장 (사용자 리뷰 단위).

## Alternatives considered

### A. Keep current state (intentional convention)
- *근거*: 'system' literal이 backend convention. type-level enumeration 자체가 의도된 SSOT.
- *단점*: Magic 룰 외 ambiguity. value-level 사용처와 type-level 사용처 *동일 string*인지 의도된 구분인지 불명.

### B. Branded type (current proposal)
- *장점*: typed binding, IDE auto-complete, 단일 변경 지점.
- *단점*: 26 file migration, cross-file dependency.

### C. Backend rename ('system' → '__system__' or similar)
- *장점*: 명시적 reserved marker.
- *단점*: Backend wire format 변경 (heavy refactor), backwards-compat layer 필요.

## Recommendation

**Defer**. PR #15341 (fallback constant)이 *agent-actionable* 범위. Type union member 통합은:
- High effort (26 file)
- Low ROI (compile-time only, runtime wire format 동일)
- Risk of accidental backend contract drift

사용자가 명시적으로 typed unification 추진 결정 시 본 RFC를 Phase 1부터 실행. 그 전에는 *intentional convention*으로 유지.

## Related

- PR #15341 (SYSTEM_ACTOR_NAME constant, 3 fallback site 박멸)
- RFC-0077 (Write-side silent failure typed) — silent failure family 박멸 사상 공유
- `/goal series` (PR #15303~#15344, dashboard hardcoded literal 박멸 18 PRs)

## Open questions

- Backend contract가 `"role": "system"` wire format을 *enum-coded value*로 유지하는가, 또는 *opaque string*로 유지하는가? Backend 측 review 필요.
- `boardHiddenCategories: new Set(['system'])` 같은 configuration set이 *runtime user-mutable*인가, *compile-time literal config*인가? Mutability 검토 필요.

## Decision

- **Defer**: 본 RFC는 향후 사용자가 type-level enumeration 통합을 추진 결정 시 시작.
- 본 RFC 작성 시점 dashboard hardcoded-fallback removal sweep은 *agent-actionable 범위* (~200 site, 18 PR) 완료.
