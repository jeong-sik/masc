---
rfc: "0494"
title: "Muse resume 는 세션이 이미 가진 context 를 다시 보내지 않는다 — 앞 턴 끝부터 이번 턴 끝까지의 durable 기록에 압축이 없을 때만"
status: Draft
created: 2026-11-05
updated: 2026-11-05
author: claude
supersedes: []
superseded_by: null
related: ["0482", "0483"]
---

# RFC-0494 — Muse resume 는 세션이 가진 context 를 다시 보내지 않는다

## 0. 요약

- Muse lane 은 resume 마다 고른 context 와 Memory 를 통째로 다시 보낸다(`keeper_muse_runtime.ml:1191` `let held = []`).
  - 11-04~05 resume 프롬프트 중앙값은 Muse 126KB(842턴)다.
  - 같은 기간 Claude Code 는 9.5KB(1,731턴)다.
- Claude Code·Codex lane 은 섹션·행 단위로 "세션이 이미 가진 것"을 빼고 보낸다(`held_context`). 턴 안에서 압축 알림을 받으면 다음 턴에 다 보낸다.
- 11-01 자체 리뷰는 Muse 에 같은 규칙을 쓰지 않기로 했다. Muse 의 live push 는 빠질 수 있어서, 알림이 없었다는 것이 압축이 없었다는 증거가 못 된다. 그 기록은 "턴을 넘는 durable 증거가 생기면 최적화한다"고 미뤘다.
- 이 RFC 는 그 증거를 정한다. 앞 턴의 `turn/completed` 부터 이번 턴의 terminal 까지 `view/page` 로 끊김 없이 읽은 durable 구간이다. 이 구간에 `compaction` 항목이 하나도 없을 때만 세션이 앞서 받은 context 를 그대로 가진 것으로 본다.
- 구간을 끝까지 못 읽거나, 모르는 값을 만나거나, 압축 항목이 하나라도 있으면 지금처럼 다 보낸다. 시간·턴 수·크기로 추정하는 규칙은 두지 않는다.

## 1. 지금

### 1.1 Muse 가 보내는 것

| 측정(11-04~05, `system_log` 의 `turn composition: mode=resume prompt_bytes=`) | 턴 | p10 | p50 | p90 |
| --- | --- | --- | --- | --- |
| Muse Code | 842 | 110,079 | 126,259 | 151,511 |
| Claude Code | 1,731 | 4,330 | 9,467 | 149,838 |

- 두 lane 이 고르는 context 크기는 비슷하다. 턴 기록 `prompt.dynamic_context.bytes` 중앙값은 e-masc-the-leader 107,758, pr-updater 104,853, you-never-change 122,681 이다. 차이는 resume 때 무엇을 빼느냐에서 난다.
- `dynamic_context.fingerprint` 는 턴마다 바뀐다. you-never-change 306턴, ocaml-agent-ic 531턴 중 앞 턴과 같은 경우는 0번이다. 그래서 통째로 비교하는 방식은 줄이는 것이 없다. 섹션·행 단위 비교(`Keeper_official_client_session_store.carried_context`)가 필요하다.

### 1.2 다시 보낸 만큼 생기는 일

Muse 호스트 세션 로그(`~/me/.masc/official-clients/muse/<hash>/.local/share/muse/sessions/2026/11/0{2..5}/*/session.jsonl`)의 `model_completed` usage 15,421건으로 쟀다.

- 턴 사이 입력 증가 중앙값은 35.8k 토큰이다. 다시 보낸 context 가 그 대부분일 것으로 본다(바이트를 토큰으로 바꾼 값은 추정).
- 호스트는 512k 기준 soft 0.75(384k)·hard 0.90(460.8k)에서 압축한다(`context_compaction_candidate` 의 `config_fingerprint "soft=0.7500,hard=0.9000"`).
  - 큰 세션 6개의 압축 332번은 모두 임계값에서 걸렸다. 그중 128번(39%)은 압축이 끝날 때까지 턴이 멈춘 `hard_threshold_blocking` 이다.
