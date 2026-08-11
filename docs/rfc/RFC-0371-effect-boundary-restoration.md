---
rfc: "0371"
title: "Effect 경계 회복 — 이펙트는 경계로, 코어는 순수 로직으로"
status: Draft
created: 2026-08-11
updated: 2026-08-11
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0042"]
implementation_prs: []
---

# RFC-0371: Effect 경계 회복 — 이펙트는 경계로, 코어는 순수 로직으로

## 0. 한 문장 요약

경계(store/loader/client/route adapter)에서 한 번 안전한 값으로 바꿨으면 코어는 그 값을 그대로 쓴다. 코어 한복판에서 env 를 되읽고, 자기가 렌더한 문자열을 재파싱하고, 이미 확인한 존재를 다시 확인하는 코드를 색출해 경계로 밀어낸다.

## 1. 문제 — 계측

2026-08-11, `lib/` + `packages/agent_core/lib/` 프로덕션 코드를 6개 패턴 패밀리(Option/Result 중간 해소, env 재독, FS 직접 접근, 예외 제어흐름, 다층 재검증, 문자열 왕복)로 스캔하고, 각 발견을 독립 검증 패스가 반박 시도한 결과:

| 판정 | 건수 |
|---|---|
| core-violation confirmed | 11 |
| core-violation unverified¹ | 5 |
| boundary-smell | 30 |
| dead-guard | 12 |
| info | 11 |
| **소계** | **69** |
| 확정 substring 왕복 (별도 수동 전수 감사, 7파일) | 13 |

¹ string-roundtrip 검증 패스가 미완(연결 끊김)이라 unverified 로 표기. B12 착수 전 재검증이 선행 조건이다.

계측 조건: 스캐너당 상위 15건 캡. 일부 스캐너는 "N건 더 있음"을 보고했으므로 이 인벤토리는 **전수가 아니라 대표 표본**이다. 검증 패스는 1차에서 주장 28건 중 12건만 confirmed 로 남겼다(경계 모듈 내 이펙트·부팅 1회 경로는 반박됨).

개별 버그 목록이 아니다. 4개 구조 패턴의 반복이다:

### (a) in-process typed→string→재파싱 터널

같은 프로세스 안에서 자기 타입을 문자열로 렌더한 뒤 그 문자열을 재파싱해 제어 흐름을 결정한다.

`lib/tool_input_validation.ml:824-835` — 모든 툴 디스패치의 검증 훅 경로(:956):

