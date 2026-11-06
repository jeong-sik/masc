---
rfc: "0494"
title: "Muse resume 는 세션이 이미 가진 context 를 다시 보내지 않는다 — 앞 턴 끝부터 이번 턴 끝까지 durable 기록에 압축이 없을 때만"
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
- Claude Code·Codex lane 은 섹션·행 단위로 "세션이 이미 가진 것"을 빼고 보낸다(`held_context`). 압축 알림을 받으면 그다음은 다 보낸다.
- 11-01 자체 리뷰는 Muse 에 같은 규칙을 쓰지 않기로 했다. Muse 의 live push 는 빠질 수 있어서, 알림이 없었다는 것이 압축이 없었다는 증거가 못 된다. 그 기록은 "턴을 넘는 durable 증거가 생기면 최적화한다"고 미뤘다.
- 이 RFC 는 그 증거를 정한다. 앞 턴 `turn/completed` 뒤부터 이번 턴 terminal 까지를 `view/page` 로 빈틈없이 읽은 durable 기록이다. 두 번에 나눠 읽는다.
  - 다음 턴을 보내기 전: 앞 턴 끝부터 지금 head 까지.
  - 턴이 끝날 때: 그 뒤부터 이번 턴 terminal 까지.
- 기록의 항목과 알림은 공개 규약의 종류마다 이름으로 분류한다. 압축 항목, 손상 구간, 잘린 앞부분, 모르는 종류, 읽기 실패 중 하나라도 있으면 지금처럼 다 보낸다. 시간·턴 수·크기로 추정하는 규칙은 없다.

## 1. 지금

### 1.1 Muse 가 보내는 것

| 측정(11-04~05, `system_log` 의 `turn composition: mode=resume prompt_bytes=`) | 턴 | p10 | p50 | p90 |
| --- | --- | --- | --- | --- |
| Muse Code | 842 | 110,079 | 126,259 | 151,511 |
| Claude Code | 1,731 | 4,330 | 9,467 | 149,838 |

- 두 lane 이 고르는 context 크기는 비슷하다. 턴 기록 `prompt.dynamic_context.bytes` 중앙값은 e-masc-the-leader 107,758, pr-updater 104,853, you-never-change 122,681 이다. 차이는 resume 때 무엇을 빼느냐에서 난다.
- `dynamic_context.fingerprint` 는 턴마다 바뀐다. you-never-change 306턴, ocaml-agent-ic 531턴 중 앞 턴과 같은 경우는 0번이다. 통째로 비교하면 줄이는 것이 없다. 섹션·행 단위 비교(`Keeper_official_client_session_store.carried_context`)가 필요하다.

### 1.2 다시 보낸 만큼 생기는 일

Muse 호스트 세션 로그(`~/me/.masc/official-clients/muse/<hash>/.local/share/muse/sessions/2026/11/0{2..5}/*/session.jsonl`)로 쟀다. 이 로그는 호스트 내부 형식이라 측정에만 쓰고 설계의 증거로는 쓰지 않는다(§4).

- `model_completed` usage 15,421건에서 턴 사이 입력 증가 중앙값은 35.8k 토큰이다. 다시 보낸 context 가 그 대부분일 것으로 본다(바이트를 토큰으로 바꾼 값은 추정).
- 호스트는 512k 기준 soft 0.75(384k)·hard 0.90(460.8k)에서 압축한다(`context_compaction_candidate` 의 `config_fingerprint "soft=0.7500,hard=0.9000"`).
  - 큰 세션 6개의 압축 332번은 모두 임계값에서 걸렸다. 그중 128번(39%)은 압축이 끝날 때까지 턴이 멈춘 `hard_threshold_blocking` 이다.
