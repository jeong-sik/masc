---
rfc: "durable-tool-result-markers"
title: "지난 턴의 도구 결과는 체크포인트에도 blob 주소로 저장한다"
status: Draft
created: 2026-09-15
updated: 2026-09-15
author: claude
supersedes: []
superseded_by: null
related: ["0363", "main-domain-scheduler-latency"]
---

# RFC — 지난 턴의 도구 결과는 체크포인트에도 blob 주소로 저장한다

## 0. 요약

RFC-0363 은 지난 턴의 도구 결과를 **모델에 보내는 사본에서만** blob 주소(marker)로 바꾼다. 체크포인트에는 본문이 그대로 남는다. 그래서 두 가지 비용이 히스토리 길이만큼 계속 커진다.

- 턴마다 체크포인트 전체를 읽고, 턴의 첫 저장에서 모든 메시지를 다시 인코딩한다. 도구 결과 본문도 매번 같이 읽고 쓴다.
- 모델 요청마다 지난 도구 결과 전부를 다시 marker 로 바꾸고, blob 파일을 SHA-256 계산과 fsync 두 번으로 다시 쓴다. 한 턴에 요청이 수십 번 나간다.

이 RFC 는 체크포인트를 저장할 때 **지난 턴의 도구 결과를 blob 에 먼저 durable 하게 쓰고, 체크포인트에는 marker 를 저장**하게 바꾼다. 모델이 보는 내용은 지금과 같다. 현재 턴의 결과는 계속 본문 그대로 둔다. 체크포인트 형식은 바뀌지 않는다. marker 는 이미 도구 결과 `content` 에 들어갈 수 있는 문자열이기 때문이다.

RFC-0363 §4 가 "checkpoint 크기 문제는 본 RFC 가 풀지 않는다 — 후속 RFC 로 남긴다" 고 적은 그 후속이다. RFC-main-domain-scheduler-latency §0 의 4단계 목표("체크포인트는 messages 본문 대신 blob 참조")와 09-07 결론("다음 레버는 옮기기가 아니라 덜 할당하기")도 이 방향을 가리킨다.

## 1. 문제 — 2026-09-15 실측

측정한 서버는 `masc start` 하나(PID 4660, 19:36 기동)다. 명령은 §4 에 그대로 적는다.

| 실측 | 값 | 방법 |
|---|---|---|
| `/health/live` 첫 바이트까지 | 0.25 / 0.92 / 1.5 / 4.7 / 6.0 초 (연결은 0.001초) | `curl -w '%{time_starttransfer}'` 연속 5회 |
| 메인 스레드가 바쁜 비율 | 4,761 샘플 중 3,469 (73%) | `sample <pid> 12` 의 main-thread |
| 그중 `materialize` 의 `List.find_map` | 427 샘플 (12%) | 같은 샘플. #36647 로 표 조회로 바꿨다 |
| 큰 체크포인트 8개 | 27–110 MB, 합 461 MB | `<base-path>/.masc/traces/<trace>/<trace>.json` 크기 |
| 같은 8개의 trace 폴더 | 0.35–1.45 GB (history 스냅샷 최대 12벌) | 폴더 합계 |
| 1~2.5분 동안 다시 쓰인 blob 파일 | 2,776개 (2,000개 표본 합 11 MB) | `find <base-path>/.masc/tool_blobs -type f -mmin -1` |
| 한 턴의 provider 요청 수 | 83회(turn 12263), 62회(turn 15638) | `keeper_turn_driver_try_provider.ml` 의 memo 주석, wire capture 실측 |

도구 결과가 체크포인트에서 차지하는 몫은 이렇다. 본문이 marker 보다 큰 결과만 셌다. marker 크기는 추정값이다(고정부 약 110바이트 + 바이트 수 자릿수 + 앞 200바이트 미리보기의 escape 길이).

| 체크포인트 | 크기 | 바꿀 수 있는 결과 | 본문 | marker 로 바꾸면 | 줄어드는 몫 |
|---|---|---|---|---|---|
| glm-5-3-flash (`…311286-00006`) | 109.8 MB | 7,686개 | 36.2 MB | 약 2.7 MB | 약 33.6 MB (31%) |
| deepseek-v4-1-flash (`…308552-00005`) | 107.1 MB | 3,987개 | 26.5 MB | 약 1.4 MB | 약 25.0 MB (23%) |
| glm-5.3-flash (`…314416-00007`) | 77.5 MB | 4,401개 | 25.4 MB | 약 1.6 MB | 약 23.9 MB (31%) |

