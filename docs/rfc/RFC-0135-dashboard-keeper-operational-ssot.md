---
rfc: "0135"
title: "Dashboard Keeper Operational Surface — Typed SSOT"
status: Implemented
created: 2026-05-19
updated: 2026-05-22
author: vincent
supersedes: []
superseded_by: null
related: ["0004", "0029", "0088", "0133", "0139"]
implementation_prs: [16573, 16576, 16593, 16600, 16606, 16611, 16615, 16619, 16623, 16626, 16632, 16638, 16662, 16663, 16672, 16680, 16683, 16685, 16687, 16689, 16691, 16695, 17075]
---

## Progress audit (2026-05-21)

Status promoted Draft → Active. 23 implementation PRs landed against
the §10 9-PR phased rollout. This audit does *not* re-map each of
the 23 PRs to its phase slot — the work is the largest active sprint
in the repo (~25 commits referencing RFC-0135 since 2026-04-01, the
top of `audit-rfc-closeout-lag.sh` output) and the sprint author is
the right person to issue an authoritative Phase→PR table at the
sprint closeout, not a sweep audit.

The unambiguous observations made here:

- 23 PRs is consistent with the §10 plan running past its original
  9-PR scope (PR-1..PR-9 nominal + Goal-1 / Goal-2 / §13 attention
  axis sub-PRs visible in the commit log, e.g. #16763 §13, #16772
  Goal-1 keeperBand, #17075 Goal-2 remaining axes).
- PR-9 CI guard lint `scripts/lint/dashboard-ssot-keeper-state.sh`
  is wired (confirmed against origin/main `scripts/lint/` listing).
- A parallel `feature/RFC-0135-goal2-remaining-axes` worktree
  exists, indicating in-flight follow-up work — Draft is no longer
  the accurate status, but Implemented cannot be claimed until the
  sprint author closes out the Goal-2/§13 follow-ups.

`Active` is the smallest defensible status change. The Phase→PR
mapping table, §5 acceptance verification, and final
Implemented/closeout flip remain author responsibilities.

### Sister RFC

- **RFC-0139** (Agent Status Vocabulary SSOT, Active 2026-05-21):
  same audit cohort. RFC-0139 explicitly cites itself as
  "RFC-0135 closure 후속". Bidirectional link added to `related:`.

---

# RFC-0135: Dashboard Keeper Operational Surface — Typed SSOT

## §0 한 줄 요약

Dashboard 가 keeper 운영 상태를 표시할 때 같은 wire field 를 화면별로 *다른 derivation* 으로 해석하여 운영자에게 모순된 정보를 노출하는 문제를, *single typed sum* 정규화 SSOT 와 *label noun/verb 분리* 로 해결한다.

## §1 문제: 3 사례

### §1.1 목록 vs 상세 — 같은 keeper, 정반대 상태 (2026-05-19 관찰)

`lifecycle-worker` 한 keeper 가:

- **목록 카드** (`dashboard/src/components/agent-roster.ts:87-116` `rosterStateNote`) → `현재 차단 · synthetic_stall`
- **상세 LIVE TRUTH** (`dashboard/src/components/keeper-detail-runtime.ts:168-301` `deriveKeeperLiveTruth`) → `턴 진행 중 · fiber alive · executing live`

같은 keeper wire payload 에서 두 화면이 반대 결론. 목록은 `keeper.runtime_blocker_class` flat 읽기만, 상세는 `composite.runtime_attention.execution_current` 로 conditioning 후 stale blocker 무시.

### §1.2 단어 collision — 같은 행에 "일시정지" 2회 (Command/Actions 화면)

`dashboard/src/components/keeper-action-panel.ts:160-200` 의 row 가 같은 한국어 단어를 두 역할로 동시에 표시:

- KeeperPhaseBadge (line 162): paused phase → `⏸ 일시정지` (state)
- 보조 span (line 163-165): paused=true → `일시정지` (state, *중복*)
- 액션 버튼 (line 183): `pause` verb → `일시정지` (verb)

`status-label.ts:33-34` 의 SSOT 매핑이 `paused` 상태와 `pause` 동사를 같은 한국어로 collapse → 의도된 SSOT 가 *오히려 collision 을 봉인*.

### §1.3 액션 verb 의미 미설명

`keeper-action-panel.ts:82-128` `keeperActionVisibility` 의 `canWake` 분기:

```ts
canWake: isStuck || (isRunning && !isPaused)
```

정상 running 상태에서도 `깨우기` 버튼이 표시됨. 운영자는 코드 안 보고는 `pause/resume/wakeup/boot/shutdown` 5 verb 의 사전조건/효과 구별 불가.

### §1.4 wire field ortho 가정 깨짐

같은 keeper 가 동시에 `phase=paused` + `status=inactive` 로 emit 되어, `canBoot = isOffline` 와 `canResume = isPaused` 가 동시에 true. echo 행이 `[⏸ 일시정지]` badge + `[기동] [재개] [종료]` 3 버튼을 동시에 보임.

### §1.5 evidence inventory (audit 결과, 2026-05-19)

#### §1.5.1 Wire field dual-path — 5 conflict clusters

| Cluster | 사이트 | 문제 |
|---|---|---|
| **C1 Phase casing 3-맵 중복** | `keeper-store-normalize.ts:35-69` `BACKEND_PHASE_MAP` / `keeper-state-diagram.ts:42-69` `PHASE_ID_MAP` / `monitoring-runtime.ts:159-180` `normalizePhase()` | 같은 의미의 phase casing map 이 3 곳에 *cross-reference 없이* 존재 |
| **C2 Status refinement fork** | `keeper-runtime-display.ts:124-166` `refineOfflineStatus()` 호출 / `monitoring-runtime.ts:214-235` `keeperBand()` 직접 read | 같은 keeper 가 fleet 에서 `offline`, detail 에서 `unbooted` 로 표시 |
| **C3 Paused AND/OR 4 중 chain** | `keeper-action-panel.ts:112-113` / `dashboard-shell.ts:168-173` `keeperLooksPaused()` / `monitoring-runtime.ts:214-215` `keeperBand()` / `keeper-reactivity-monitor.ts:191-192` `isKeeperPaused` | 4 함수가 각자 `paused | phase==='Paused' | stage==='paused' | status==='paused'` OR 분기 |
| **C4 Runtime blocker class enum 직접 read** | `keeper-action-panel.ts:117-119` / `keeper-detail-alert-strip.ts:335` / `keeper-runtime-display.ts:235-318` | 3 곳이 `runtime_exhausted/oas_timeout_budget/turn_timeout` 를 inline check, 통일된 predicate 부재 |
| **C5 Composite vs keeper field fallback** | `keeper-detail-runtime.ts:180-194` (`composite.phase ?? keeper.phase ?? keeper.status`) / `keeper-state-diagram.ts` (composite 무시) | RFC-0046 의도 (`composite` = SSOT) 가 fallback 으로 우회 |

#### §1.5.2 Noun/verb label collision matrix

| 한국어 어근 | state 사이트 | verb 사이트 | 동일 row 가시 | 심각도 |
|---|---|---|---|---|
| **일시정지** | `keeper-phase-indicator.ts:56` (Paused badge) | `keeper-action-panel.ts:52,183` (pause button + title) + line 164 보조 span | ✓ | CRITICAL |
| **종료** | `keeper-phase-indicator.ts:55,60` (Dead/Draining: `종료`/`종료중`) | `keeper-action-panel.ts:56,210` (shutdown) + `keeper-detail-lifecycle.ts:43,62` | ✓ | CRITICAL |
| **기동** | `keeper-lifecycle-timeline.ts:60` (lifecycle event `기동됨`) | `keeper-action-panel.ts:55,174` (boot button) | ✓ | HIGH |
| **재개** | `keeper-lifecycle-timeline.ts:72` (`자동 재개됨`) | `keeper-action-panel.ts:53,192` (resume button) | ✓ | HIGH |
| **차단됨** | `status-label.ts:39` (blocked) + `keeper-detail-alert-strip.ts:373,382` | `keeper-detail-runtime.ts:295` (row label) + `runtime-config-panel.ts:917` | adjacent | MEDIUM |
| **깨우기** | — | `keeper-action-panel.ts:54,201` (wakeup button) | — | LOW |

PR #16562 vocab outlier alignment (`정지`/`일시 중지` → `일시정지`) 가 *state 명사 alignment* 만 처리. *state↔verb 분리* 는 본 RFC §3 의 작업.

#### §1.5.3 Derivation function 중복 그래프

12 derivation 함수 (7 파일) 중 6 duplication 쌍 식별:

1. **blocked/attention verdict**: `deriveKeeperLiveTruth:192-194` (composite-aware) vs `rosterStateNote:95-107` (flat-only) — `rosterStateNote` 가 `composite` 인자 자체를 **안 받음** → §1.1 사례의 근본 원인.
2. **paused 판정**: `keeperActionVisibility:112-113` vs `isKeeperPaused:191-192` — 같은 로직 함수만 분리.
3. **phase tone**: `keeperStateTone:101` vs `KeeperPhaseBadge:66-69` `PHASE_STYLES` — 같은 truth, 다른 shape.
4. **offline detection**: `keeperActionVisibility:92-98` 수동 phase 체크 vs `keeper-runtime-display` `isOfflineStatus()` — utility 미사용.
5. **blocker reason 추출**: `deriveKeeperLiveTruth:232-238` fallback chain vs `rosterStateNote:95-96` 단순 trim.
6. **lifecycle event meta**: `lifecycleEventTone:38` + `lifecycleEventLabel:58` — 같은 lookup 2 함수 분리.

## §2 Typed Sum SSOT — `KeeperOperationalState`

신규 모듈 `dashboard/src/lib/keeper-operational-state.ts` 에 *closed sum* 으로 keeper 운영 상태를 정의한다. 모든 dashboard 화면은 이 sum 에서만 분기한다.

```ts
type BlockerReason =
  | 'synthetic_stall'
  | 'runtime_exhausted'
  | 'oas_timeout_budget'
  | 'turn_timeout'
  | 'heartbeat_failures'
  | 'completion_contract_violation'
  // ... audit 결과 후 확정 (catch-all 금지)

type TurnPhase = 'idle' | 'executing' | 'compacting' | 'handing_off'

type KeeperOperationalState =
  | { kind: 'offline'; reason: 'unbooted' | 'crashed' | 'shutdown' }
  | { kind: 'running'; turn: TurnPhase; blocker: null }
  | { kind: 'running'; turn: TurnPhase; blocker: BlockerReason } // execution fresh but blocker conditioning shows stale signal — typed 아래서 *명시적으로* 동시 표현
  | { kind: 'paused'; cause: 'operator' | 'auto_recover' | 'liveness_guard' }
  | { kind: 'stuck'; reason: BlockerReason } // fiber alive 아니거나 turn evidence stale + blocker class set

export function deriveKeeperOperationalState(
  keeper: Keeper,
  composite: KeeperCompositeSnapshot | null,
): KeeperOperationalState
```

조건 매트릭스 (wire field → state):

| `paused` | `status`/`phase` | `composite.execution_current` | `runtime_blocker_class` | → state |
|---|---|---|---|---|
| true | * | * | * | `paused` |
| * | offline/inactive/crashed | * | * | `offline` |
| false | active/running | true | null | `running { turn=…, blocker=null }` |
| false | active/running | true | set | `running { turn=…, blocker=…}` (stale blocker, execution 신뢰) |
| false | active/running | false | set | `stuck { reason=…}` |

derivation 함수는 *exhaustive*. 새 wire 변형이 추가되면 컴파일 에러로 잡힘.

## §3 Label noun/verb 분리

`status-label.ts` 를 두 함수로 분리한다 — **하나의 한국어 단어가 두 의미를 가질 수 없게**.

```ts
// 상태 라벨 (명사형, 색/아이콘 같이)
export function stateLabel(state: KeeperOperationalState): {
  text: string
  tone: 'ok' | 'neutral' | 'warn' | 'bad'
  icon: string
}
//   running   → "실행중"      (🟢)
//   paused    → "일시정지됨"  (🟡 ⏸)
//   stuck     → "차단됨"      (🔴 ⛔)
//   offline   → "오프라인"    (⚫)

// 액션 라벨 (동사형 — 접미사 "하기" 또는 단독 아이콘)
export function actionLabel(verb: KeeperActionVerb): {
  text: string
  icon: string
}
//   pause     → "일시정지하기" (⏸)
//   resume    → "재개하기"     (▶)
//   wakeup    → "깨우기"       (⚡)
//   boot      → "기동하기"     (🚀)
//   shutdown  → "종료하기"     (⏏)
```

UI 가이드라인:

1. *상태* 자리에는 `stateLabel` 만, *액션 버튼* 자리에는 `actionLabel` 만 사용.
2. 같은 row 에 같은 *어근* (`일시정지` 등) 단어가 보이더라도 *접미사* / *아이콘* / *색* 으로 시각 분리 강제.
3. tooltip 의무 — 모든 action 버튼은 "사전조건: X, 효과: Y" 형태의 한국어 설명을 `title` attribute 로 노출.

## §4 Backend wire conditioning

Dashboard 단독 fix 는 dual-path 의 한쪽만 정렬한다. Backend 가 *post-conditioned* 필드를 emit 해야 진정한 SSOT.

신규 wire 필드:

```
effective_blocker: BlockerReason | null
```

규칙: `execution_current == true` 면 `effective_blocker = null` 로 강제. dashboard 는 `runtime_blocker_class` 직접 읽기를 deprecate 하고 `effective_blocker` 만 본다.

§9 거부 기준 #1 (워크어라운드 시그니처 #1 — flat string-as-truth) 회피 보장.

## §5 PR 시퀀스 (audit-driven)

| PR | 내용 | 의존 | 해소되는 cluster / 사례 |
|---|---|---|---|
| **PR-1** | `dashboard/src/lib/keeper-operational-state.ts` 신설 — typed sum + `deriveKeeperOperationalState(keeper, composite)` 함수 + 100% wire fixture → state 매트릭스 테스트. `BlockerReason` variant 는 `lib/keeper/` 의 실제 enum 을 grep 하여 확정. | 없음 | 기반 — 이후 PR 의 단일 호출처 |
| **PR-2** | Phase casing SSOT 통합 — `keeper-state-diagram.ts` `PHASE_ID_MAP` + `monitoring-runtime.ts` `normalizePhase()` 를 `keeper-store-normalize.ts` `toKeeperPhase()` 호출로 치환. 중복 맵 삭제. | PR-1 | **C1** Phase casing 3-맵 |
| **PR-3** | `dashboard/src/lib/keeper-predicates.ts` 신설 — `isKeeperPaused`, `isKeeperOffline`, `keeperBlockerKind`, `keeperCanWakeup` SSOT. `keeper-action-panel.ts:112-113` / `dashboard-shell.ts:168-173` / `monitoring-runtime.ts:214-215` / `keeper-reactivity-monitor.ts:191-192` 가 모두 import. | PR-1 | **C3** Paused 4-중 chain, **C4** Blocker enum 3-중 read |
| **PR-4** | `agent-roster.ts:rosterStateNote` 시그니처를 `(keeper, composite, monitoringHint)` 로 변경. `composite.runtime_attention` 으로 conditioning 후 typed state 호출. `runtime_blocker_summary` flat read 제거. | PR-1 | **§1.1** 목록↔상세 일치, **C5** composite fallback |
| **PR-5** | `keeper-detail-runtime.ts:deriveKeeperLiveTruth` 가 typed state 호출. line 188-194 inline conditioning 제거. `keeper-detail-alert-strip.ts` 의 verdict 도 같은 state 사용 (PR #16555 typed verdict scope 와 통합). | PR-1, PR-4 | **C2** Status refinement fork, **C5**, 헤더 strip 일관성 |
| **PR-6** | `keeper-action-panel.ts` typed state 기반 visibility 재작성, line 164 중복 `<span>일시정지</span>` 제거, 각 버튼에 사전조건/효과 tooltip 추가. | PR-1, PR-3 | **§1.2** echo 행 "일시정지/일시정지", **§1.3** wakeup 의미 미설명 |
| **PR-7** | `status-label.ts` 를 `stateLabel(state)` / `actionLabel(verb)` 두 함수로 분리. 액션 verb 라벨에 한국어 접미사 `하기` 또는 icon-only 적용 (`pause: '일시정지하기' | ⏸`). 모든 verb-site call site 업데이트. | PR-1, PR-6 | **§1.5.2** noun/verb collision matrix 전체 (CRITICAL 2 + HIGH 2) |
| **PR-8** | Backend `effective_blocker: BlockerReason | null` post-conditioned 필드 + `runtime_blocker_class` deprecated 마킹 (`lib/keeper/`). dashboard 의 fallback 분기 제거. | 독립 (OCaml) | **§4** wire SSOT 완성, flat string-as-truth 영구 차단 |
| **PR-9** | CI guard PR — `rg` 기반 lint 가 본 RFC §9 거부 기준 1~5 위반을 PR 단계에서 차단. `scripts/lint/dashboard-ssot-guard.sh`. | PR-1~7 | 회귀 방지 |

PR-1 머지 후 PR-2~7 은 모두 같은 SSOT 호출자이므로 **동시 진행** 가능. PR-8 (backend) 은 독립 stack 으로 병행. 각 PR < 300 LoC 변경 목표 (PR-1 만 ~500 LoC 예상, 신규 모듈 + fixture 테스트 포함).

## §6 비기능 요건 / 테스트

- PR-1 의 fixture 테스트는 *모든 wire 조합 × 모든 derived state* 매트릭스를 cover. catch-all `default:` 금지.
- TLA+ spec 은 본 RFC 대상 아님 (UI surface) — 단, backend `effective_blocker` (PR-6) 는 `KeeperCompositeLifecycle` invariant 후보.
- 시각 회귀 — paused keeper / blocked keeper / stuck keeper 각각의 dashboard screenshot snapshot 추가 (CI 자동화는 별도 RFC).

## §7 마이그레이션 / 호환성

- `runtime_blocker_class` wire field 는 PR-6 머지 후 *3 sprint* 동안 유지 (외부 reader 호환).
- dashboard 는 PR-3/PR-4 머지 시점부터 `effective_blocker` (PR-6) 가 있으면 우선 사용, 없으면 client-side conditioning fallback. PR-6 prod rollout 후 fallback 제거 PR-9 (별도).

## §8 Related work / cross-reference

- **PR #16552** (`fix(dashboard): split statusLabel collisions + unify displayStatus`, MERGED 2026-05-19) — body 의 "Out of scope" §에 사용자가 *RFC-0135 Keeper/Agent Status Vocabulary SSOT (가칭)* 으로 reserve. 본 RFC 가 그 가칭 scope (`'정지'` 124 occurrences inline 라벨링, 컴포넌트별 inline 라벨, `statusLabel ↔ monitoring-runtime ↔ fsm-hub-types` 3곳 분산) 을 *확장된 scope* (typed sum + derive 함수 + wire conditioning + label noun/verb 분리) 로 정착시킨다.
- **PR #16555** (typed verdict + runtime scope tagging for keeper detail alert strip) — 본 RFC 의 § 5 PR-5 가 직접 확장.
- **PR #16562** (vocab outlier alignment `정지`/`일시 중지` → `일시정지`) — 본 RFC §3 의 *선행 작업*. label SSOT 첫 step.
- **RFC-0133** (keeper phase casing SSOT consolidation) — backend↔frontend phase casing 정렬. 본 RFC §4 와 같은 패밀리 (wire normalization).
- **RFC-0088** (Counter-as-Fix 워크어라운드 거부) — 본 RFC §9 의 거부 기준이 0088 의 시그니처 #2 (String/Substring 분류기 보강) 와 직결.
- **RFC-0029** (Dashboard Fiber-Batched Aggregation) — 본 RFC 의 derive 함수가 batched aggregation 의 컨슈머. 의존성 없음 (병행 진행 가능).
- **memory note**: `feedback_dual_path_normalize_vs_raw_wire_format.md` (2026-05-19) — dashboard phase casing 사고와 동형 패턴.

## §9 거부 기준 (선언적 — CI guard 로 enforce, PR-8)

다음 패턴은 PR 머지 거부:

1. **flat string-as-truth** — 새 컴포넌트에서 `keeper.runtime_blocker_class` / `keeper.runtime_blocker_summary` 직접 읽기 (PR-6 후) → workaround 시그니처 #1.
2. **OR-축 visibility 분기** — `(status, phase, paused)` 세 축의 OR 조합으로 visibility/state 추론 → ortho 가정 위반.
3. **noun/verb 라벨 collision** — 같은 한국어 단어를 상태 위치와 액션 버튼 위치에 동시 emit (CI grep guard).
4. **catch-all `default:` 추가** — derive 함수의 sum 분기에서 누락된 arm 을 `default:` 로 봉인 → exhaustive match 약화.
5. **N-of-M 라벨 변경** — `status-label.ts` 의 매핑 변경 시 `stateLabel`/`actionLabel` 모두 동시 업데이트 (codemod 또는 fixture 테스트 동반).

## §10 Implementation Notes

- PR-1 의 derive 함수는 *pure* — 사이드이펙트 없음, store 의존 없음 (`Keeper`, `KeeperCompositeSnapshot` 만 인자).
- PR-2 의 tooltip 한국어 문구는 별도 PR-7 의 `actionLabel` 와 동시 머지하여 *접미사 + 사전조건 설명* 한 번에 노출.
- PR-6 backend 변경은 OCaml side 이므로 dashboard PR 시퀀스와 *독립 stack*. 단, PR-3/PR-4 의 fallback 분기가 PR-6 머지 전후를 안전하게 cover.

## §11 Risk / Open Questions

1. **typed sum 의 variant arm 확정**: `BlockerReason` 의 변형 목록은 audit 결과 (PR-1 머지 전) 에 따라 결정. 새 reason 이 wire 에서 추가되면 RFC-EXTEND 로 처리.
2. **paused cause** (`operator` / `auto_recover` / `liveness_guard`) 가 wire 에 명시되어 있는가? 없으면 PR-6 의 backend 확장 범위 확대.
3. **screenshot snapshot CI**: 본 RFC 외부. 별도 RFC 후보.
4. **외부 reader** (CLI, JIRA hook 등) 중 `runtime_blocker_class` 직접 의존하는 곳이 있다면 PR-6 deprecation 일정에 영향 — audit 필요.
5. **`fsm-hub-types` 누락 audit**: PR #16552 body 가 명시한 `statusLabel ↔ monitoring-runtime ↔ fsm-hub-types` 3곳 vocab 분산 중 `fsm-hub-types` 가 본 RFC §1.5 audit 에서 누락되었다. PR-1 spec 확정 전 추가 grep + matrix 보강 필요.

## §13 Axes Extensions (post-merge typed-state evolution)

`KeeperOperationalState` 는 PR-1 머지 시 4 variant (offline/paused/stuck/running) sum 으로 출발했고, 각 variant 가 *kind 별* 데이터만 가진 minimal shape 였다. 이후 audit (2026-05-19) 가 typed sum **외부** 에서 OR 합류되는 axes 를 다수 발견 — 이 axes 는 variant 와 직교 (paused 키퍼도 attention='needs_attention' 가능, running 키퍼도 attention='blocked' 가능). 외부 OR 합류는 RFC §9-2 (OR-축 visibility 분기) 거부 기준에 직접 해당.

본 절은 typed sum 에 흡수된 axes 의 evolution 을 한 줄씩 기록한다.

### Goal-2 / 2026-05-20 — `attention: KeeperAttention` 흡수

- **흡수 대상**: `composite.runtime_attention.{blocked, needs_attention}` 의 2-bit axis. 우선순위 `blocked > needs_attention > clean`.
- **이전 패턴**: `lib/keeper-operational-state.ts:179 deriveKeeperAttention(composite)` standalone helper + 외부 consumer (`components/keeper-detail-runtime.ts:213` audit B3) 가 `stuckByBlockerClass || attention !== 'clean'` OR-merge.
- **이후 패턴**: `KeeperOperationalState` 의 4 variant 모두 `attention: KeeperAttention` axis 보유. derive 함수가 일관 derive → variant 별 첨부. callsite 는 `opState.attention` 직접 read.
- **외부 helper 정리**: `deriveKeeperAttention` export 제거 → private `computeKeeperAttention`. 마지막 외부 consumer 가 `opState.attention` 으로 routing 되어 standalone export 불필요.
- **테스트**: 4 variant 각각의 `attention` 값이 `composite.runtime_attention` 와 정확히 매핑되는지 검증 (clean/blocked/needs_attention × 4 variant = 12 case).
- **B3 closure 증명**: `keeper-detail-runtime.ts` 의 `import { deriveKeeperAttention }` 사라짐 = SSOT 외부 axis 단일 callsite 의 완전 흡수.

### Goal-2 / 2026-05-21 — remaining axes strict closeout

- **흡수 대상**: audit Goal-2 잔여 축 `turnPhase`, `displaySummary`, `phase`.
- **이전 패턴**:
  - `turnPhase` 는 running variant 에만 있었고, `keeper-detail-runtime.ts` 는 `deriveKeeperTurnPhase(keeper, composite)` 를 별도 호출.
  - `displaySummary` 는 `deriveKeeperDisplayReason` / `deriveBlockerReason` helper 를 소비자가 직접 호출.
  - `phase` 는 `monitoring-runtime.ts:keeperPhaseForDisplay` 에서 lifecycle terminal guard + `derivePreferredPhase` fallback 을 직접 조합.
- **이후 패턴**: `KeeperOperationalState` 의 4 variant 모두 공통 `KeeperOperationalAxes` 를 보유:
  - `attention: KeeperAttention`
  - `turnPhase: KeeperTurnPhase` (composite preferred → flat `pipeline_stage` fallback → `unknown` marker)
  - `displaySummary: string | null` (composite runtime attention reason → flat blocker summary → flat attention reason)
  - `phase: KeeperPhase | null` (terminal lifecycle guard 보존, 그 외 composite preferred)
- **consumer closure**:
  - `keeper-detail-runtime.ts` 는 `opState.turnPhase` 와 `opState.displaySummary` 를 읽고 별도 fallback chain 을 제거.
  - `monitoring-runtime.ts` 는 `opState.phase` 를 읽고, band 계산도 같은 `opState` 인스턴스를 공유.
- **테스트**: `keeper-operational-state.test.ts` 에 non-running variant turnPhase, displaySummary precedence, phase terminal override 케이스 추가. `keeper-detail-runtime` / `monitoring-runtime` focused tests 로 consumer 회귀 확인.

이로써 HTML audit 의 Goal-2 명시 범위는 helper-level centralization 이 아니라 typed-state 공통 axis 로 닫힌다. Goal-2 이후 남은 external OR (`heartbeatStale`, `contextBreach`, `socialModelRecognized`) 는 typed variant arm 자체가 아니라 runtime projection layer 의 입력 신호로 다룬다.

### Follow-up / 2026-05-21 — runtime organism projection

- **흡수 대상**: `heartbeat stale`, `context ratio breach`, `fiberAlive`, `stopRequested`, `runtime trace`, `runtime warnings`, `execution.completion_contract_result`, FsmHub raw composite lanes.
- **이전 패턴**:
  - `monitoring-runtime.ts` 가 heartbeat/context/social/KSM phase 를 local OR-chain 으로 합류.
  - `keeper-detail-runtime.ts` 가 fiber/stop/trace/warning/completion-contract 를 별도 derive.
  - FsmHub raw lanes 는 아래 패널에서만 소비되어 live-truth headline 과 monitoring band 의 attention 판단과 같은 projection 으로 묶이지 않음.
- **이후 패턴**: `dashboard/src/lib/keeper-runtime-projection.ts` 가 `KeeperRuntimeProjection` 을 생성하고, detail live-truth + monitoring band 가 같은 projection 을 소비한다. 이 projection 은 `KeeperOperationalState` 를 대체하지 않고 감싼다: typed operational state 는 core lifecycle/blocker axis, runtime projection 은 주변 생체 신호와 raw FSM lanes 를 한 tick 의 동기화된 operator view 로 결합한다.
- **display rule**: detail live-truth 는 `동기화` row 에 projection headline/detail 을 노출하고, FsmHub 는 raw lanes 의 원본 상세 표시를 계속 담당한다. 따라서 raw truth 를 숨기지 않고 coupled summary 만 추가한다.
- **stale receipt rule**: `runtime_attention.execution_current=false` 또는 `stale_execution_receipt=true` 이면 `execution.completion_contract_result` 는 sync detail 에 남기되 current attention 으로 승격하지 않는다.
- **테스트**: `keeper-runtime-projection.test.ts` 가 listed signal 전체의 signal-kind set, headline/tone priority, stale receipt gating 을 검증한다. `monitoring-runtime.test.ts` 와 `keeper-detail-runtime.test.ts` 는 consumer 가 projection 을 통해 같은 attention/hint/sync row 를 읽는지 검증한다.

## §12 변경 이력

- 2026-05-19 vincent — 초안 작성, 3 사례 기반 root-cause 정리, PR 시퀀스 §5.
- 2026-05-20 vincent (via agent-llm-a-code) — §13 추가, Goal-2 `attention` axis 흡수 + 후속 axes 후보 명시. audit B3 closure.
- 2026-05-21 vincent (via agent-code) — Goal-2 잔여 `turnPhase`, `displaySummary`, `phase` 를 `KeeperOperationalState` 공통 axis 로 흡수.
- 2026-05-21 vincent (via agent-code) — runtime organism projection 추가. heartbeat/context/social/fiber/stop/trace/warning/tool/FSM lanes 를 한 projection 으로 결합하고 detail/monitoring consumer 를 전환.