- 캐시 안 된 토큰 643M 중 23%가 압축 직후 요청에서 나왔다(압축 479번, 그 직후 적중 7%).
- 55%는 턴 중간 캐시 소실이다. 공급자 쪽에서 세션 고유 KV 가 밀려난 것으로 보이고 이 RFC 범위 밖이다(§3). 다만 프롬프트가 작아지면 소실 한 번의 비용도 줄어든다. 지금 평균은 26.6만 토큰이다(큰 세션 6개).
- 가격: muse-spark-1.3 캐시 입력은 1M 토큰당 $0.15, 일반 입력은 $1.25 다(dev.meta.ai/docs/pricing-rate-limits, 2026-11-05 확인).

### 1.3 11-01 에 막힌 이유와 지금 코드

`docs/evidence/2026-11-01-official-client-self-review/2026-11-01-official-client-self-review-evidence-record.md:23`:

> Muse live push silence cannot certify retained Memory — A dropped compaction's gap notification can arrive after the terminal — Reuse the session but retransmit selected current context; do not persist exact held-context certificates without a durable retention witness

- 맞는 판단이다. Claude Code·Codex 는 자식 프로세스 출력 순서대로 압축 알림을 받는다(`keeper_claude_code_runtime.ml:1182`·`:1436`, `keeper_codex_runtime.ml:1555`). Muse 는 MSP push 로 받고, push 에는 빈틈이 생긴다(`Runtime_muse_serve.View_gap_observed`, `runtime_muse_serve.mli:287`).
- 같은 리뷰의 다음 줄 때문에 `read_durable_turn`(`runtime_muse_serve.ml:1135`)이 생겼다. 이 함수는 terminal cursor 에서 거꾸로 이번 턴 `turn/started` 까지 `view/page` 로 읽는다. 지금은 그 구간에서 최종 답·usage·모델만 꺼낸다(`durable_turn_of_events`, `:1061`). 이 읽기가 실패하면 턴이 실패한다(`:1394-1404`).
- durable page 는 cursor 를 건너뛰지 않는다(MSP `ViewPageResult.events`). page 안의 `View_gap` 은 masc 가 이미 거절한다(`runtime_muse_msp.ml:1414-1415`).
- 공개 `ItemKind` 18개 중 masc 가 모르는 것은 `Unrecognized_item_kind` 로 읽고 버린다(`runtime_muse_msp.ml:815`, `:955`, `:970`). 버려지는 것에 `damagedRange`(읽지 못한 로그 구간)와 `earlierHistory`(잘린 앞부분 대신 나오는 항목)도 들어 있다.

## 2. 설계

### 2.1 두 번의 읽기

턴 T+1 을 기준으로 쓴다. 턴 T 는 직전에 acknowledged 된 턴(`claim_plan.previous_settlement`)이다.

| 읽기 | 언제 | 범위 | 실패하면 |
| --- | --- | --- | --- |
| 사이 읽기 | `session/resume` 다음, `turn/start` 전 | head 에서 거꾸로, T 의 `turn/completed` 바로 뒤까지 | `Unwitnessed Unreadable`. 다 보내고 턴은 진행 |
| 끝 읽기 | T+1 의 `turn/completed`(`Terminal_completed`) 를 받은 뒤 | 사이 읽기가 본 가장 새 이벤트 바로 뒤부터 T+1 terminal 직전까지 | `Unwitnessed Unreadable`. 아무것도 held 로 남기지 않고 턴은 완료 |

- 두 범위는 빈틈없이 이어진다. 사이 읽기가 끝난 뒤 `turn/start` 전에 생긴 이벤트도 끝 읽기에 들어간다. 끝을 정하는 것은 cursor 같음 비교뿐이다. cursor 는 열어 보지 않는다(MSP 규약: opaque).
- 끝 읽기는 답 읽기(`read_durable_turn`)가 이미 읽은 `[turn/started, terminal)` 이벤트에 분류를 얹는다. 따로 더 읽는 것은 `(사이 읽기의 가장 새 이벤트, turn/started)` 뿐이다. 답 읽기의 범위와 실패 규칙은 바뀌지 않는다. 분류는 이미 디코드된 이벤트 위의 순수 함수다.
- 사이 읽기는 T 의 `turn/completed` 외에도 멈춘다. T 의 `turn/started`, `earlierHistory` 항목, 세션 처음에 먼저 닿으면 `Previous_boundary_not_held` 다. 그래서 읽는 양에 끝이 있다. 지나간 page 는 접어서 분류만 남기고 쌓아 두지 않는다.
- start 턴에는 사이 읽기가 없다. 끝 읽기는 `[turn/started, terminal)` 이다. 큰 seed 로 start 턴 안에서 압축이 날 수 있어서 start 도 판정을 받는다.
- 터미널 없이 끝난 턴, 실패한 턴, 재시도, 세션 교체는 지금 store 가 이미 아무것도 held 로 남기지 않는다(`keeper_official_client_session_store.ml:1942-1948`, `:1991-1995`, `held_context_for_resume` 의 `:1614-1618`). 이 RFC 는 그 경로를 바꾸지 않는다.