나머지 큰 몫은 스트리밍 `reasoning_details` 조각이다(8개 합 190 MB, 41%). 그 조각은 이 RFC 범위가 아니다(§6).

### 1.1 전송 사본만 바꾸면 남는 것

RFC-0363 은 durable state 를 건드리지 않는 쪽을 골랐다. 되돌리기 쉬워서다. 그 대가로 아래 일이 요청마다, 턴마다 히스토리 전체에 대해 되풀이된다.

1. **턴 시작**: `Keeper_run_context` 가 `load_context_from_checkpoint` 로 체크포인트 전체를 디코드한다. 도구 결과 본문 36 MB 도 같이 문자열로 만든다.
2. **요청마다**: `Keeper_model_input_demotion.plan` 이 지난 도구 결과마다 포화 marker 를 만들어 크기를 잰다. `materialize` 는 살아남은 결과마다 `Tool_blob_store.put` 을 부른다. put 은 SHA-256 을 계산하고 임시 파일에 쓴 뒤 fsync 하고, rename 하고, 부모 디렉터리를 fsync 한다(`Fs_compat.save_file_atomic`). 캡이 없는 경로(`keeper_turn_driver_try_provider.ml` 의 uncapped materialize)에서는 지난 결과 전부가 대상이고, 메인 fiber 에서 돈다.
3. **턴의 첫 저장**: 디코드한 메시지는 새 값이라 인코딩 캐시가 비어 있다. 모든 메시지를 다시 인코딩한다. 도구 결과 본문도 다시 JSON escape 한다.

blob 은 내용 주소라서 2번이 쓰는 파일은 매번 같은 내용이다. 같은 바이트를 요청마다 디스크에 다시 쓰고 있다.

## 2. 지금 흐름 — 만드는 곳, 저장하는 곳, 읽는 곳

| 단계 | 위치 | 도구 결과 본문을 어떻게 다루나 |
|---|---|---|
| 만든다 | 도구 실행 → `Agent_core.Types.ToolResult { content; content_blocks; _ }` | `Tool_bridge.default_externalize_threshold_bytes` 를 넘으면 생성 때 blob 으로 나간다(`tool_bridge.ml`, `keeper_tool_execute_runtime.ml`). 나머지는 본문 그대로다 |
| 저장한다 | `Keeper_checkpoint_store.save_agent_core_classified_with_encoding_memo` → `Checkpoint.to_string_with_encoding_memo` → `Keeper_fs.save_encoded_durable_atomic_from` | `content` 문자열을 그대로 인코딩한다(`checkpoint_codec.ml` `checkpoint_tool_result_to_json`). 저장 뒤 이전 canonical 파일은 history 스냅샷으로 hard link 된다(최대 12벌) |
| 읽는다 | `Keeper_checkpoint_store.load_agent_core` (턴 시작, 상태 상세, 대시보드 체크포인트 API, 거절 round-trip 기록) | `content` 를 문자열로 되살린다. 디코드 때 `json` 은 항상 `None` 이다(`checkpoint_codec.ml:424`) |
| 모델에 보낸다 | `Keeper_turn_driver_try_provider` → `Keeper_model_input_demotion.plan`/`materialize` | 현재 턴 이전 결과를 marker 로 바꿔 보낸다. blob 은 요청마다 다시 쓴다 |
| 모델이 본문을 다시 읽는다 | `keeper_artifact_read` (sha256 · offset · max_bytes) | blob 에서 페이지로 읽는다 |
| 반복 호출을 찾는다 | `Keeper_run_tools_setup` history pair → `Keeper_tool_progress_identity.output_fingerprint` | marker 면 저장 주소(sha·bytes·mime)로, 본문이면 본문 지문으로 계산한다. **두 지문은 같은 내용이어도 다르다** |
| 훅이 최근 결과를 본다 | `Keeper_official_client_host.last_tool_results`, `Keeper_run_tools_hooks` | 마지막 Tool 메시지만 본다. 현재 턴이다 |
| 대시보드 | `server_dashboard_http_keeper_api_checkpoints.ml` 요약·미리보기, `GET /api/v1/artifacts/<sha256>` (CanAdmin) | 체크포인트 요약과 blob 본문을 따로 준다 |
| blob 청소 | `Tool_blob_maintenance.run` (배포 전 helper, BasePath lease 를 잡은 오프라인에서만) | `durable_consumer_basenames` 의 `traces`·keeper 런타임 디렉터리 안 marker 를 살아 있는 참조로 센다 |