```ocaml
let validation_schema_of_json ~name json_schema : Agent_core.Types.tool_schema =
  let params = Tool_bridge.params_of_json_schema json_schema in
  let json = `Assoc [ ...; ("parameters", `List (List.map tool_param_to_json params)) ] in
  match Agent_core.Types.tool_schema_of_json json with
  | Ok schema -> schema
  | Error err -> failwith ("validation_schema_of_json: " ^ err)
```

이미 typed 인 `params` 를 JSON 으로 렌더해 재파싱한다. `Agent_core.Types.tool_schema_of_params`(types.mli:183)라는 typed→typed 직접 생성자가 **이미 존재**하므로 왕복 전체와 `failwith` 가 불필요하다.

`lib/server/server_routes_http_routes_channel_gate.ml:323` — HTTP 상태 코드를 자기 에러 문구로 결정:

```ocaml
if String_util.contains_substring lower "keeper not found" then `Not_found
else `Bad_gateway
```

생산자 6곳의 문구가 2종(`"keeper not found: %s"` / `"keeper not found in registry: %s"`)이고 후자는 우연히 부분 문자열로 걸린다. 누가 문구를 다듬으면 404 가 502 로 조용히 승격된다. 이 계약은 어디에도 적혀 있지 않다.

### (b) 요청 경로의 env-as-bus

`lib/server/server_auth.ml:563` — mutation 인가 게이트가 **요청마다** `MASC_ALLOW_ANONYMOUS_MUTATIONS` 를 재독. `lib/tool_workspace.ml:60` — 부팅 시 프로세스 자신이 `putenv` 로 써넣은 `MASC_INTERNAL_MCP_TOKEN`(auth_credential_base.ml:119)을 툴 호출마다 `getenv` 로 되읽는다. env 가 in-process mutable 채널이 됐다(쓰기 2곳, 읽기 3곳). `lib/keeper/keeper_tool_execute_runtime.ml:388` — 툴 실행마다 env 읽고 `<> Some "false"` permissive 파싱.

### (c) 존재/meta 검증의 다층 반복

`lib/keeper/keeper_turn.ml:439` — 직접 메시지 턴 1건에 keeper 존재 검증 4회(디스크 읽기 3회 + 레지스트리 1회). resolve 가 meta 를 버리고 이름만 반환하는 API shape 이 하류 재검증을 강제한다. `lib/keeper/keeper_tool_registered_runtime.ml:115` — `mint_token` + `guarded_dispatch` 를 이미 실행했는데 fallthrough 가 같은 디스패치를 다시 실행(pre-hook 2회, observer 2회, span 2-3회 — 텔레메트리 오염).

### (d) 부분 타입이 강제하는 dead guard

`lib/keeper/keeper_board_attention_candidate.ml:1757` — `resumable_status` 가 Option 으로 정보를 버려서, 호출부가 같은 값을 재match 하며 1,600행 떨어진 불변식에 `assert false` 로 베팅한다. `lib/keeper/keeper_heartbeat_loop.ml:1205` — 3-생성자 `cycle_status` 를 bool 로 파생한 뒤 false 분기에서 재match(boolean blindness). 실사고 전례: keeper_registry.ml:721 sparse-match `Assert_failure`(2026-05-08), 닫힌 어휘 파스 실패 → keeper 정지 사슬(#27967, #28008).

생산자 0 가드도 이 계열이다: `keeper_error_classify.ml:184` 의 `"empty completion (no thinking"` 은 저장소 전체에 생산자가 없고, 주석이 스스로 "no production producer" 를 자백한다. `server_dashboard_http_runtime_info.ml:709,719` 의 가드 2건도 생산자 0.

## 2. 원칙 (판정 기준)

1. **Functional core / imperative shell** — env·FS·clock·예외 제어흐름은 경계 모듈에만. 판정 질문은 하나: *이 값이 무엇을 결정하는가, 그 결정이 경계 안에서 일어나는가.* 경계 모듈(파서/스토어/클라이언트) 내부의 이펙트는 그 모듈의 존재 이유이므로 위반이 아니다.
2. **Parse, don't validate** — 경계에서 1회 파싱해 typed 값으로 내부 전달. validate-then-discard 금지.
3. **Option/Result 는 합성 후 경계에서 1회 해소** — 중간 계층의 `failwith`/`Option.get`/재match 금지. 헬퍼가 정보를 버리면(bool·이름만 반환) 호출부에 `assert false` 가 강제된다.
4. **In-process 계약은 typed** — 같은 프로세스 안에서 자기 타입을 렌더해 되읽는 채널 금지. 에러 메시지·env·description·브로드캐스트 본문은 제어 흐름 채널이 아니다.
5. **존재/권위 검증은 소유 계층에서 1회** — 동시성 권위(레지스트리)가 최종 확인을 소유하고, resolve 결과는 typed handle 로 운반한다.

## 3. 금지 패턴 (PR 리뷰 reject 기준, 발견 인용)

1. **typed→string→재파싱**: tool_input_validation:835, channel_gate:298/:323, proactive_refresh:36 → server_routes_http_runtime:311(`label=` 필드를 문자열에 박고 되꺼냄), failure_envelope:59-64(string→string→string 3단).
2. **요청 경로 env 읽기**: server_auth:563, keeper_tool_execute_runtime:388, tool_workspace:60. `<> Some "false"` 류 permissive 파싱 동반 금지.
3. **결정 로직 내 FS 직접 접근·레이아웃 지식 이중화**: masc_grpc_service:246(생산자 0 필드 raw 프로브 — 이미 drift), :117 vs :365(.json 필터 불일치), mcp_server:342(writer 레이아웃 재구현).
4. **Option/Result 중간 붕괴**: keeper_board_attention_candidate:1757, keeper_heartbeat_loop:1205, dashboard_verification:160(Result→failwith 로 실패 브랜치가 타입에서 소멸).
5. **catch-all 의 Cancelled 삼킴**: otel_spans:107(Cancelled→false), keeper_compact_audit:232. 형제 6곳의 `Eio.Cancel.Cancelled _ as e -> raise e` 규율이 표준.
6. **이름/prefix 관습 분류기**: tool_dispatch:107, tool_telemetry:39(주석이 스스로 탈출구를 인정), workspace_task_receipts:23(keeper↔agent 이름의 매직 오프셋 역파싱).
7. **생산자 없는 가드**: keeper_error_classify:184, runtime_info 가드 2건, prompt_defaults:22, voice_runtime_overlay:168(then/else 동일 분기). 발견 즉시 삭제 — "방어적"이라는 사유는 인정하지 않는다. 미래의 upstream 형태 변화는 문자열 가드가 아니라 핀 갱신 시 컴파일 에러로 잡는다.

## 4. 배치 계획

파일 중복 없는 원자 배치. 머지 순서 의존이 생기면 두 PR 로 나누지 않고 한 배치로 합친다(#27997/#28007 47초 역전 사고 근거).

### Phase 1 — 기반 (저위험, 동작 불변이 구조적으로 증명됨)

| 배치 | 내용 | 대상 |
|---|---|---|
| B1 | dead-guard 소거 + `*_opt` 기계 치환 | prompt_defaults, voice_runtime_overlay, keeper_multimodal_input, keeper_approval/audit, workspace_goal_index, dashboard_goals_types_accessor |
| B2 | 예외 catch 폭 정합 — Cancelled 재던짐 + dead catch 제거 | keeper_compact_audit, otel_spans, prompt_registry, types_core, masc_error, keeper_chat_blocks |
| B3 | 확정 substring 왕복 13건 소거 | keeper_error_classify, server_dashboard_http_runtime_info, failure_envelope, keeper_context_core_history, bin/masc_trace |

### Phase 2 — 요청 경로 typed 채널 (고위험, 스모크 필수)

| 배치 | 내용 | 게이트 |
|---|---|---|
| B4 | server 문자열 분류기 → typed 채널 (channel_gate 의 `keeper_exists` 는 status 전체 디스패치 대신 meta store typed 존재 API 직결) | 라이브 /health·404 경로 스모크 |
| B5 | 툴 디스패치 단일 판정·단일 계측·typed 검증 (`tool_schema_of_params` 직결, registered_runtime 이중 실행 제거) | 텔레메트리 카디널리티 전후 실측 diff 첨부 |
| B6 | keeper 존재 검증 1회화 — resolve 가 typed handle 을 운반 | operator_control 포함 → RFC 필수 영역, pr-rfc-check.sh |

### Phase 3 — config/FS 경계

| 배치 | 내용 | 게이트 |
|---|---|---|
| B7 | env SSOT — 결정 경로 getenv 를 부팅 주입으로 | putenv 토글 의존 테스트 재작성 동반 |
| B8 | credential materialization 수렴 (DISCORD_BOT_TOKEN reader 4곳 → 단일 accessor) | credential 인접 — RFC 인용 |
| B9 | FS 읽기 소유권 회복 — store/owner read API 로 위임 | owner API 에 단위 테스트 신설 |
| B10 | Parse-don't-validate 파서 강화 (trajectory 의 `""` StringMap 키 센티널 제거 포함) | persisted 스키마 소비자 파급 조사 |

### Phase 4 — 게이트 뒤

| 배치 | 내용 | 선행 조건 |
|---|---|---|
| B11 | auth env 채널 제거 — putenv/getenv 왕복을 typed credential 주입으로 | credential RFC 게이트 + "재시작 없는 토글" 요구가 실재하는지 라이브 확인. 실재하면 env 가 아니라 명시적 admin 상태로 |
| B12 | identity 이름 codec + 에러 귀속 터널 | unverified 5건 검증 패스 + agent_core Error 확장점 설계(§6) + wire 호환 마이그레이션 계획 |

## 5. 검증 방법 (배치당 Done 기준)

1. **동작 불변**: dune build + 기존 테스트 green. 제거하는 분기는 착수 시점에 생산자 0 을 rg 로 재확인(이동 경로≠죽은 경로 — 리터럴→흡수접두사→basename 3단 해석).
2. **대체 경로 증명**: 신설 typed API/variant 에 단위 테스트 추가. 기대값은 리터럴로 작성(검사 대상 함수를 기대값 쪽에 재사용 금지).
3. **계측 변화 명시**: B5 의 span 감소 등 텔레메트리 변화는 전후 실측 diff 를 PR 에 첨부.
4. **drift-guard 테스트는 소거와 함께 삭제**: substring 가드를 잠그는 테스트는 RFC-0042 가 진단한 안티패턴이므로 잠그지 않고 없앤다.
5. **요청 경로 배치(B4-B6)는 머지 후 라이브 재측정**: merged≠booted 3단 분리, /health + keeper 턴 스모크.
6. **각 PR 은 본 RFC 인용 + pr-rfc-check.sh PASS**. workaround 시그니처(counter-as-fix, string 분류기 추가, N-of-M) 매칭 시 배치를 재설계한다 — 본 RFC 의 목적이 그 패턴의 소거이므로 배치 안에서의 재생산은 자기모순이다.

## 6. 범위 밖 / 후속

- unverified 5건(keeper_internal_error:963, runtime_agent:259, fusion_agent_core:63, keeper_agent_error:281, workspace_task_receipts:23)은 B12 착수 전 검증 패스에서 재판정.
- agent_core Error 확장점 방식(opaque payload vs sub-sum split)은 별도 설계 결정 — 경계 제약(MASC 는 agent_core 를 알지만 역방향 금지)을 유지하는 안만 허용.
- permissive default 값 자체의 변경(예: tool_catalog unknown→true)은 동작 변화이므로 범위 밖 — 별도 이슈로.
- 테스트 코드의 같은 패턴(에러 메시지 문구에 결합된 단언 ~142곳, fixture cwd 추측)은 프로덕션 정리 후 별도 트랙.

## 7. 부록 — 인벤토리 (69건, 심각도순)

계측 스크립트와 검증 판정 원문은 워크플로 저널(`wf_c46ff023-afa`)에 보존. 아래 표본 캡(스캐너당 15건)을 유의하고 읽을 것.

| 위치 | 심각도 | 검증 | 요지 |
|---|---|---|---|
| `lib/fusion/fusion_agent_core.ml:63` | core-violation | unverified | agent_core 의 error.ml 이 렌더한 "Provider '%s' ..." 메시지와 fusion_official_client.ml:23 이 렌더한 "runtime_id: detail" 을 재파싱해 귀속 |
| `lib/keeper/keeper_agent_error.ml:281` | core-violation | unverified | typed Agent_core.Retry variant 를 wire 문자열로 렌더한 뒤 즉시 'typed' 생성자에 opaque string 으로 다시 싼다 |
| `lib/keeper/keeper_board_attention_candidate.ml:1757` | core-violation | confirmed | 같은 status 를 두 층에서 분류 — Option 해소 후 재match, 1,600행 원거리 불변식에 assert false |
| `lib/keeper/keeper_heartbeat_loop.ml:1205` | core-violation | confirmed | cycle_status 를 bool 로 파생해 정보 폐기 후 false 분기에서 재match — boolean blindness |
| `lib/keeper/keeper_tool_execute_runtime.ml:388` | core-violation | confirmed | 툴 실행마다 env 읽어 스트리밍 여부 결정, `<> Some "false"` permissive 파싱 |
| `lib/keeper/keeper_tool_registered_runtime.ml:115` | core-violation | confirmed | mint+guarded_dispatch 이중 실행 — pre-hook·observer·span 중복, 텔레메트리 오염 |
| `lib/keeper/keeper_turn.ml:439` | core-violation | confirmed | 직접 메시지 턴 1건에 keeper 존재 검증 4회 (디스크 3 + 레지스트리 1) |
| `lib/keeper_runtime/keeper_internal_error.ml:963` | core-violation | unverified | typed masc_internal_error 를 JSON 렌더해 Error.Internal 메시지 문자열에 박고 같은 프로세스가 재파싱 |
| `lib/runtime/runtime_agent.ml:259` | core-violation | unverified | 사람용 description 필드에 "runtime:%s/runtime" 를 밀수해 되읽음 |
| `lib/server/masc_grpc_service.ml:246` | core-violation | confirmed | directive 계산이 workspace store 의 typed 읽기를 우회해 raw JSON 프로브 — 생산자 0 필드로 이미 drift |
| `lib/server/proactive_refresh.ml:36` | core-violation | confirmed | timeout 조건(label/phase)을 Failure 문자열로 렌더해 던지고 소비자가 substring 재파싱 |
| `lib/server/server_auth.ml:563` | core-violation | confirmed | mutation 인가 게이트가 요청마다 env 재독 |
| `lib/server/server_routes_http_routes_channel_gate.ml:298` | core-violation | confirmed | 존재 확인을 위해 status 전체 디스패치 실행, typed Ok None 이 문자열이 되어 substring 재분류 |
| `lib/tool_input_validation.ml:835` | core-violation | confirmed | typed params → JSON 렌더 → 재파싱 → failwith. typed 직접 생성자 존재(types.mli:183) |
| `lib/tool_workspace.ml:60` | core-violation | confirmed | 자기 프로세스가 putenv 한 토큰을 툴 호출마다 getenv — env 를 in-process mutable 채널로 사용 |
| `lib/workspace/workspace_task_receipts.ml:23` | core-violation | unverified | keeper↔agent 이름 관계가 codec 없이 문자열 관습 — 렌더 4곳 산포, 매직 오프셋 역파싱 |

(boundary-smell 30 · dead-guard 12 · info 11 건의 전체 목록은 워크플로 저널과 구현 배치 PR 에서 인용한다. 표가 리뷰를 압도하지 않도록 core-violation 만 본문에 실었다.)
