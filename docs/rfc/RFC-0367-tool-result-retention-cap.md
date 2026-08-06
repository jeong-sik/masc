---
title: Durable tool-result retention cap in keeper session checkpoints
status: Draft
authors: Kimi Code
created: 2026-08-05
supersedes: []
relates_to:
  - RFC-0363 (historical tool-result demotion in the bounded transmission view) — 전송 사본 측. 본 RFC 는 그 §4 안 B / §7 "checkpoint 는 계속 자람" 의 durable 측 후속이다.
  - RFC-0351 (memory-first context management, compaction sunset — S1 이 checkpoint purge R1–R3 와 `cleared_tool_result_content` 마커를 도입)
---

# RFC-0367 — Durable tool-result retention cap in keeper session checkpoints

## 0. 한 줄 요약

장수 keeper 세션의 OAS 체크포인트는 tool 결과 원문을 영구히 인라인으로 쌓아 매 기록마다 수십 MB 를 통째로 직렬화/기록/로드한다. 체크포인트 기록 시점에 **최신 N 개(기본 1,000) tool 결과만 원문으로 유지**하고, 초과분은 `Keeper_checkpoint_purge` R3 와 같은 고정 마커(`cleared_tool_result_content`)로 강등한다. 삭제가 아니라 치환이므로 tool_use↔tool_result pairing 불변식이 유지되고, 연산은 멱등이다.

## 1. 문제 — 실측 (2026-08-05, sangsu 세션 `trace-1785189111927-00005`)

| 실측 | 값 |
|---|---|
| checkpoint 메시지 | 19,235 |
| 메시지 총 바이트 | ~57 MB |
| tool 메시지 (인라인) | 7,390 개 / **39.5 MB (69%)** |
| assistant 메시지 | 17.6 MB |
| **최신 1,000 개 tool 결과 바이트** | **15.0 MB** |
| 초과분 (6,390 개) 강등 시 절감 | **~24.6 MB** |

- 세션은 살아 있는 동안 계속 자란다. 이 세션은 같은 날 RFC-0363 실측(15,421 msg / 28.2 MB) 대비 몇 시간 만에 메시지 바이트가 2 배가 되었다.
- 매 체크포인트 기록마다 전체 메시지가 직렬화되어 디스크에 쓰이고, 턴마다 전체가 다시 로드/재측정된다. tool 결과 초과분은 이 IO/CPU 의 대부분을 차지하면서 **전송에는 거의 기여하지 않는다** — `Runtime_model_input_tail_window` 가 히스토리의 한 자릿수 % 만 보내고, 그 안에서도 최신 구간이 우선이다.
- RFC-0363 은 전송 사본(transmission view)의 강등을 다루고 durable 히스토리는 "후속 RFC 로 남긴다"고 명시했다 (§4 안 B, §7). 본 RFC 가 그 후속이다.

### 1.1 외부 수렴

결정론적 prune 우선은 업계 표준이며, durable 측도 같은 방향이다 (2026-08-05 조사):

| 시스템 | durable / 전송 정책 |
|---|---|
| claude-code | 오래된 tool 출력을 디스크 spill 후 경로 + 프리뷰 마커로 치환 |
| openclaw | `toolResult` 만 prunable, 최근 assistant 턴 보호 |
| hermes-agent | `_prune_old_tool_results` — compaction 전에 결정론적 prune 먼저 |
| codex | `tool_output_token_limit` 상한 |

공통점: **LLM compaction 에 맡기지 않고 타입/개수 기반 결정론적 규칙이 먼저 돈다.** 본 RFC 도 같은 계열이다.

## 2. 이미 있는 것

새 저장소·도구·provider 의존이 없다.

| 부품 | 위치 | 제공 |
|---|---|---|
| purge 파이프라인 | `lib/keeper/keeper_checkpoint_purge.mli` | R1–R3 규칙, `purge : config -> Checkpoint.t -> (Checkpoint.t * report, purge_error) result` |
| 고정 마커 | R3 `cleared_tool_result_content` | 닫힌 사이클 ToolResult 를 IO 없이 고정 문자열로 치환. **원문은 `.masc/tool_calls/` 로그에 이미 영속**되어 있어 blob 불필요 |
| closed-cycle 판정 | `Keeper_checkpoint_purge` R3 | tool_use↔tool_result 사이클이 닫힌 것만 건드림 |
| 저장 경계 훅 | `lib/keeper/keeper_agent_run.ml:864` `checkpoint_sink` | `Keeper_checkpoint_store.save_oas_classified` 호출 직전 변환 지점 |
| 런타임 튜너블 | `lib/runtime_settings.ml` + `runtime_params.json` | `keeper.*` 키 패턴 (`register_int` + surface catalog + `Runtime_params.get`). 노 하드코딩 (projects.md) |

주의: purge 의 라이브 훅은 현재 **0 건**이다 — 호출자는 offline CLI (`bin/masc_checkpoint_purge.ml`) 와 테스트뿐이다. 본 RFC 의 배선은 이 저장 경계에 **새 라이브 훅을 추가**하는 것이다.

## 3. 설계

### 3.1 규칙 (R4 — retention cap)

`Keeper_checkpoint_purge` 모듈에 cap 전용 함수(가칭 `cap_tool_results`)를 추가한다. full `purge` 에 config 필드를 얹지 않는다 — 라이브 sink 에 R1(dedup, 메시지 drop)/R2(thinking strip)까지 켜는 것은 본 RFC 범위 밖의 durable 변경이고, cap 은 **치환만** 하므로 전용 함수가 최소 침습이다. 기존 `partition` / `clear_tool_result_blocks` / `validate` 를 재사용한다.

체크포인트 기록 시 (`cap > 0` 일 때):