- 캐시 안 된 토큰 643M 중 23%가 압축 직후 요청에서 나왔다(압축 479번, 그 직후 적중 7%).
- 55%는 턴 중간 캐시 소실이다. 이것은 공급자 쪽에서 세션 고유 KV 가 밀려난 것으로 보이고 이 RFC 범위 밖이다(§3). 다만 프롬프트가 작아지면 소실 한 번의 비용도 줄어든다. 지금 평균은 26.6만 토큰이다(큰 세션 6개).
- 가격: muse-spark-1.3 캐시 입력은 1M 토큰당 $0.15, 일반 입력은 $1.25 다(dev.meta.ai/docs/pricing-rate-limits, 2026-11-05 확인).

### 1.3 11-01 에 막힌 이유

`docs/evidence/2026-11-01-official-client-self-review/2026-11-01-official-client-self-review-evidence-record.md:23`:

> Muse live push silence cannot certify retained Memory — A dropped compaction's gap notification can arrive after the terminal — Reuse the session but retransmit selected current context; do not persist exact held-context certificates without a durable retention witness

- 맞는 판단이다. Claude Code·Codex 는 자식 프로세스의 출력 순서대로 압축 알림을 받는다(`keeper_claude_code_runtime.ml:1182`·`:1436`, `keeper_codex_runtime.ml:1555`). Muse 는 MSP push 로 받고, push 에는 빈틈이 생긴다(`Runtime_muse_serve.View_gap_observed`, `runtime_muse_serve.mli:287`).
- 같은 리뷰의 다음 줄은 최종 답에 같은 문제가 있다고 보고 durable 구간을 읽게 했다. `read_durable_turn`(`runtime_muse_serve.ml:1135`)은 terminal cursor 에서 거꾸로 이번 턴의 `turn/started` 까지 `view/page` 로 읽는다. 지금은 그 구간에서 최종 답·usage·모델만 꺼낸다(`durable_turn_of_events`, `:1061`).

## 2. 설계

### 2.1 증거 구간

증거는 settlement 마다 한 번 만든다. 범위는 다음 둘 사이의 durable 이벤트 전부다.

- 시작:
  - resume 턴은 직전에 acknowledged 된 턴(`claim_plan.previous_settlement` 의 `turn_id`)의 `turn/completed` 이벤트 바로 뒤부터다.
  - start 턴은 이번 턴의 `turn/started` 부터다. 지금 `read_durable_turn` 이 읽는 범위와 같다. 큰 seed 로 start 턴 안에서 압축이 날 수 있어서 start 도 판정을 받는다.
- 끝(포함): 이번 턴의 terminal cursor.

turn id 는 압축을 넘어 그대로다(MSP `ForkCutPoint` 설명, `keeper_official_client_session_store.mli` `host_last_turn` 설명). 그래서 새 필드나 cursor 저장 없이 이미 저장된 turn id 로 시작점을 찾는다. 저장 형식(`masc.keeper.official-client-session.v2`)은 바뀌지 않는다.

이 범위는 두 턴 사이에 끝난 압축(`timing: standalone_manual`)과 다음 턴 시작 전 압축(`pre_turn`)을 모두 덮는다.

### 2.2 판정

```ocaml
type retention_witness =
  | Retained
      (** 구간을 끝까지 읽었고 compaction 항목이 없거나, 있는 것이 모두
          [Compaction_noop] 으로 끝났다. *)
  | Rewritten of { item_id : string }
      (** compaction 항목이 시작됐다. 끝났든 아니든, outcome 이
          [Compaction_noop] 이 아니면 여기다. [Unrecognized_*] outcome 도
          여기다. *)
  | Unwitnessed of unwitnessed
and unwitnessed =
  | Previous_boundary_not_held  (** 서버가 앞 턴의 turn/completed 를 더 가지고 있지 않다 *)
  | Gap_in_durable_range        (** durable 읽기에 View_gap 이 끼었다 *)
  | Turn_not_settled            (** 이번 턴이 terminal 없이 끝났다 *)
```

