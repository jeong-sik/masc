---
rfc: "0150"
title: "Keeper Attention Signal — backend 단일 typed wire envelope"
status: Implemented
created: 2026-05-20
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0068", "0135"]
implementation_prs: []
---

# RFC-0150: Keeper Attention Signal — backend 단일 typed wire envelope

## §0 한 줄 요약

같은 운영자 의도(예: "런타임 근거를 확인해 turn을 재개해야 함")가 backend가 emit하는 3개 별 wire field(`attention_reason`, `next_human_action`, `trust.latest_next_action`)에 산재해, dashboard가 paired equivalence set으로 dedupe하는 임시 처방을 누적 중이다. 이를 **단일 `KeeperAttentionSignal` typed envelope**로 통합해 backend가 *한 가지 signal*만 emit하도록 정규화한다.

## §1 문제: 3-field 산재 (PR #16908 관찰)

PR #16908 작업 중 다음 모순이 *모두 dashboard 측에서* string-pair predicate로 흡수됨:

### §1.1 페어 #1: attention_reason ↔ next_human_action (4쌍)

| `attention_reason` | `next_human_action` | dashboard 라벨 |
|--------------------|---------------------|----------------|
| `runtime_blocked` | `inspect_runtime_blocker` | "런타임 근거 확인 필요" / "런타임 근거 확인" |
| `paused_blocked` | `inspect_blocker_before_resume` | "일시정지 원인 확인 필요" / "원인 확인 후 재개" |
| `provider_timeout` | `inspect_turn_timeout` | "프로바이더 타임아웃" / "타임아웃 근거 확인" |
| `runtime_trust_snapshot_unavailable` | `inspect_keeper_runtime_trust` | "런타임 신뢰 스냅샷 없음" / "런타임 신뢰 스냅샷 확인" |

PR #16908 PR-1 ckpt-1(commit `be17dd75db`)이 이 4쌍을 dashboard `ATTENTION_PAIR_DUPLICATES` set으로 dedupe했다. backend가 두 field를 *paired emit*하는 것 자체가 본 RFC가 닫고자 하는 anti-pattern.

### §1.2 페어 #2: attention_reason ↔ trust.latest_next_action (동일 페어 패턴)

`trust.latest_next_action`은 위 paired emit site에서 `next_human_action`을 *turn snapshot*으로 한 번 더 복사한 형태로 추정. PR #16908 follow-up commit(`0da6d7ddfb`)이 동일 `ATTENTION_PAIR_DUPLICATES` set을 재사용해 dashboard 측에서 또 hide함.

세 번째 field가 같은 NextHumanAction wire vocabulary를 다시 emit하는 것은 *parallel duplication*. backend wire schema의 의미 압축 실패.

### §1.3 Backend emit sites (확인 필요 — RFC §3 work)

- `lib/keeper/keeper_status_bridge.ml:727-742` — paired `(attention_reason, next_human_action)`, 6 reasons.
- `lib/keeper_fd_pressure.ml:190-191` — `(fd_pressure, restore_fd_headroom)`.
- `lib/dashboard/dashboard_goals.ml:44-45` — `(runtime_trust_snapshot_unavailable, inspect_keeper_runtime_trust)`.
- `lib/keeper/keeper_runtime_trust_snapshot.ml` — `trust.latest_next_action` derivation. (3rd emit path; precise line range TBD.)

## §2 Proposed: `KeeperAttentionSignal` typed envelope

```ocaml
type attention_signal =
  | Runtime_blocked of { blocker_class: string }
  | Paused_blocked of { since: float }
  | Provider_timeout of { elapsed_sec: float; budget_sec: float }
  | Fd_pressure of { headroom_pct: float }
  | Runtime_trust_snapshot_unavailable
  | Approval_pending of { id: string; tool_name: string; task_id: string option }
  | Continue_gate_required
  | Paused
```