## 3. 설계

### 3.1 저장 규칙

체크포인트를 저장할 때마다, 저장할 메시지 목록에서 아래를 **모두** 만족하는 도구 결과를 marker 로 바꿔 저장한다.

1. `ToolResult` 이고 `content_blocks = None` 이다. `Some` 이면 provider 인코더가 `content` 를 내보내지 않으므로 바꿔도 줄지 않는다(RFC-0363 §3.1 과 같은 이유).
2. `Tool_output.decode_from_agent_core content = Not_marker` 다. `Decoded` 는 이미 marker 이고, `Invalid_marker` 는 손상을 고정하지 않도록 그대로 둔다.
3. 현재 턴보다 앞선 원자에 속한다. 경계는 모델 입력이 이미 쓰는 `Runtime_model_input_tail_window.first_atom_at_or_after messages ~message_index:<현재 턴 시작 메시지 수>` 로 계산한다. 현재 턴의 결과는 본문 그대로 저장한다. 턴이 쓰고 있는 결과를 marker 로 받으면 모델이 자기 출력을 다시 읽으려 artifact read 를 부르게 된다(RFC-0363 §4 안 B 의 문제).
4. 실제 marker 가 본문보다 작다. 저장 시점엔 진짜 marker 를 만들 수 있으니 포화 후보가 아니라 실제 값으로 비교한다.

판정은 타입, 정수 비교, 바이트 비교뿐이다. 중요도 점수나 문자열 분류는 없다.

턴 시작 메시지 수는 저장을 부르는 쪽(`keeper_agent_run.ml` 의 턴 안 저장, `keeper_agent_run_finalize_response.ml` 의 마감 저장)이 이미 가진 `initial_messages` 에서 온다. 저장소 함수는 그 값을 인자로 받는다. 저장소가 턴을 추측하지 않는다.

### 3.2 쓰는 순서

1. 바꿀 결과마다 `Tool_blob_store.put_durable` 로 blob 을 쓴다. 본문과 부모 디렉터리가 모두 fsync 된 뒤에만 주소를 받는다.
2. 받은 주소로 marker 를 만들어 메시지를 바꾼다.
3. 체크포인트를 지금처럼 원자적으로 쓴다.

체크포인트는 durable 하지 않은 blob 을 가리키지 않는다. 1과 3 사이에 죽으면 아무도 가리키지 않는 blob 이 남는다. 청소가 두 번의 스캔 뒤 지운다. `put_durable` 이 실패하면(`Sys_error`) 그 결과는 본문 그대로 저장하고, 실패 수를 저장 결과에 typed 로 담는다. 저장 자체는 막지 않는다. 다음 저장이 다시 시도한다.

같은 결과는 한 번만 바뀐다. 한번 marker 로 저장된 결과는 다음 저장에서 규칙 2에 걸려 건너뛴다. 그래서 blob 쓰기는 **턴마다 그 직전 턴의 결과만큼만** 일어난다.

### 3.3 형식, 하드컷, 옛 데이터

