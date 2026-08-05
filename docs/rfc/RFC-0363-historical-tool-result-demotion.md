---
title: Historical tool-result demotion in the bounded transmission view
status: Draft
authors: Claude Opus 5 (1M context)
created: 2026-08-05
supersedes: []
relates_to:
  - RFC-0351 (memory-first context management, compaction sunset) — this implements the L5 tool_result line
  - RFC-memory-os-bounded-context-and-librarian-curator (#26534)
  - "#26545 / #26551 / #26800 (Runtime_model_input_tail_window)"
  - "#25096 (Tool_output / Tool_blob_store externalization)"
---

# RFC-0363 — Historical tool-result demotion in the bounded transmission view

## 0. 한 줄 요약

Tool 결과는 생성 시점에 64 KB 를 넘을 때만 blob 으로 나간다. 라이브 체크포인트 5,540 개 중 그 임계를 넘는 것은 1 개다. 나머지는 히스토리에 인라인으로 영구히 남아 매 요청마다 재전송된다. 최근 구간 밖의 tool 결과를 전송 사본에서만 기존 blob 마커로 강등해, 같은 바이트 예산으로 더 깊은 히스토리를 보낸다.

## 1. 문제 — 실측 (2026-08-05, `trace-1785189111927-00005`)

| 실측 | 값 |
|---|---|
| checkpoint 메시지 | 15,421 |
| checkpoint 직렬화 | 28.2 MB |
| tool 메시지 (인라인) | 5,540 |
| tool 메시지 (이미 마커) | 58 |
| **인라인 tool 바이트** | **20.0 MB = 전체 메시지 바이트의 71%** |
| 인라인 크기 p10 / p50 / p90 / p99 / max | 751 / **2,862** / 8,264 / 10,761 / 67,351 B |
| **현행 임계(65,536 B) 초과 개수** | **1** |

`Tool_bridge.maybe_externalize` 의 기본 임계는 `Common.max_tool_output_bytes` = 65,536 (`lib/core/common.ml:102`). 중앙값 tool 결과는 그 1/23 이다. **쓰기 시점 externalization 은 이 분포에서 사실상 발화하지 않는다.**

### 1.1 이득은 요청 축소가 아니라 히스토리 깊이다

`Runtime_model_input_tail_window` 는 이미 요청을 예산에 맞춘다 — 실측상 이 trace 는 히스토리의 1.9–4.7% 만 전송된다. 인라인 tool 바이트가 71% 를 차지하므로, **모델이 보는 깊이의 대부분을 오래된 tool 출력이 잡아먹는다.**

강등이 사는 것은 **예산당 원자 수**다.

### 1.2 외부 수렴

세 개 하네스가 같은 것을 한다 (2026-08-05 업스트림 소스 직독):

| 시스템 | 메커니즘 |
|---|---|
| claude-code 2.1.222 | 최신 5 개 tool_use id 유지, 나머지는 디스크 spill 후 경로 + 2 KB 프리뷰로 치환 |
| openclaw `80da6166` | `role==='toolResult'` 만 prunable, 최근 3 assistant 턴 보호 |
| hermes-agent `1be70d63` | `_prune_old_tool_results`. 코드 주석: *"old tool outputs otherwise ride in history and are re-sent verbatim on every subsequent turn"* |

MASC 만 per-result cap 만 갖고 **히스토리 pass 가 없다**.

### 1.3 RFC-0351 과의 관계

RFC-0351 §4 타입 수명이 이미 이 줄을 적어놓았다:

> `tool_result` — **사이클 스코프** — 닫힌 사이클은 조립 시 축약/스필 대상

본 RFC 는 그 줄의 구현이다. 새 정책이 아니다.

## 2. 이미 있는 것

새 저장소·도구·provider 의존이 없다.

| 부품 | 위치 | 제공 |
|---|---|---|
| content-addressed blob store | `lib/tool_blob_store/tool_blob_store.mli` | `put ~bytes ~mime -> Tool_output.t`, sha256 샤딩, atomic, 멱등 |
| 마커 코덱 | `lib/tool_blob_store/tool_output.mli` | `Inline \| Stored of artifact_ref`, `encode_for_oas`, `decode_from_oas` (`Not_marker \| Invalid_marker \| Decoded`) |
| 모델용 페이지 리더 | `lib/keeper/keeper_artifact_read.mli` | sha256 / offset / max_bytes. **이미 모델에 노출** (`keeper_tools_oas_bundle.ml:26`) |
| 원자 라벨링 | `lib/runtime/runtime_model_input_tail_window.ml` | `annotate`, `atoms_per_window = 60` |
| 메시지 측정기 | `keeper_turn_driver_try_provider.ml:261-264` | `Yojson.Safe.to_string (Keeper_context_core.message_to_json msg)` |

## 3. 설계

`model_input_projection` 안, `Runtime_model_input_tail_window.project` **앞**에 강등 단계를 둔다. 전송 사본만 바꾸고 durable state 는 건드리지 않는다 (RFC-0351 §3 L5 "history 재작성 없음").

```
demote ~retain_atoms messages   (* 순수 함수. 예산을 입력으로 받지 않는다 *)
  |> project ~measure_message_bytes ~capacity_bytes ~reserved_bytes
```

### 3.1 강등 대상 — 타입으로 판정한다

`Agent_sdk.Types.ToolResult { content_blocks; content; _ }` 중 **모두** 만족하는 것:

1. `content_blocks = None`
   `api_common.ml:304-321` — `content_blocks = Some blocks` 이면 `content` 는 **직렬화되지 않는다**. 그런 메시지의 `content` 를 마커로 바꾸면 크기가 전혀 줄지 않는데 추정기는 감소를 계상한다. 즉 추정이 **하한**이 되어, window 가 과소평가로 cut 하고 물질화된 요청이 예산을 넘는다. `Some` 은 이미지·문서를 담으며 마커로 표현할 수도 없다.
2. `Tool_output.decode_from_oas content = Not_marker`
   `Decoded` 는 이미 강등된 것이고, **`Invalid_marker` 는 강등하지 않는다** — 마커 모양인데 파싱에 실패한 payload 를 blob 으로 다시 저장하면 손상을 고착시킨다. 세 경우를 exhaustive match 로 다룬다.
3. 원자 인덱스 < `atom_count - retain_atoms`
4. `upper_bound_demoted_bytes msg < measure_message_bytes msg`

판단은 (a) 타입, (b) 정수 비교, (c) 바이트 비교뿐이다. 중요도 점수·문자열 분류·휴리스틱 임계값 없음 (RFC-0351 §2.2).

### 3.2 크기 상한 — 포맷을 복제하지 않고 포화 후보로 측정한다

마커 크기는 "약 200–300 B" 가 아니다. 실측:

| 케이스 | raw | JSON |
|---|---|---|
| ASCII 200 B 프리뷰 | 321 B | 325 B |
| **한국어 200 B 프리뷰** | 867 B | **1,053 B** |
| 포화 최악 (200×0xFF, 19 자리 count) | 950 B | **1,154 B** |

`encode_for_oas` (`tool_output.ml:132-133`) 는 프리뷰를 `%S` 로 넣는다 = `String.escaped`, 0x20–0x7E 밖 모든 바이트가 `\ddd` 4 자로 팽창한다. `make_preview` (`tool_blob_store.ml:101-112`) 는 0x20 미만만 제거하므로 0x7F–0xFF 는 살아남는다. 그 뒤 Yojson 이 backslash 를 다시 2 배로 만든다 — 상위 바이트당 **5×**. **MASC 의 tool 출력은 일상적으로 한국어 UTF-8 이고, 그 모든 바이트가 0x80 이상이다.**

따라서 포맷 산술을 강등 모듈이 복제하면 안 된다. 대신:

```
upper_bound_demoted_bytes msg =
  measure_message_bytes
    (msg with content = encode_for_oas (Stored saturating_ref))
where saturating_ref = make_artifact_ref
  ~sha256:(String.make 64 'f')
  ~bytes:(String.length content)
  ~preview:(String.make Tool_blob_store.preview_max '\255')
  ~mime:(* 실제 물질화가 쓸 mime 과 동일 *)
```

**window 가 쓰는 바로 그 `measure_message_bytes`** 를 통과시킨다. 해싱 없음, I/O 없음, 포맷 지식 없음. 실제 마커는 항상 이보다 작거나 같다.

### 3.3 `preview_max` 를 export 한다

`preview_max = 200` 은 현재 `tool_blob_store.ml:99` 에 있고 `.mli` 에 없다. `make_artifact_ref` 는 프리뷰 길이를 검사하지 않는다. 강등 모듈이 `200` 을 하드코딩하면, 나중에 `preview_max` 를 올리는 변경이 상한을 조용히 하한으로 바꾼다 — CLAUDE.md 가 금지하는 silent failure 다.

`val preview_max : int` 를 `tool_blob_store.mli` 에 공개하고, 강등은 그것만 참조한다.

### 3.4 경계는 꼬리에서 움직인다 — 초안의 오류 정정

초안은 강등 경계를 `atom_count` 로 양자화했다. 그것은 틀렸다: window 의 `drop` 은 `available_bytes` 로 결정되므로 두 경계는 **양자만 같고 트리거가 다르다**. `atom_count` 119 → 120 이고 예산이 넉넉해 `drop = 0` 인 순간, 강등 경계만 0 → 60 으로 뛰어 원자 0–59 가 원문에서 마커로 뒤집힌다. window jump 없는 **prompt-cache 전량 미스** — §1.2 가 인용한 #26535 의 비용 그 자체다.

정정: 강등은 **최신 `retain_atoms` 개를 제외한 전부**로 정의한다. 예산과 무관한 순수 함수다.

이 경계는 매 턴 1 원자씩 **꼬리 방향**으로 전진한다. 캐시는 prefix 로 매칭되므로, 오래된 쪽은 계속 마커로 고정돼 있고 바뀌는 지점은 캐시 커버리지의 **끝**이다. 커버리지는 줄지 않고 늘어난다. cut 은 여전히 머리에서 양자화된 채 움직인다 — 두 경계가 서로 다른 끝에 있으므로 간섭하지 않는다.

### 3.5 `retain_atoms`

RFC-0351 §3 이 최근 창을 명시적으로 허용한다:

> L5 의 "최근 창"은 recency 구조이지 중요도 판단이 아니다. keeper 는 일직선 타임라인이므로 최근성은 타임라인의 구조 자체다.

값은 실측 근거가 없다. 초기값을 `atoms_per_window` (60) 로 두고 §6 에서 측정 후 조정한다. 리터럴 금지 — named constant 로 `.mli` 에 공개하고 "empirically tuned, see RFC-0363 §6" 주석을 단다.

### 3.6 물질화와 실패

1단계는 포화 후보로 측정만 한다. 2단계는 cut 을 살아남은 강등 메시지에 대해서만 `Tool_blob_store.put` 한다.

`put` 실패 시 해당 메시지는 인라인으로 되돌린다. 그러면 실제 크기가 추정보다 **커지므로**, 물질화 후 반드시 재측정하고 초과 시 `project` 를 다시 돌린다. 조용한 통과 금지 — 실패는 typed 결과로 올라오고 카운터가 아니라 재조립으로 대응한다.

### 3.7 blob 수명 — 강등 blob 은 파생 데이터다

강등이 만드는 blob 은 durable 참조를 갖지 않는다 (전송 사본은 영속되지 않는다). `tool_blob_maintenance.mli` 의 계약상:

- GC 는 **startup 경계에서만** 돌고, `Delete_previous_candidates` 는 **이전 스냅샷의 후보였고 새 완전 스캔에서도 미참조인** 해시만 지운다 — 삭제까지 **연속 2 회 startup 스캔**이 필요하다.
- 그 사이 강등은 매 턴 같은 내용을 다시 `put` 한다. content-addressed 이므로 같은 sha 로 복원된다.

즉 강등 blob 은 **체크포인트에 원문이 살아 있는 파생 캐시**다. 지워져도 다음 강등이 되살린다.

알려진 한계: 모델이 **이전 턴의 마커 sha** 를 현재 전송 집합 밖에서 읽으려 하면 startup 2 회 이후 not-found 가 될 수 있다. `keeper_artifact_read` 가 typed not-found 를 반환해야 하며, 모델이 행동할 수 있는 신호여야 한다. 현행 window 는 그 내용을 상수 스텁으로 **회수 시도조차 불가능**하게 버리므로, 강등은 엄격한 개선이다.

`durable_consumer_basenames` 에 추가할 소비자는 없다 — 참조를 영속하지 않기 때문이다.

## 4. 검토한 대안

### 안 B — 쓰기 임계 인하 + 최근 구간 재수화

`default_externalize_threshold_bytes` 를 65,536 → 약 4,096 으로 낮추고, projection 에서 최신 유지 구간의 마커만 blob 에서 인라인으로 되돌린다.

- **유일하게 checkpoint 28.2 MB 도 줄이는 안이다.** 본 RFC 채택 후에도 durable 히스토리는 계속 자란다.
- 매 턴 해싱 없음 (blob 은 생성 시 1 회).
- 대신 durable 포맷이 바뀌고, **모델이 자기 턴의 tool 출력을 마커로 받으면 안 된다**는 보장이 새로 필요하다. 그 보장이 깨지면 모델이 자기 출력을 읽으려 `keeper_artifact_read` 를 호출하는 낭비가 매 턴 발생한다.
- `Common.max_tool_output_bytes` 의 다른 소비자 blast radius 조사가 선행되어야 한다 (본 RFC 범위 밖, 미조사).

채택하지 않는 이유는 롤백 비용이다. 본 RFC 는 projection 단계 제거로 되돌아가고, 안 B 는 durable 포맷을 되돌려야 한다. 다만 **checkpoint 크기 문제는 본 RFC 가 풀지 않는다**는 사실을 기록한다 — 후속 RFC 로 남긴다.

## 5. 비목표

- 컴팩션 파이프라인 투자 — RFC-0351 §8 금지.
- 자동 컴팩션 트리거 복구 — 별건. receipt 없는 window 로 트리거를 쏘면 조용한 손실이 예정된 조용한 손실이 된다.
- durable 히스토리 재작성.
- checkpoint 크기 축소 (안 B 의 영역).
- 중요도 점수 · 문자열 분류 · 휴리스틱 임계값 — RFC-0351 §2.2.

## 6. 검증

| 지표 | 현재 | 목표 |
|---|---|---|
| 인라인 tool 바이트 / 전송 바이트 | 71% (durable 기준) | 전송 기준 측정 후 확정 |
| 같은 예산에서 전송되는 원자 수 | 실측 필요 | 증가 |
| byte-cap bind rate | 8.3% (GLM 24.5%) | 감소, 그리고 **단조 증가 중단** |
| **prefix 안정성** | cut 이 바뀔 때만 변경 | **불변** |

필수 회귀 테스트:

1. **prefix 불변식** — 원자를 1 개씩 늘리며 전송 리스트의 *머리*가 `drop` 이 바뀔 때만 바뀌는지. 초안의 "60 원자 경계에서만 바뀌는지"는 **잘못된 불변식**이었다: 오늘 그 경계에서는 prefix 가 아예 안 바뀌므로 버그가 있어도 통과한다.
2. **상한 건전성** — 임의 payload(ASCII / 한국어 / 0x00–0xFF 전 범위)에 대해 `upper_bound_demoted_bytes ≥ measure_message_bytes (물질화된 마커 메시지)`.
3. **`content_blocks = Some` 제외** — 그런 메시지는 강등되지 않고 크기가 변하지 않는다.
4. **`Invalid_marker` 제외** — 손상된 마커 모양 payload 는 그대로 둔다.
5. **`put` 실패 경로** — 인라인 복귀 후 재측정이 실제로 일어나고, 요청이 예산을 넘지 않는다.

## 7. 리스크

| 리스크 | 완화 |
|---|---|
| 상한이 하한이 되어 요청 초과 | §3.2 포화 후보를 실제 측정기로 통과. §6 테스트 2 |
| `content_blocks = Some` 오계상 | §3.1 조건 1. §6 테스트 3 |
| prompt-cache 회귀 | §3.4 꼬리 경계. §6 테스트 1. 실패 시 머지 금지 |
| `preview_max` 변경이 상한을 깸 | §3.3 export 후 단일 참조 |
| `put` 실패 후 조용한 초과 | §3.6 재측정 필수. §6 테스트 5 |
| 강등 blob GC 후 not-found | §3.7 — 파생 데이터, 다음 강등이 복원. typed not-found 필요 |
| checkpoint 는 계속 자람 | 본 RFC 비목표. 안 B 후속 RFC |