### 2.2 판정

```ocaml
type retention_witness =
  | Retained
  | Rewritten of { item_id : string }
  | Unwitnessed of unwitnessed
and unwitnessed =
  | Previous_boundary_not_held
      (** 사이 읽기가 T 의 turn/completed 를 만나기 전에 T 의 turn/started,
          earlierHistory, 세션 처음 중 하나에 닿았다. *)
  | Damaged_range of { item_id : string }
  | Unrecognized_item_kind of string
  | Unrecognized_method of string
  | Unreadable of string
      (** view/page 요청·디코드 실패. 턴은 실패시키지 않는다. *)
```

- 두 읽기가 모두 `Retained` 일 때만 T+1 은 섹션을 뺀다. 그리고 T+1 settlement 는 `resume_delivery.held_context`(앞서 가졌던 것 + 이번에 보낸 것)를 남긴다.
- 사이 읽기가 `Retained` 가 아니면 T+1 은 다 보낸다. 이때 보낸 것이 새 held 의 바탕이 된다.
- 끝 읽기가 `Retained` 가 아니면 T+1 settlement 는 `[]` 를 남긴다.
- 섹션·행 비교와 "변하지 않음" 안내(`unchanged_sections`·`partly_held_sections`)는 Claude Code·Codex 와 같은 `Host.resume_prompt` 가 만든다. Muse 전용 비교 규칙은 없다.

### 2.3 분류표

모든 durable 항목은 아래 중 하나로 간다. `match` 에 `_ ->` 를 두지 않는다.

| `ItemKind` | 판정 |
| --- | --- |
| `compaction` | `completed` 이고 outcome 이 `noop` 이면 영향 없음. 그 밖(시작만, `compacted`, `failed`, `cancelled`, 모르는 outcome)은 `Rewritten`. 규약은 실패한 압축이 모델 입력을 그대로 뒀는지 말하지 않는다 |
| `damagedRange` | `Damaged_range`. 그 안에 무엇이 있었는지 모른다 |
| `earlierHistory` | `Previous_boundary_not_held`. 잘린 앞부분 대신 나오므로 경계를 볼 수 없다 |
| `userMessage`, `agentMessage`, `reasoning`, `toolCall`, `userShell`, `subagent`, `workflow`, `reminderChild`, `hookRun`, `sideChat`, `webSearch`, `monitorFeed`, `scheduledFire`, `backgroundTerminalCompletion`, `overdueNotice` | 영향 없음. 새 항목을 더할 뿐 앞서 보낸 입력을 바꾸지 않는다(공개 규약 기준. Q2 가 이것을 확인한다) |
| 그 밖의 문자열 | `Unrecognized_item_kind` |

알림은 MSP `MspNotification` 목록(스키마 4025줄)의 durable 알림을 모두 이름으로 분류한다. `item/*` 은 위 표를 따르고 나머지는 영향 없음이다. 목록에 없는 method 는 `Unrecognized_method` 다.

Muse 런처는 기본으로 한 시간마다 새 버전을 확인한다(`~/.local/bin/muse` 의 `MUSE_UPDATE_INTERVAL_SECONDS:-3600`). 새 종류가 생기면 masc 가 이름을 붙일 때까지 `Unrecognized_*` 가 되어 다 보낸다. 줄이지는 못하지만 틀리지는 않는다.