- 체크포인트 형식은 바뀌지 않는다. marker 는 지금도 `content` 에 들어가는 문자열이다(생성 때 외부화 기준을 넘은 결과가 이미 이렇게 저장된다). 코덱·버전·reader 를 바꾸지 않는다.
- **옛 체크포인트를 위한 변환 코드를 만들지 않는다.** 이 규칙의 입력은 "지금 저장하는 히스토리 안에서 현재 턴보다 앞선 결과" 다. 언제, 어느 바이너리가 만든 결과인지는 보지 않는다. 어제 만든 결과와 1분 전에 만든 결과에 같은 규칙이 적용된다. 그래서 이미 쌓인 체크포인트도 다음 저장에서 같은 규칙으로 줄어든다. 버전을 판별하는 분기나 한 번만 도는 migration 이 없다.
- 첫 저장은 무겁다. 큰 keeper 의 첫 저장은 결과 수천 개를 한꺼번에 `put_durable` 한다(glm 체크포인트 7,686개, 36 MB). SHA-256 계산은 저장소가 인코딩에 이미 쓰는 pool 작업(`offload_checkpoint_cpu` → `Domain_pool_ref.submit_cpu_or_inline`)으로 보내고, 파일 쓰기는 이름 붙은 systhread 경계로 보낸다. 메인 fiber 에서 돌리지 않는다. 한 번 지나면 다음 저장부터는 직전 턴 몫만 남는다.
- 새 바이너리가 쓴 체크포인트를 옛 바이너리가 읽어도 문제가 없다. marker 는 옛 바이너리의 모델 입력 경로(`Decoded` 건너뜀)와 artifact read 가 이미 다룬다. 되돌려도 marker 는 marker 로 남는다. 본문을 체크포인트로 다시 넣는 코드는 만들지 않는다. 본문은 blob 에서 읽을 수 있다.

### 3.4 blob 수명 — 파생 데이터에서 원본으로

지금 강등 blob 은 "체크포인트에 원문이 살아 있는 파생 캐시" 다(RFC-0363 §3.6). 이 RFC 뒤에는 **지난 결과의 원본이 blob 에만 있다.** 그래서 수명 규칙을 다시 확인해야 한다.

- 체크포인트는 `<base-path>/.masc/traces/` 아래에 있고, `traces` 는 이미 `Tool_blob_maintenance.durable_consumer_basenames` 에 있다. history 스냅샷도 같은 폴더다. 그래서 체크포인트와 스냅샷 안의 marker 는 **등록 변경 없이** 살아 있는 참조로 세어진다. 청소 모듈 문서("durable 참조를 새로 저장하는 변경은 같은 변경에서 소비자 등록")를 이미 만족한다.
- 청소는 오프라인 helper 가 BasePath lease 를 잡은 동안만 돌고, 연속 두 번의 완전 스캔에서 참조가 없어야 지운다. `<base-path>/.masc/clusters` 가 비어 있지 않으면 청소 자체를 멈춘다. 이 조건은 그대로 둔다.
- `fetch` 는 파일의 SHA-256 을 확인하고, 다르면 `Integrity_mismatch` 를 돌려준다. 손상은 조용히 지나가지 않는다.
- 달라지는 위험: `tool_blobs` 를 잃으면 지난 결과 본문을 잃는다. trace 폴더만 복사하면 본문이 따라가지 않는다. §9 의 결정 1 이다.

### 3.5 모델이 보는 것과 요청마다 하던 일

- 모델이 보는 내용은 같다. 지난 결과는 지금도 marker 로 가고, 현재 턴 결과는 본문으로 간다. marker 문자열은 같은 본문이면 같다(내용 주소 + 결정적 미리보기).
- 요청마다 `plan` 은 지난 결과 대부분을 `Decoded` 로 보고 건너뛴다. 새로 바꿀 대상은 "현재 턴 시작부터 그 턴의 첫 저장 전까지" 의 직전 턴 결과뿐이다. `materialize` 의 blob 쓰기도 그 수만큼 줄어든다.
- `plan`·`materialize` 자체를 지우지는 않는다. 턴 시작과 첫 저장 사이 요청을 위해 필요하고, 저장이 `put_durable` 실패로 본문을 남긴 결과를 위해서도 필요하다. 단계 3(§8)에서 요청마다 남은 비용을 다시 재고, 지울 수 있는지 판단한다.

### 3.6 운영자와 대시보드가 보는 것

- 체크포인트 API 의 요약·미리보기는 marker 의 `preview`(앞 200바이트까지)를 보여 준다.
- 본문은 `GET /api/v1/artifacts/<sha256>` 로 필요할 때 읽는다. 이 경로는 이미 있고 CanAdmin 권한이다.
- 체크포인트 메시지를 본문째 보여 주는 화면이 있다면 marker 를 풀어 보여 줄지 정해야 한다. §9 의 결정 3 이다.

### 3.7 소비자별 영향