각 variant가 *한 가지* operator intent. dashboard는 `attention_signal`만 받고 `attention_reason / next_human_action / latest_next_action` 3 필드 모두 제거.

라벨링은 dashboard 측 `attention-signal-display.ts`에서 *variant별* Korean text 결정 — single typed source. PR #16908의 `Record<AttentionReason, string>` 봉인이 (commit `4dab7b8961`) 이미 dashboard 측 결정 단일화를 시작해놨으니, backend가 `attention_signal`만 emit하면 그 봉인이 자연스럽게 *완성된다*.

### §2.1 Wire format

```json
{
  "attention_signal": {
    "kind": "provider_timeout",
    "elapsed_sec": 600.0,
    "budget_sec": 600.0
  }
}
```

ATD/codegen 경로는 RFC-0140 dashboard-wire-codec-layer 기반.

## §3 Phasing

| Phase | Backend | Dashboard | Cutover |
|-------|---------|-----------|---------|
| P0 | `attention_signal` field 추가 (parallel emit, 3 필드 그대로 유지) | 기존 3 필드 그대로 사용 | none |
| P1 | 3 필드 derived from `attention_signal` (단일 SSOT 컴퓨테이션) | `attention_signal` 우선 read, 3 필드 fallback | dashboard reads new field |
| P2 | 3 필드 emit 중단, schema 삭제 | `attention_signal` only, dedupe set 삭제 | backend stops legacy emit, dashboard cleans up |

P2 cutover 시 PR #16908의 다음 코드가 *함께 삭제*되어야 함 — anti-stale-workaround invariant:

- `dashboard/src/components/keeper-detail-alert-strip.ts:ATTENTION_PAIR_DUPLICATES`
- `dashboard/src/components/keeper-detail-alert-strip.ts:duplicatesAttentionReason`
- `dashboard/src/components/keeper-detail-alert-strip.ts:isAttentionPairDuplicate`

## §4 Out of scope

- `attention_signal` 외 다른 operator-facing 정보 (`operator_disposition`, `stop_cause`, `latest_terminal_reason`) — 본 RFC 영역 밖.
- RFC-0068 (backend turn disposition typed sum) — 인접 영역이지만 다른 layer (turn 종료 시점 vs operator pending 시점).
- Dashboard label SSOT (RFC-0135 implementation_prs에 PR #16908 등록은 별도 PR로 처리).
- `TURN_TERMINAL_FAILURE_CODES`와 backend `Keeper_turn_disposition` wire enum의 동기화 — 본 RFC와 다른 codeset. PR #16908 follow-up commit `15fefb37c9`가 1 entry만 임시 추가했으며, full sync는 RFC-0068 PR-3 또는 별 RFC가 다룰 영역.

## §5 Related

- RFC-0068 (turn disposition typed sum) — turn 종료 layer.
- RFC-0135 (dashboard SSOT) — dashboard read-side. PR #16908이 implementation_prs 후보로 별도 register 예정.
- RFC-0140 (dashboard wire codec layer) — ATD/codegen 인프라.
- PR #16908 commits `4dab7b8961` (typed enum 봉인), `be17dd75db` (페어 #1 dedupe), `0da6d7ddfb` (페어 #2 dedupe), `15fefb37c9` (failure code gap) — *prereq workaround*로 분류, P2에서 회수.

## §6 Open questions

1. `trust.latest_next_action`이 정확히 어디서 derive되는가? `keeper_runtime_trust_snapshot.ml`의 어떤 함수가 `next_human_action`을 trust snapshot으로 복사하는지 line-range 확정 필요.
2. `attention_signal` variant 9개 중 어떤 것이 *진짜 거의 안 emit되는지* (e.g. `Continue_gate_required`)? Production log에서 emit frequency 측정 후 inactive variant는 deprecation candidate.
3. P2 cutover 시 backwards compatibility — 외부 client(예: 다른 dashboard, external scripts)가 3 필드를 직접 읽는가? `rg` 확인 필요.