### 2.4 남는 틈

`TurnStartParams` 에는 "head 가 이 cursor 일 때만 시작" 같은 전제 조건이 없다. 그래서 사이 읽기와 `turn/start` 사이, 또는 T+1 첫 요청 직전에 압축이 설치될 수 있다. 이때 T+1 은 뺀 섹션의 요약만 보고 돈다.

- 이 경우는 T+1 끝 읽기가 정확히 잡는다(`Rewritten`). T+2 는 다 보낸다.
- 같은 턴에 "섹션을 뺐다"와 "끝 읽기가 `Rewritten`" 이 함께 나오면 `Rewritten_while_held` 로 적는다. §5 에서 센다.
- 호스트가 자동 압축 후보를 시작할 때 `item/started` 를 내면 이 틈은 줄어든다. 진행 중인 압축이 사이 읽기에 보이기 때문이다. 공식 transcript `schema/msp/transcripts/compact-command-round-trip` 은 수동 압축에서 `item/started`(`status: inProgress`) 뒤에 `item/completed` 가 오는 것을 보인다. 자동 압축에서도 같은지는 확인 필요다(Q1).

### 2.5 고치는 곳

| 층 | 파일 | 바뀌는 것 | 시험 |
| --- | --- | --- | --- |
| L1 | `lib/runtime/runtime_muse_msp.ml(i)` | 공개 `ItemKind` 18개와 durable 알림을 닫힌 합으로 디코드하고, 모르는 값은 버리지 않고 `Unrecognized_*` 로 남긴다. 순수 `classify : view_event list -> retention_witness` | §2.3 표의 줄마다 한 시험. 녹화된 page 조각 사용 |
| L2 | `lib/runtime/runtime_muse_serve.ml(i)` | 사이 읽기 함수. 끝 읽기는 `read_durable_turn` 결과에 분류를 얹고 `(사이 끝, turn/started)` 만 더 읽는다 | 경계 찾음 → `Retained`, `turn/started` 먼저 → `Previous_boundary_not_held`, `earlierHistory` → 같은 것, `damagedRange` → `Damaged_range`, 요청 실패 → `Unreadable` 이고 턴은 완료 |
| L3 | `lib/keeper/keeper_muse_runtime.ml` | `framed_prompt_for_turn` 대신 `Host.resume_prompt` 를 불러 `resume_delivery.held_context` 를 얻는다. `framed_prompt_for_turn` 은 `.prompt` 만 돌려준다(`keeper_official_client_host.ml:1036`). Antigravity lane 은 그대로 둔다. `held` 와 두 settle 지점(`settle_holding`·`settle_completed_holding`)의 `[]` 를 판정 결과로 바꾸고, `:1191` 위 주석의 미뤄 둔 이유를 지운다 | `Retained` 두 번 뒤 resume 은 바뀐 섹션만 보낸다. 어느 한쪽이 `Retained` 가 아니면 다 보낸다. 안에서 압축된 start 뒤 resume 은 다 보낸다 |
| L4 | `docs/evidence/` | 배포 전후 측정 | §5 |

`gh stack` 으로 L1 → L2 → L3 를 쌓는다. L4 는 배포 뒤 문서 PR 이다.

## 3. 하지 않는 것