| 소비자 | 영향 | 대응 |
|---|---|---|
| 모델 입력(`plan`/`materialize`) | 바꿀 대상이 직전 턴 몫으로 준다 | 코드 변경 없음. 단계 3에서 잰다 |
| `keeper_artifact_read` | 이미 marker 를 읽는다 | 없음 |
| 반복 호출 감지(`Keeper_tool_progress_identity`) | 같은 도구 출력이 지난 턴엔 marker, 이번 턴엔 본문이면 지문이 달라 반복을 못 찾는다 | 단계 1: 본문 지문을 저장 주소 지문(sha256·bytes·mime)과 같은 방식으로 계산해 둘을 같게 만든다 |
| 훅 `last_tool_results` | 마지막 Tool 메시지는 현재 턴이라 본문 그대로다 | 없음. 테스트로 고정한다 |
| `Keeper_transcript_unit`·꼬리 복구 | `tool_use_id` 만 본다 | 없음 |
| 사서(`Keeper_librarian`) | 도구 결과를 읽지 않는다 | 없음 |
| provider 입력 스냅샷(`Keeper_provider_input_snapshot`) | 자기 artifact 재사용 판정에만 marker 를 푼다. 체크포인트 도구 결과 본문에 기대지 않는다 | 없음 |
| 대시보드 체크포인트 API | 미리보기가 marker 미리보기가 된다 | 결정 3 |
| blob 청소 | `traces` 가 이미 소비자 루트다 | 없음 |

## 4. 기대 효과와 재는 법

| 지표 | 기준 (2026-09-15) | 기대 | 재는 법 |
|---|---|---|---|
| 큰 체크포인트 크기 | 109.8 / 107.1 / 77.5 MB | 약 −31% / −23% / −31% | 파일 크기 |
| 턴 시작 디코드·첫 저장 인코딩 바이트 | 체크포인트 크기와 같다 | 같은 비율로 준다 | 파일 크기로 대신한다 |
| 다시 쓰이는 blob 파일 수 | 1~2.5분에 2,776개 | 턴마다 직전 턴 결과 수 수준 | `find <base-path>/.masc/tool_blobs -type f -mmin -1 \| wc -l` |
| 메인 스레드 바쁜 비율 | 73% | 준다 (목표치는 단계 3 측정 뒤 확정) | `sample <pid> 12` main-thread 의 바쁜 샘플 비율 |
| `/health/live` 첫 바이트 | 0.25–6.0 초 | 준다 | `curl -s -o /dev/null -w '%{time_starttransfer}'` 연속 5회 |
| 스케줄러 lag | RFC-main-domain-scheduler-latency 하네스 | p99 감소 | `/health` 의 `.scheduler` |

부하는 창마다 다르다. 같은 서버를 기동 뒤 같은 시간(약 15분)에, 같은 방법으로 두 번 이상 잰다. 코어 수와 할당률을 같이 적어 창을 비교할 수 있게 한다.

## 5. 검토한 대안

### 5.1 턴 시작에 마지막으로 쓴 값을 재사용한다 (RFC-main-domain-scheduler-latency P4b 2단계)

디코드를 없애는 가장 직접적인 방법이다. 그 RFC 는 코덱 왕복이 값을 그대로 돌려준다는 증명을 먼저 요구했다. 실제로 디코드는 `ToolResult.json` 을 항상 `None` 으로 만든다(`checkpoint_codec.ml:424`). 그래서 메모리 값과 재기동 뒤 읽은 값이 달라진다. keeper 마다 체크포인트 한 벌을 더 들고 있어 major GC 가 훑는 live heap 도 는다. 디스크 크기와 인코딩 바이트는 줄지 않는다. 이 RFC 와 같이 쓸 수는 있지만 대신할 수는 없다.

### 5.2 히스토리 길이를 자른다

체크포인트가 1만 4천 메시지까지 자라지 않게 하는 방법이다. 효과는 가장 크다. 대신 keeper 가 무엇을 기억하는지가 바뀐다. 제품 결정이라 이 RFC 범위가 아니다.

### 5.3 생성 때 blob 으로 보내는 기준을 낮춘다 (RFC-0363 안 B)

체크포인트도 준다. 대신 현재 턴의 결과도 marker 가 되어, 모델이 방금 받은 자기 출력을 artifact read 로 다시 읽어야 한다. 이 RFC 는 현재 턴을 본문으로 남겨 그 문제를 피한다.

### 5.4 blob 중복 쓰기만 없앤다

