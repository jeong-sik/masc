---
rfc: "0140"
title: "Dashboard Wire-Format Codec Layer"
status: Draft
created: 2026-05-19
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0135", "0139"]
implementation_prs: [16700]
---

# RFC-0140: Dashboard Wire-Format Codec Layer

## §0 한 줄 요약

Dashboard 가 backend OCaml 의 wire 데이터를 typed 형태로 받기 위한 *boundary parser* 와 *coverage guard* 가 모듈 단위로 흩어져 있는 현재 상태를, **단일 codec layer** 로 정합하여 새 wire vocabulary 추가 시 자동으로 backend↔frontend 1:1 매칭이 빌드 타임에 enforce 되도록 한다.

## §1 문제: boundary parsing 의 N-of-M 분산

2026-05-19 본 RFC 작성 시점, dashboard 의 *wire → typed* 변환 책임이 다음 모듈들에 흩어져 있음:

| 위치 | 책임 |
|---|---|
| `keeper-store-normalize.ts` | `toKeeperPhase`, `BACKEND_PHASE_LOWERCASE_MAP`, `normalizeKeeperAgentStatus` 외 12+ normalizer |
| `store-normalizers.ts` | `normalizeAgentStatus`, `normalizeTaskStatus`, `normalizeExecutionTone` 외 15+ |
| `mission-normalizers.ts` | mission-specific normalizer 5+ |
| `lib/runtime-blocker-class.ts` | `asKeeperRuntimeBlockerClass` |
| `lib/keeper-runtime-state.ts` | `asKeeperPauseState`, `asKeeperRuntimeBlockerState` |
| `lib/governance-risk-level.ts` | `asKeeperApprovalRiskLevel` |
| `lib/keeper-fiber-alive.ts` | `deriveFiberAlive` (typed decision) |
| `lib/keeper-blocker-reason.ts` | `deriveBlockerReason` (typed decision) |
| `api/board.ts`, `api/dashboard.ts` | `normalizeKeeperApprovalQueueItem` 외 |
| inline | `as string`, `asString().trim()` 단언 형식 ~30+ 사이트 |

본 *N-of-M abstraction* 패턴 (software-development.md AI 코드 생성 안티패턴 §3) 의 전형. 새 wire vocabulary 추가 시:

1. backend 가 새 OCaml variant 추가
2. frontend 는 *어떤 모듈* 에 typed union 추가? — 자명하지 않음
3. 1:1 매칭 guard 가 *부분만* 적용됨 (현재 `KeeperPhase` 와 `blocker_class` 만 build-time enforce)
4. 새 boundary parser 패턴 반복 작성 (caller=1 마다)