- 압축 임계값을 바꾸지 않는다. `context_compaction.soft_threshold`·`hard_threshold`·`provider_context_limit_tokens` 는 1.4.14 바이너리에만 있고 공식 설정 문서(dev.meta.ai/docs/muse-code/configuration)에는 없다.
- `prompt_cache_retention: "24h"` 를 다루지 않는다. Muse Code 1.4.14 는 이 값을 보내지 않고 설정 키도 없다. 또 공백 15~60분 요청도 적중 85%라서 보존 시간은 주원인이 아니다.
- 턴 중간 캐시 소실(55%)을 고치지 않는다. 소실 뒤 남는 `cache_read` 가 세션이 달라도 같은 값(17009·22769·28785·9969)이다. 세션끼리 공유하는 앞부분만 남는다는 뜻이고, 원인은 공급자 쪽이다.
- 새 세션 seed 상한(#47789)은 RFC-librarian-lifecycle 의 `refused_model_input` 규칙이 다룬다.

## 4. 고르지 않은 길

| 길 | 버린 이유 |
| --- | --- |
| live push 의 `Compaction_observed` 만 보기(Claude Code 방식) | push 는 빠진다. 11-01 리뷰가 막은 바로 그 길이다 |
| 답 읽기 범위를 앞 턴까지 넓히기 | 답 확인이 옛 이벤트 디코딩에 묶인다. 옛 구간을 못 읽으면 완료된 턴이 실패한다 |
| 턴이 끝날 때 한 번만 읽기 | 두 턴 사이에 설치된 압축을 다음 턴이 이미 섹션을 뺀 뒤에야 안다 |
| 모르는 항목은 무시 | 앞으로 생길 입력 재작성 종류가 `Retained` 가 된다 |
| 공개 목록을 디코드하지 않고 모르면 다 보내기 | 지금 masc 가 모르는 종류(`hookRun`·`webSearch` 등)가 흔해서 줄이는 것이 거의 없다 |
| 호스트 내부 `session.jsonl` 의 `context_projection_checkpoint` 읽기 | 공개 규약이 아닌 내부 형식이다. 버전이 바뀌면 말없이 틀린다 |
| N턴마다·M바이트마다 다 보내기 | 추정이다. 압축이 없어도 다 보내고, 압축이 있어도 못 잡는다 |
| dynamic context 전체 digest 비교 | 매 턴 바뀐다(0/306, 0/531) |
| cursor 를 새 필드로 저장 | 저장 형식(`masc.keeper.official-client-session.v2`) hard cut 이 모든 official client 세션을 새로 시작하게 한다. 경계는 이미 저장된 turn id 로 찾고, 사이 읽기의 끝 cursor 는 한 턴 안에서만 쓴다 |

## 5. 측정과 되돌림

배포 전 3일과 배포 뒤 3일을 같은 Muse Keeper 로 비교한다. Muse 주간 한도가 11-09 00:00Z 에 풀리므로 그 뒤에 잰다.

| 값 | 출처 | 목표 |
| --- | --- | --- |
| resume `prompt_bytes` p50 | `system_log` `turn composition` | 20KB 이하(Claude Code 9.5KB) |
| 턴 사이 입력 증가 p50 | 호스트 `model_completed` usage | 지금 35.8k 보다 작음 |
| 100턴당 압축 설치 수 | 호스트 `context_compaction_installed` | 지금보다 작음 |
| 도구 호출당 캐시 안 된 토큰 | 호스트 `model_completed` (input − cache_read) | 지금 45.6k 보다 작음 |
| 판정 분포 | L2 가 남기는 판정 로그 | `Unwitnessed` 를 이유별로, `Rewritten_while_held` 를 그대로 적는다 |

첫 셋이 줄지 않으면 "다시 보낸 context 가 세션 성장의 주원인"이라는 §1.2 가정이 틀린 것이다. 그때는 L3 를 되돌린다.

## 6. 열린 질문

- Q1. 자동 압축 후보가 시작될 때 호스트가 `item/started`(kind `compaction`)를 내는가? L2 전에 살아 있는 세션 하나를 `view/page` 로 읽어 확인한다. 안 내면 §2.4 의 `Rewritten_while_held` 가 더 자주 나온다.
- Q2. 호스트가 compaction 항목 없이 이미 보낸 user message 를 바꾸는 경로가 있는가? 바이너리에 `run.context_slimming`·`context_compaction.tool_result_clearing_enabled` 가 있다. 공식 문서의 `MUSE_TRANSPORT_TRACE=1` 로 연속 턴의 실제 요청을 보고 확인한다. 그런 경로가 있으면 이 RFC 는 멈춘다. §2.3 의 "영향 없음" 줄이 틀리기 때문이다.