같은 주소를 다시 쓰지 않게 하는 수정은 요청마다의 파일 쓰기를 줄인다(별도 PR). 하지만 체크포인트는 그대로 커서 턴마다 읽기·인코딩·GC 비용이 남는다. 이 RFC 와 함께 가는 보완이다.

## 6. 하지 않는 것

- 스트리밍 `reasoning_details` 조각 합치기. 별도 PR 이다.
- `content_blocks = Some` 결과, `Invalid_marker` 결과를 바꾸는 일.
- 히스토리 보존 기간·길이 정책.
- 현재 턴 결과를 marker 로 바꾸는 일.
- 체크포인트 버전 변경, 옛 형식 reader, 변환 코드.

## 7. 위험

| 위험 | 내용 | 완화 |
|---|---|---|
| 본문의 원본이 blob 으로 옮겨간다 | `tool_blobs` 손실 = 지난 결과 본문 손실. trace 폴더만 옮기면 본문이 빠진다 | 결정 1. 청소는 참조를 세고 두 번 스캔 뒤에만 지운다. `fetch` 가 무결성을 확인한다 |
| 첫 저장이 무겁다 | 큰 keeper 는 첫 저장에서 수천 개를 durable 로 쓴다 | pool·systhread 경계 안에서 돈다. 단계 2 PR 에서 첫 저장 시간을 잰다 |
| 반복 호출 감지가 약해진다 | 지문이 marker/본문에 따라 달라진다 | 단계 1 을 먼저 넣는다 |
| 경계 계산이 모델 입력과 어긋난다 | 저장과 모델 입력이 서로 다른 경계를 쓰면 현재 턴 결과가 marker 가 될 수 있다 | 같은 함수(`first_atom_at_or_after`)와 같은 입력(`initial_messages` 수)을 쓴다. 테스트로 고정한다 |
| 되돌리기 | 되돌려도 marker 는 남는다 | 옛 바이너리가 marker 를 읽는다. 본문은 blob 에 있다 |
| 청소가 꺼진 클러스터 구성 | `clusters` 가 있으면 청소가 멈춰 blob 이 계속 쌓인다 | 지금과 같다. 참조가 늘어 지울 수 있는 것이 줄 뿐이다 |

## 8. 단계 — PR 별

1. **반복 호출 지문을 저장 주소 기준으로 맞춘다.** `Keeper_tool_progress_identity` 가 본문 출력도 sha256·bytes·mime 지문으로 계산한다. 같은 본문이 marker 든 본문이든 같은 지문이 나오는지 테스트한다. 동작 변화: 없음(지금은 marker 가 거의 없다).
2. **저장 규칙을 넣는다.** 저장소 함수가 턴 시작 메시지 수를 받고 §3.1 규칙으로 `put_durable` → marker → 저장 순서를 지킨다. 테스트: 저장 뒤 다시 읽으면 지난 턴 결과는 marker, 현재 턴 결과는 본문이다. marker 가 가리키는 blob 이 원래 본문과 같다. `put_durable` 실패 시 본문으로 저장되고 실패 수가 결과에 담긴다. 이미 marker 인 결과는 다시 쓰지 않는다.
3. **요청마다 남은 비용을 잰다.** §4 표를 같은 방법으로 다시 채운다. `plan`·`materialize` 를 줄이거나 지울 수 있는지 판단해 이 RFC 에 적는다.
4. **대시보드 표시.** 결정 3 에 따라 필요하면 본문 표시를 artifact 경로로 바꾼다.
5. **마감.** 측정 결과를 적고 상태를 올린다.

## 9. 결정이 필요한 것

1. **지난 결과 본문의 원본을 blob 저장소로 옮겨도 되는가.** trace 폴더만으로는 본문이 완전하지 않게 된다. 백업·내보내기가 `tool_blobs` 도 함께 다뤄야 한다.
2. **바꾸는 시점.** 제안: 다음 턴의 저장부터(현재 턴 결과는 그 턴 동안 본문). 대안: 턴 마감 저장에서 그 턴 결과까지 바꾼다. 대안은 요청마다의 비용을 더 줄이지만, 턴 마감 뒤 이어지는 continuation 이 방금 결과를 marker 로 보게 된다.
3. **대시보드가 본문을 어떻게 보여 줄지.** 제안: 미리보기를 보여 주고 본문은 누르면 `GET /api/v1/artifacts/<sha256>` 로 읽는다.