1. 닫힌 접두부(`closed_prefix`) 안의 `ToolResult` 블록 중 **마커가 아닌** 것만 카운트한다 (마커는 카운트 제외 — §3.3 멱등성). 열린 꼬리(`protected_suffix`, 진행 중인 사이클)는 구조상 건드리지 않는다.
2. **꼬리 기준 최신 `cap` 개는 그대로 둔다.**
3. 그보다 오래된 것은 R3 와 동일하게 `cleared_tool_result_content` 로 치환한다.

`cap = 0` 이면 입력을 그대로 반환한다 (비활성).

### 3.2 왜 blob 마커가 아니라 고정 마커인가

- 전체 tool I/O 는 이미 `.masc/tool_calls/` 로그에 영속된다. checkpoint 안의 원문은 사본이며, 회수가 필요하면 그 로그가 SSOT 다.
- 고정 마커는 checkpoint 기록 경로에 **새 IO 를 추가하지 않는다** (해싱 없음, `Tool_blob_store.put` 없음). 이 규칙의 목적이 기록 IO 절감인데 blob 물질화가 그 비용을 다시 만들면 자기모순이다.
- 모델이 보는 전송 사본은 RFC-0363 의 projection 이 별도로 다룬다. durable cap 은 전송 경로와 무관하게 checkpoint 크기만 줄인다.

### 3.3 멱등성과 안정성

- 마커로 치환된 ToolResult 는 카운트에서 제외되므로, 두 번째 purge 부터는 같은 입력에 같은 출력이다 (멱등).
- 경계가 새 tool 결과 N 개만큼 앞으로 이동하면 그만큼만 새로 마커가 된다. durable 사본이므로 prompt-cache 관심사는 없다 (전송 사본은 RFC-0363 의 원문 cut anchor 가 지배).
- 치환이라 삭제가 아니므로 메시지 수·pairing·인덱스가 보존되고, API 의 tool_use↔tool_result pairing 검증(400) 위험이 없다.
- 입력·출력 모두 기존과 같이 `Keeper_compaction_unit.validate` 를 통과한다.

### 3.4 배선

`keeper_agent_run.ml:864` 의 `checkpoint_sink` 에서 `save_oas_classified` 호출 직전에 `Keeper_checkpoint_purge.cap_tool_results ~cap` 을 적용한다 (`cap` 은 §3.5 튜너블에서 읽는다). 변환은 persisted copy 에만 일어나고 OAS in-memory 세션은 건드리지 않는다 — 다음 턴 로드부터 적용된다. **OAS 경계 불침범** (OAS 는 MASC 를 모른다). 이것이 purge 모듈의 첫 라이브 훅이다.

### 3.5 튜너블

`runtime_params.json` 키 `keeper.session_tool_result_cap`:

- 기본값 `1000`
- `0` = 비활성 (기존 동작 그대로)

`Runtime_settings.ml` 의 기존 `keeper.*` 패턴을 따른다. 코드에 리터럴 상수를 박지 않는다.

## 4. 효과와 한계 (정직한 기대치)

| 지표 | 현재 (sangsu) | 기대 |
|---|---|---|
| checkpoint 직렬화 바이트 | ~44 MB | ~20 MB 수준 (실측 검증 필요) |
| 턴당 checkpoint 기록/로드 IO·CPU | 전체 메시지 | 대략 절반 이하 |
| durable 히스토리 증가율 | 무상한 | tool 바이트는 상한 내로 포화 |
| **모델 입력 토큰** | 70–146k | **불변** |

마지막 줄이 중요하다: 모델 요청 크기는 이미 `config/runtime.toml` 의 `max-request-body-bytes` (512 KB raw cut) 와 tail-window 가 지배한다. 본 RFC 는 **durable 저장·IO·로드 비용**을 줄이는 것이지 토큰 비용을 줄이는 것이 아니다. 토큰 측은 별건이다.

## 5. 비목표

- LLM compaction 투자 — RFC-0351 §8 금지.
- 전송 사본 강등 — RFC-0363 의 영역.
- assistant thinking / ingress truncation 절감 — 별건.
- `.masc/tool_calls/` 로그 보존 정책 — 그 로그는 그대로 둔다.

## 6. 검증

필수 회귀 테스트 (`test_keeper_checkpoint_purge` 패턴):

1. **cap 준수** — tool 결과 cap+K 개 입력 시 최신 cap 개만 원문, 나머지는 마커.
2. **멱등** — purge 출력에 다시 purge 를 적용해도 동일.
3. **pairing 보존** — 메시지 수·순서·tool_use/tool_result 대응 불변.
4. **닫히지 않은 사이클 보호** — 미완결 tool 호출의 결과는 cap 초과분이어도 치환되지 않는다.
5. **cap=0 비활성** — 기존 동작과 바이트 동일.
6. **R1–R3 무회귀** — 기존 purge 테스트 전부 통과.

빌드/검증: `scripts/dune-local.sh build test/<신규>.exe`, 인접 테스트, `ocamlformat --check`.

## 7. 리스크

| 리스크 | 완화 |
|---|---|
| cap 경계 부근 정보 손실로 keeper 판단 저하 | 최신 1,000 개 = 15 MB 유지. 원문 SSOT 는 `.masc/tool_calls/` 로그에 잔존 |
| 마커 카운트 포함 시 cap 드리프트 | §3.3 — 마커는 카운트 제외, 멱등 테스트 2 |
| 미완결 사이클 치환으로 API 400 | §3.1 closed-cycle 판정 재사용, 테스트 4 |
| 튜너블 미적용 경로 | sink 에서만 config 를 채우고 기본 비활성 아님 — 기존 purge 호출부 전수 확인 |
| OAS 경계 침범 | persisted copy 만 변환, in-memory 무간섭 |