- `held_context` 는 `Retained` 일 때만 "앞서 가졌던 것 + 이번 턴에 보낸 것"이 된다. `Rewritten`·`Unwitnessed` 면 `[]` 이다.
- 다음 resume 은 `held_context_for_resume` 을 그대로 쓴다. 섹션·행 비교, "변하지 않음" 안내(`unchanged_sections`·`partly_held_sections`)는 Claude Code·Codex 와 같은 코드가 만든다. Muse 전용 비교 규칙은 없다.
- start 턴은 `Retained` 일 때 `start_held_context` 를, 아니면 `[]` 를 남긴다. start 다음 첫 resume 의 시작점은 start 턴의 `turn/completed` 다.
- `Compaction_failed`·`Compaction_cancelled` 도 `Rewritten` 이다. 규약(`CompactionOutcome`)은 실패한 압축이 모델 입력을 그대로 뒀는지 말하지 않는다.
- 판정은 settlement 에서만 한다. live push 의 `Compaction_observed` 는 지금처럼 로그와 raw trace 에만 쓴다.

### 2.3 남는 틈과 받아들이는 이유

압축이 턴 N+1 의 첫 요청 직전(`pre_turn`)에 설치되면 문제가 생긴다. masc 는 턴 N 끝에서 `Retained` 를 보고 N+1 프롬프트에서 섹션을 뺀다. 그런데 모델은 N+1 동안 그 섹션의 요약만 본다. N+1 settlement 가 그 압축을 `Rewritten` 으로 잡아 N+2 는 다 보낸다.

- Claude Code·Codex lane 도 같은 틈을 가진다. 압축 알림은 그 턴이 끝난 뒤에야 다음 턴에 반영된다.
- 호스트가 비동기 압축 후보를 시작할 때 `item/started` 를 내면 이 틈은 줄어든다. 턴 N 구간에 시작 항목이 들어와 N 에서 `Rewritten` 이 된다. 공식 transcript `schema/msp/transcripts/compact-command-round-trip` 은 수동 압축에서 `item/started`(`status: inProgress`) 뒤에 `item/completed` 가 오는 것을 보인다. 자동 압축 후보에서도 같은지는 확인 필요다(§6 Q1).

### 2.4 고치는 곳

| 층 | 파일 | 바뀌는 것 | 시험 |
| --- | --- | --- | --- |
| L1 | `lib/runtime/runtime_muse_msp.ml(i)`, `lib/runtime/runtime_muse_serve.ml(i)` | `read_durable_turn` 이 `~since_turn_id` 를 받아 앞 턴 `turn/completed` 까지 읽고, `durable_turn` 에 `retention : retention_witness` 를 더한다 | 녹화된 view/page 페이지로: 압축 없음 → `Retained`, 시작만 있음·completed·failed·모르는 outcome → `Rewritten`, noop → `Retained`, 앞 경계 없음 → `Previous_boundary_not_held`, gap → `Gap_in_durable_range` |
| L2 | `lib/keeper/keeper_muse_runtime.ml` | `let held = []` 를 `held_context_for_resume` 로, 두 settle 지점(`settle_holding`·`settle_completed_holding`)의 `~held_context:[]` 를 판정 결과로 바꾼다. `:1191` 위 주석의 미뤄 둔 이유를 지운다 | `Retained` 뒤 resume 이 바뀐 섹션만 보낸다. `Rewritten`·`Unwitnessed` 뒤 resume 은 다 보낸다. terminal 없이 끝난 턴 뒤 resume 은 다 보낸다. 안에서 압축된 start 뒤 resume 은 다 보낸다 |
| L3 | `docs/evidence/` | 배포 전후 측정 | §5 |

`gh stack` 으로 L1 → L2 를 쌓는다. L3 는 배포 뒤 문서 PR 이다.

## 3. 하지 않는 것