본 세션 (2026-05-19) audit 만 36 finding 중 typed sum drift 12, N-of-M 10. PR 흐름 (#16638, #16652, #16662, #16669, #16675, #16685, #16688, #16699) 도 *각 boundary 별로 별도 PR + 별도 모듈* 형태.

## §2 목표

| 정량 | 현재 | 목표 |
|---|---|---|
| boundary parser 모듈 수 | 7+ (분산) | 1 (codec layer) + thin per-domain re-export |
| backend↔frontend 1:1 build-time guard 영역 | 2 (KeeperPhase, blocker_class) | 모든 closed-enum boundary |
| inline `as string` / `asString` 의 wire-typed 단언 | ~30+ | <5 (외부 unknown 경계만) |
| 새 wire vocabulary 추가 시 frontend 작업 | 평균 3-4 site touch | 1 (codec schema entry) |
| typecheck PASS 후에도 *실제 drift* 가 머지될 수 있는가? | YES (catch-all 영역) | NO (closed unions only) |

## §3 비-목표

- backend OCaml 측 schema 표현 자체 변경 (OCaml type 정의는 그대로). dashboard 측 codec 만 다룸.
- runtime 동작 변경. 본 RFC 는 *컴파일 타임 invariant + 모듈 구조* 작업.
- 신규 wire field 추가. 기존 wire vocabulary 의 *typed 흡수* 만 책임.
- RFC-0135 / RFC-0139 등 기존 SSOT 의 *대체*. 본 RFC 는 그 RFC 들의 *집행 메커니즘* 통합.

## §4 설계: Codec Layer Skeleton

### §4.1 Schema 선언 형식

```ts
// dashboard/src/codec/schemas.ts (예시)

import { closedEnum, struct, optional } from './core'

export const KeeperPhaseCodec = closedEnum({
  name: 'KeeperPhase',
  // Backend SSOT: lib/keeper/keeper_state_machine.ml:6-19
  backend: ['offline', 'running', 'failing', 'overflowed', 'compacting',
            'handing_off', 'draining', 'paused', 'stopped', 'crashed',
            'restarting', 'dead', 'zombie'],
  frontend: ['Offline', 'Running', 'Failing', 'Overflowed', 'Compacting',
             'HandingOff', 'Draining', 'Paused', 'Stopped', 'Crashed',
             'Restarting', 'Dead', 'Zombie'],
  toFrontend: (raw) => /* exhaustive mapping */,
})

export const KeeperApprovalRiskLevelCodec = closedEnum({
  name: 'KeeperApprovalRiskLevel',
  // Backend SSOT: lib/governance_pipeline_types.ml:1-18
  backend: ['low', 'medium', 'high', 'critical'],
  frontend: ['low', 'medium', 'high', 'critical'],
  toFrontend: (raw) => raw,
})
```

`closedEnum<B, F>()` 는 다음을 *컴파일 타임* 으로 guarantee:

1. `B` (backend strings) 가 `as const` tuple → typed union
2. `F` (frontend) 가 `as const` tuple → typed union
3. `toFrontend` 가 *exhaustive* — backend 의 모든 variant 가 frontend 의 한 variant 로 매핑
4. coverage check: `Exclude<F, ReturnType<toFrontend>>` = never 미충족 시 typecheck fail
5. parser 자동 생성: `KeeperPhaseCodec.parse(unknown)` → `KeeperPhase | null`

### §4.2 Struct codec — JSON 객체

```ts
export const KeeperApprovalQueueItemCodec = struct({
  id: nonEmptyString,
  keeper_name: nonEmptyString,
  tool_name: nonEmptyString,
  risk_level: KeeperApprovalRiskLevelCodec,
  requested_at: optional(isoTimestamp),
  // ...
})
```

기존 `normalizeKeeperApprovalQueueItem` (api/board.ts:63) 가 declarative codec 으로 흡수. 새 field 추가 시 schema 만 update.

### §4.3 Typed decision (provenance preserving)

본 세션 의 `deriveFiberAlive` / `deriveBlockerReason` 같은 *priority-fallback decision* 도 codec 의 일급 시민:

```ts
export const FiberAliveDecisionCodec = priorityFallback({
  name: 'FiberAlive',
  sources: [
    { key: 'composite_phase_diagnosis', read: (c) => c.composite?.phase_diagnosis?.conditions.fiber_alive, type: 'boolean' },
    { key: 'keepalive_running', read: (c) => c.keeper.keepalive_running, type: 'boolean' },
    { key: 'presence_keepalive', read: (c) => c.keeper.presence_keepalive, type: 'boolean' },
    { key: 'link_state_inference', read: (c) => c.linkedState !== 'offline', type: 'derived' },
  ],
})
```

자동 생성: `FiberAliveDecisionCodec.derive({ keeper, composite, linkedState })` → `FiberAliveDecision`. `source` field 가 first-class — 본 세션 의 `deriveFiberAlive` / `deriveBlockerReason` 가 같은 codec 의 instance.

### §4.4 Backend coverage guard (자동)

기존 *수동 mirror* (A1 #16662, #16675) 가 codec schema 의 *자동 산출물*:

```ts
type BackendKeeperPhase = typeof KeeperPhaseCodec.backend[number]
type _Coverage = Exclude<BackendKeeperPhase, keyof typeof KeeperPhaseCodec.toFrontend>
const _COVERAGE: [_Coverage] extends [never] ? true : _Coverage = true
```

새 backend variant 추가 시 codec 의 `backend` tuple 만 update. `_COVERAGE` 가 typecheck 통과 못 함 → frontend 누락 즉시 발견.

## §5 PR 시퀀스 (incremental migration)

| PR | 변경 | 의존 | 닫는 audit |
|---|---|---|---|
| **PR-1** | `dashboard/src/codec/core.ts` 신설 — `closedEnum`, `struct`, `priorityFallback` 등 codec primitive. 신규 모듈만, caller 0. | 없음 | 기반 — 후속 PR 의 정의처 |
| **PR-2** | `KeeperPhaseCodec` declaration + 기존 `BACKEND_PHASE_LOWERCASE_MAP` (A1) 흡수. `toKeeperPhase` 가 codec 호출로 위임. | PR-1 | A1 통합 |
| **PR-3** | `KeeperRuntimeBlockerClassCodec` + 기존 `KEEPER_RUNTIME_BLOCKER_CLASSES` (F5/#16638/#16675) 흡수. | PR-1, PR-2 패턴 follow | 24-arm audit 통합 |
| **PR-4** | `KeeperPauseStateCodec` + `KeeperRuntimeBlockerStateCodec` (F1) + `KeeperApprovalRiskLevelCodec` (F4) 흡수. | PR-1 | F1, F4 통합 |
| **PR-5** | `FiberAliveDecisionCodec` (A2) + `BlockerReasonDecisionCodec` (A3) — priority-fallback codec primitive 적용. | PR-1 | A2, A3 통합 |
| **PR-6** | `KeeperApprovalQueueItemCodec` (struct) + `api/board.ts:normalizeKeeperApprovalQueueItem` 흡수. | PR-4 | api boundary 흡수 시작점 |
| **PR-7** | 4 normalizer 모듈 (`keeper-store-normalize`, `store-normalizers`, `mission-normalizers`, `api/dashboard.ts`) 의 closed-enum normalizer 들 → codec 위임. | PR-2~5 | N-of-M 분산 종결 |
| **PR-8** | `inline as string` / `asString` 사이트 audit + codec 으로 이주. | PR-6, PR-7 | catch-all 잔존 site 종결 |
| **PR-9** | CI guard — `scripts/lint/dashboard-codec-coverage.sh`: backend OCaml `_to_string` 함수 list 와 codec schema 의 `backend` tuple 1:1 매칭 검증. | PR-2~8 | 회귀 방지 |

각 PR < 400 LoC 목표 (PR-1 만 ~600 LoC 예상, primitive + 테스트). PR-2~5 는 모두 *동일 패턴* 의 자기복제이므로 단일 reviewer 가 빠르게 검토 가능.

## §6 비기능 요건 / 테스트

- **PR-1 primitive 테스트**: 모든 codec primitive 의 *coverage check fail* 케이스를 type-level test 로 확인. `// @ts-expect-error` block 으로 backend tuple 만 추가 시 typecheck 실패 보임.
- **PR-2~5 가 *행동 동등* 임을 증명**: 기존 normalizer 의 test fixture 가 codec 위임 후에도 모두 PASS.
- **PR-9 CI guard 가 *실제 drift 잡음***: 임시로 backend variant 1 개 추가 + frontend 미갱신 시 CI red.

## §7 마이그레이션 / 호환성

- 기존 normalizer 함수 시그니처 그대로 export (PR-2~7). caller 는 *내부 구현만 codec 위임* 이라 변경 없음.
- 기존 typed parser 모듈 (`lib/runtime-blocker-class.ts`, `lib/keeper-runtime-state.ts`, `lib/governance-risk-level.ts`, `lib/keeper-fiber-alive.ts`, `lib/keeper-blocker-reason.ts`) 가 codec 위임 thin wrapper 로 축소. 5+ sprint 후 *직접 codec 호출* 로 caller migration 시 deletion.
- 신규 boundary 추가 시 PR-1 의 primitive 직접 사용 — 별도 lib/ 모듈 신설 안 함.

## §8 Related work / cross-reference

- **RFC-0135** — Dashboard Keeper Operational Surface — typed SSOT 의 9 PR sequence. 본 RFC 의 *backend↔frontend boundary* 슬라이스.
- **RFC-0139** — Agent Status Vocabulary SSOT (#16698 머지). 본 RFC 의 한 적용 사례.
- **A1 #16662** — `BACKEND_PHASE_MAP` coverage check. 본 RFC 의 §4.4 가 일반화.
- **#16675** — `keeper_meta_contract blocker_class` 24-arm 1:1 guard. 본 RFC 의 §4.4 가 일반화.
- **#16685 (A2)**, **#16699 (A3)** — typed decision 패턴. 본 RFC 의 §4.3 이 일반화.
- **#16652 (F1)**, **#16669 (F2)**, **#16688 (F4)** — 개별 boundary 약화 closure. 본 RFC 가 통합 메커니즘.

## §9 거부 기준 (선언적 — CI guard 로 enforce, PR-9)

본 RFC 머지 후 다음 PR 은 머지 거부 (workaround 거부 기준 §"누적 메커니즘"):

1. **`| string` catch-all 추가**: closed enum union 에 `| string` 또는 등가 약화 → typecheck fail (codec primitive 가 reject)
2. **새 boundary parser 모듈 신설**: PR-1 의 primitive 가 cover 하는 패턴은 codec 호출로만 정의. 새 `lib/keeper-XXX.ts` 만들지 말 것.
3. **backend↔frontend 1:1 미증명**: closed enum 보유 wire field 가 codec schema 등록 없이 inline narrowing → PR-9 lint fail.
4. **`as string` 단언**: codec 외부에서 typed wire 값 단언 금지. unknown 경계는 `codec.parse(unknown)` 만.

## §10 Implementation Notes

- 본 RFC 의 codec primitive 는 *zod-style fluent API* 또는 *atd-style declarative* 사이 선택. PR-1 진입 전 prototype 1 페이지로 비교 후 결정. 둘 다 build-time enforce 가능.
- TypeScript 의 `satisfies` + tuple `as const` + conditional types 만으로 *런타임 의존성 0* 구현 가능. zod 도입은 별도 결정.
- backend OCaml `_to_string` 함수 list 를 dump 하는 stand-alone OCaml binary (lib/dev_tools/dump_wire_vocab.ml 같은) 가 PR-9 의 CI guard data source.

## §11 Risk / Open Questions

1. **Migration cost**: 기존 N=40+ normalizer site 의 codec 위임 cost. PR-7 가 가장 큰 변경. 분할 (3-4 sub-PR) 권장.
2. **Codec primitive API 결정**: zod-style runtime validation 함께 도입 시 *dashboard bundle size* +20kB 가능. dashboard 가 internal-only 라 허용 가능성 높지만 stripped primitive (type-only + minimal runtime) 도 옵션.
3. **OCaml `_to_string` extraction 자동화**: PR-9 의 CI guard 가 OCaml AST 파싱 또는 단순 regex 로 충분한지. 단순 regex 시 false negative 위험 — PR-9 spec 시 결정.
4. **신규 backend variant ↔ codec schema sync delay**: backend PR 머지 후 frontend codec 업데이트 PR 전까지 typecheck red. CI 가 *backend PR 머지 trigger frontend PR creation* 자동화 가능성 — 별도 RFC 후보.
5. **본 RFC 와 RFC-0135 PR-8 (backend `effective_blocker`)** 의 ordering: PR-8 가 wire schema 변경. 본 RFC 의 codec migration 이 *그 변경을 가장 빠르게 흡수할 수 있는 형태* 여야 함.

## §12 변경 이력

- 2026-05-19 — Draft 초안. 본 세션 dashboard SSOT audit 결과 (typed drift 12, N-of-M 10, 하드코딩 18, IA/UX 15) 가 본 RFC 의 evidence base. P1~P2 PR 군 (#16638, #16652, #16662, #16669, #16675, #16685, #16688, #16699) 의 *분산 패턴* 이 본 RFC 의 *통합 동기*.