- 압축 임계값을 바꾸지 않는다. `context_compaction.soft_threshold`·`hard_threshold`·`provider_context_limit_tokens` 는 1.4.14 바이너리에만 있고 공식 설정 문서(dev.meta.ai/docs/muse-code/configuration)에는 없다.
- `prompt_cache_retention: "24h"` 를 다루지 않는다. Muse Code 1.4.14 는 이 값을 보내지 않고 설정 키도 없다. 또 공백 15~60분 요청도 적중 85%라서 보존 시간은 주원인이 아니다.
- 턴 중간 캐시 소실(55%)을 고치지 않는다. 소실 뒤 남는 `cache_read` 가 세션이 달라도 같은 값(17009·22769·28785·9969)이다. 세션끼리 공유하는 앞부분만 남는다는 뜻이고, 원인은 공급자 쪽이다.
- 새 세션 seed 상한(#47789)은 RFC-librarian-lifecycle 의 `refused_model_input` 규칙이 다룬다.

## 4. 고르지 않은 길

| 길 | 버린 이유 |
| --- | --- |
| live push 의 `Compaction_observed` 만 보기(Claude Code 방식) | push 는 빠진다. 11-01 리뷰가 막은 바로 그 길이다 |
| 호스트 내부 `session.jsonl` 의 `context_projection_checkpoint` 읽기 | 공개 규약이 아닌 내부 형식이다. 버전이 바뀌면 말없이 틀린다 |
| N턴마다·M바이트마다 다 보내기 | 추정이다. 압축이 없어도 다 보내고, 압축이 있어도 못 잡는다 |
| dynamic context 전체 digest 비교 | 매 턴 바뀐다(0/306, 0/531). 줄이는 것이 없다 |
| cursor 를 새 필드로 저장 | 저장 형식 hard cut 이 모든 official client 세션을 새로 시작하게 한다. 이미 저장된 turn id 로 같은 경계를 찾을 수 있다 |

## 5. 측정과 되돌림

배포 전 3일과 배포 뒤 3일을 같은 Muse Keeper 로 비교한다. Muse 주간 한도가 11-09 00:00Z 에 풀리므로 그 뒤에 잰다.

| 값 | 출처 | 목표 |
| --- | --- | --- |
| resume `prompt_bytes` p50 | `system_log` `turn composition` | 20KB 이하(Claude Code 9.5KB) |
| 턴 사이 입력 증가 p50 | 호스트 `model_completed` usage | 지금 35.8k 보다 작음 |
| 100턴당 압축 설치 수 | 호스트 `context_compaction_installed` | 지금보다 작음 |
| 도구 호출당 캐시 안 된 토큰 | 호스트 `model_completed` (input − cache_read) | 지금 45.6k 보다 작음 |
| 판정 분포 | L1 이 남기는 `retention` 로그 | `Unwitnessed` 비율을 그대로 적는다 |

첫 셋이 줄지 않으면 "다시 보낸 context 가 세션 성장의 주원인"이라는 §1.2 가정이 틀린 것이다. 그때는 L2 를 되돌린다.

## 6. 열린 질문

- Q1. 자동 압축 후보가 시작될 때 호스트가 `item/started`(kind `compaction`)를 내는가? L1 시험 전에 살아 있는 세션 하나를 `view/page` 로 읽어 확인한다. 안 내면 §2.3 의 틈이 Claude Code 와 같은 크기로 남는다.
- Q2. 호스트가 compaction 항목 없이 이미 보낸 user message 를 바꾸는 경로가 있는가? 바이너리에 `run.context_slimming`·`context_compaction.tool_result_clearing_enabled` 가 있다. 공식 문서의 `MUSE_TRANSPORT_TRACE=1` 로 연속 턴의 실제 요청을 보고 확인한다. 그런 경로가 있으면 이 RFC 는 멈춘다. 이 구간이 증거가 되지 못하기 때문이다.
- Q3. 앞 턴이 terminal 없이 끝난 경우(`Unobserved_after`) `turn/completed` 가 durable 기록에 남는가? 안 남으면 그 다음 턴은 늘 `Previous_boundary_not_held` 로 다 보낸다. 안전하지만 줄어드는 것이 없다.
