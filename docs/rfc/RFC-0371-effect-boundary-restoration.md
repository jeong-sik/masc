---
rfc: "0371"
title: "Effect 경계 회복 — 이펙트는 경계로, 코어는 순수 로직으로"
status: Draft
created: 2026-08-11
updated: 2026-08-12
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0042"]
---

# RFC-0371: Effect 경계 회복 — 이펙트는 경계로, 코어는 순수 로직으로

## 0. 한 문장 요약

경계(store/loader/client/route adapter)에서 한 번 안전한 값으로 바꿨으면 코어는 그 값을 그대로 쓴다. 코어 한복판에서 env 를 되읽고, 자기가 렌더한 문자열을 재파싱하고, 이미 확인한 존재를 다시 확인하는 코드를 색출해 경계로 밀어낸다.

## 1. 문제 — 계측

2026-08-11, `lib/` + `packages/agent_core/lib/` 프로덕션 코드를 6개 패턴 패밀리(Option/Result 중간 해소, env 재독, FS 직접 접근, 예외 제어흐름, 다층 재검증, 문자열 왕복)로 스캔하고, 각 발견을 독립 검증 패스가 반박 시도한 결과:

| 판정 | 건수 |
|---|---|
| core-violation confirmed | 15 |
| boundary-smell | 31 |
| dead-guard | 12 |
| info | 11 |
| **소계** | **69** |
| 확정 substring 왕복 (별도 수동 전수 감사, 7파일) | 13 |

계측 조건 (1차): 스캐너당 상위 15건 캡 — 대표 표본.

**2차 전수 스윕 (같은 날, 캡 제거, 워크플로 `wf_1bdada3b`)**: 5개 패턴 패밀리를 전수 재스캔했다. 각 스위퍼는 rg 명령·총 매치 수·제외 사이트의 판정 근거(부팅 1회 / module-init / DI seam / 주석 전용)를 기록했다.

| 패턴 | 전수 스캔 | 신규 발견 | confirmed |
|---|---|---|---|
| env 읽기 | 137 | 37 | 22 |
| FS 직접 접근 | 447 | 21 | 16 |
| Option.get / assert false / failwith | 34 | 13 | 7 |
| 자기 렌더 재파싱 | 358 | 16 | 11 |
| blanket catch | 163 | 22 | 7 |
| **계** | **1,139** | **109** | **63** |

검증 패스의 반박률은 두 라운드 모두 유의미했다: 1차 28건 중 16건 반박·강등, 2차 109건 중 46건 반박·강등(42%). 대표 반박: `exec_dispatch:150` 의 `Var` arm 은 bash lexer 가 `$` 를 fail-closed 하므로 프로덕션 도달 불가 — 스캐너의 그럴듯한 주장을 소비자·생산자 실독이 걸러냈다.

2차에서 추가된 core-violation 7건 중 특기: `server_auth.ml:572` (mutation **origin allowlist** 를 요청마다 env 재독 — §1(b) 기지 :563 의 같은 결정 흐름 형제, B11), `keeper_owner.ml:329` (`run_in_systhread` 의 Cancelled 가 `Store_unavailable` 로 오분류 — B2 에서 즉시 소거), `keeper_provider_runtime_boundary.ml:117/:155` + `keeper_execution_receipt.ml:127` (typed→wire→re-typed 왕복 체인 — B12 의 실물 확정). workspace 의 mixed-layer FS 클러스터(~8곳: 가드는 bare `Sys.file_exists`, 본문은 backend-aware — Memory 폴백에서 fleet invariant 가 조용히 skip)는 B9 의 범위를 "backend-aware 일관화"로 재정의한다. 전체 판정 원문은 #28221 과 워크플로 저널.

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

`lib/tool_workspace.ml:60` — 부팅 시 프로세스 자신이 `putenv` 로 써넣은 `MASC_INTERNAL_MCP_TOKEN`(auth_credential_base.ml:119)을 툴 호출마다 `getenv` 로 되읽는다. env 가 in-process mutable 채널이 됐다. `lib/keeper/keeper_tool_execute_runtime.ml:388` — 툴 실행마다 env 읽고 `<> Some "false"` permissive 파싱.

### (c) 존재/meta 검증의 다층 반복

`lib/keeper/keeper_turn.ml:439` — 직접 메시지 턴 1건에 keeper 존재 검증 4회(디스크 읽기 3회 + 레지스트리 1회). resolve 가 meta 를 버리고 이름만 반환하는 API shape 이 하류 재검증을 강제한다. `lib/keeper/keeper_tool_registered_runtime.ml:115` — `mint_token` + `guarded_dispatch` 를 이미 실행했는데 fallthrough 가 같은 디스패치를 다시 실행(pre-hook 2회, observer 2회, span 2-3회 — 텔레메트리 오염).

### (d) 생산자 0 dead guard

`keeper_error_classify.ml:184` 의 `"empty completion (no thinking"` 은 저장소 전체에 생산자가 없고, 주석이 스스로 "no production producer" 를 자백한다. `server_dashboard_http_runtime_info.ml:709,719` 의 가드 2건도 생산자 0.

## 2. 원칙 (판정 기준)

아래 원칙은 식별자나 구문을 전역 grep 해 자동 금지하는 규칙이 아니다. 각 후보에서 생산자→소비자 데이터 흐름과 소유 경계를 확인한 뒤 판정한다. 같은 구문도 경계 어댑터, 자원 소유 orchestration, 테스트에서는 정당할 수 있다.

1. **Functional core / imperative shell** — env·FS·clock·예외 제어흐름을 그 값을 소유하는 경계 또는 orchestration 에 둔다. 판정 질문은 하나: *이 값이 무엇을 결정하고, 어느 계층이 그 결정을 소유하는가.* 파서/스토어/클라이언트 내부의 이펙트와 명시적으로 clock·cancel·resource lifecycle 을 소유하는 실행 계층은 그 모듈의 존재 이유이므로 위반이 아니다.
2. **Parse, don't validate** — 경계에서 1회 파싱해 typed 값으로 내부 전달. validate-then-discard 금지.
3. **Option/Result 의 정보를 버린 뒤 추측으로 복원하지 않는다** — 중간 계층 해소 자체를 금지하지 않는다. `failwith`/`Option.get`/wildcard fallback 으로 실패 의미를 없앤 뒤 bool·문구로 복원하는 경로가 대상이다.
4. **In-process 계약은 typed** — 같은 프로세스 안에서 자기 타입을 렌더해 되읽는 채널 금지. 에러 메시지·env·description·브로드캐스트 본문은 제어 흐름 채널이 아니다.
5. **존재/권위 검증은 소유 계층에서 1회** — 동시성 권위(레지스트리)가 최종 확인을 소유하고, resolve 결과는 typed handle 로 운반한다.

## 3. 금지 패턴 (PR 리뷰 후보 기준, 발견 인용)

아래 항목은 텍스트가 매치됐다는 이유만으로 reject 하지 않는다. 해당 PR이 새 implicit control channel 을 만들거나, 이미 보유한 typed 정보를 버린 뒤 문자열·환경·파일을 통해 재구성한다는 데이터 흐름 증거가 있을 때만 blocker 다. 외부 wire/프로세스 경계의 직렬화, 설정 로더의 env 읽기, store의 FS 접근, 명시적 오류 표시를 위한 문자열은 대상이 아니다.

1. **typed→string→재파싱**: tool_input_validation:835, channel_gate:298/:323, failure_envelope:59-64(string→string→string 3단).
2. **요청 경로에서 이미 주입된 값을 env 로 재조회**: keeper_tool_execute_runtime:388, tool_workspace:60. 요청별 환경 정책을 명시적으로 소유하는 loader는 예외지만, `<> Some "false"` 같은 permissive 파싱으로 오타와 부재를 같은 값으로 합치는 경로는 허용하지 않는다.
3. **결정 로직에서 owner API를 우회한 FS 접근·레이아웃 지식 이중화**: mcp_server:342(writer 레이아웃 재구현). store/loader가 자기 레이아웃을 읽는 것은 대상이 아니다.
4. **Option/Result 의미 붕괴 후 재추론**: dashboard_verification:160(Result→failwith 로 실패 브랜치가 타입에서 소멸). 경계에서 모든 분기를 명시적으로 처리하는 정상 해소는 대상이 아니다.
5. **catch-all 의 Cancelled 삼킴**: otel_spans:107(Cancelled→false). 형제 6곳의 `Eio.Cancel.Cancelled _ as e -> raise e` 규율이 표준.
6. **이름/prefix 관습 분류기**: tool_dispatch:107, tool_telemetry:39(주석이 스스로 탈출구를 인정), workspace_task_receipts:23(keeper↔agent 이름의 매직 오프셋 역파싱).
7. **닫힌 세계에서 생산자 없는 가드**: keeper_error_classify:184, runtime_info 가드 2건, prompt_defaults:22, voice_runtime_overlay:168(then/else 동일 분기). 저장소 내부의 exhaustive typed producer만 입력한다는 증거와 회귀 테스트가 있을 때 삭제한다. 외부 입력·persisted data·version-skew가 도달 가능한 경로는 `rg` 0건만으로 dead라 판정하지 않는다. 미래 upstream 변화는 가능하면 typed variant와 exhaustive match로 잡고, 불가능한 wire 경계는 명시적 unknown/error 분기를 유지한다.

## 4. 배치 계획

파일 중복 없는 검토 가능한 배치를 우선한다. 같은 불변식을 중간 상태 없이 바꿔야 할 때만 한 배치로 합치고, 독립적으로 검증 가능한 변경은 작은 PR로 나눈다. 머지 순서 의존은 stacked base 또는 명시적 dependency로 표현한다(#27997/#28007 47초 역전 사고 근거).

### Phase 1 — 기반 (저위험, 동작 불변이 구조적으로 증명됨)

| 배치 | 내용 | 대상 |
|---|---|---|
| B1 | 닫힌 생산자 그래프로 증명된 dead-guard 소거 + 의미 보존이 확인된 `*_opt` 치환 | prompt_defaults, voice_runtime_overlay, keeper_multimodal_input, keeper_approval/audit, workspace_goal_index, dashboard_goals_types_accessor |
| B2 | 예외 catch 폭 정합 — Cancelled 재던짐 + dead catch 제거 | otel_spans, prompt_registry, types_core, masc_error, keeper_chat_blocks |
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
| B12 | identity 이름 codec + 에러 귀속 터널 | agent_core Error 확장점 설계(§6) + wire 호환 마이그레이션 계획 |

## 5. 검증 방법 (배치당 Done 기준)

1. **동작 불변**: exact-head CI build + 기존 테스트 green. 제거하는 분기는 착수 시점에 생산자 0 뿐 아니라 외부/저장 입력 가능성과 alias 변환을 함께 재확인한다(이동 경로≠죽은 경로 — 리터럴→흡수접두사→basename 3단 해석).
2. **대체 경로 증명**: 신설 typed API/variant 에 단위 테스트 추가. 기대값은 리터럴로 작성(검사 대상 함수를 기대값 쪽에 재사용 금지).
3. **계측 변화 명시**: B5 의 span 감소 등 텔레메트리 변화는 전후 실측 diff 를 PR 에 첨부.
4. **제거한 implicit bridge를 고정하던 테스트는 typed 계약 테스트로 교체**: 단순 삭제하지 않는다. 외부 wire 문자열 자체가 공개 계약인 경우에는 해당 boundary codec 테스트를 유지한다.
5. **요청 경로 배치(B4-B6)는 머지 후 라이브 재측정**: merged≠booted 3단 분리, /health + keeper 턴 스모크.
6. **본 RFC 구현 PR 은 RFC 인용 + pr-rfc-check.sh PASS**. counter-as-fix, string 분류기, N-of-M 같은 텍스트 매치만으로 자동 reject 하지 않고, 새 silent fallback 또는 implicit control channel 이 생기는지 데이터 흐름을 리뷰한다. 확인되면 배치를 재설계한다.

## 6. 범위 밖 / 후속

- 2026-08-12 검증 판정: keeper_internal_error:963 · workspace_task_receipts:23 · runtime_agent:259 · keeper_agent_error:281 은 core-violation, fusion_agent_core:63 은 제어 흐름을 바꾸지 않는 boundary-smell.

### 6.1 B12 설계 결정 (선행 조건 해소)

**(1) agent_core Error 확장점 — extensible variant carrier 채택, sub-sum split 기각.**

문제의 실물: `keeper_internal_error.ml:963` 은 typed `masc_internal_error` 를 JSON 으로 렌더해 `Agent_core.Error.Internal` 의 message **문자열 안에** prefix 와 함께 박고, 같은 프로세스가 수동 prefix 스캔으로 되찾아 재파싱한다. agent_core 의 Error 에 masc 페이로드를 실을 자리가 없어서 생긴 터널이다.

- **기각 — sub-sum split**: agent_core 에 masc 의 에러 형상별 생성자를 추가하는 안은 agent_core 가 masc 어휘를 알게 되므로 경계 제약(agent_core 는 masc 를 모른다) 위반. 기각.
- **채택 — extensible variant carrier**: agent_core 가 `type carrier = ..` 를 선언하고 Error 페이로드에 `carrier option` 슬롯을 둔다. masc 쪽에서 `type Agent_core.Error.carrier += Masc_internal of Masc_internal_error.t` 로 확장하고, 소비자는 생성자 match 로 다운캐스트한다. agent_core 는 masc 를 계속 모르고, JSON 렌더·prefix 스캔·재파싱이 전부 사라진다. 유일한 비용은 extensible variant 의 비-exhaustive match (`| _ ->` 필수) — 이 슬롯의 소비자는 자기가 실은 것만 찾는 다운캐스트이므로 이 한정된 자리에서는 수용한다.
- terminal code 왕복 3건(`keeper_provider_runtime_boundary:117/:155`, `keeper_execution_receipt:127`)도 같은 처방: wire 문자열은 receipt 직렬화 시점에만 렌더하고, in-process 전달은 `Keeper_turn_terminal_code.t` 를 그대로 운반한다. wire 호환은 직렬화 계층이 소유하므로 receipt 파일 포맷은 불변.

**(2) keeper↔agent 이름 codec — leaf 추출 (masc.string_util 선례).**

`workspace_task_receipts.ml:23` 이 정본(`Keeper_identity`, 4철자 수용)의 **2철자 열화 사본**을 보유한 원인은 게으름이 아니라 의존 방향이다: codec 은 `lib/keeper`(masc 본체) 에 살고, `masc_workspace` 는 keeper 에 의존하지 않는다(실측: `lib/workspace/dune` 의존 목록에 keeper 없음). — contains_substring 91사본과 동일한 근본 원인.

처방도 동일: 이름 codec(4철자 수용 + `keeper_agent_name` 렌더)을 의존성 0 leaf (`lib/keeper_identity_codec` 또는 기존 `masc.string_util` 급의 신설 leaf)로 내리고, `Keeper_identity` 와 `workspace_task_receipts` 둘 다 위임한다. 렌더 산포 4곳(keeper_identity:94, tool_agent:94, server_auth 외)도 같은 leaf 로 수렴. leaf dune 에는 string_util 과 같은 anti-regrowth 주석을 박는다.

- `runtime_agent:259` (description 필드의 `"runtime:%s/runtime"` 밀수) 는 carrier 와 무관 — config 레코드에 typed `runtime_id` 필드를 추가하고 description 은 사람용으로 되돌린다.
- B12 는 위 두 설계로 착수 가능하다.

**(3) terminal-code 의 agent-core wire — RFC-0042 sub-sum 의 실행 설계 (구현 조사 2026-08-12).**

잔여 2건(`keeper_agent_error:281`, `keeper_provider_runtime_boundary:155`)의 실측 사슬:

```
Agent_core.Error.t ─(terminal_reason_code_of_core_error: typed→wire 렌더)→ string
  ─(of_core_error_wire = Agent_core_error wire: 문자열을 그대로 싸는 생성자)→ Keeper_turn_terminal_code.t
  ─(to_wire)→ Keeper_registry.Provider_runtime_error.code : string   (execution-receipt 영속 축)
  ─(:155 classify_provider_runtime_error_record: prefix 재파싱)→ 타임아웃/phase 관측
```

- `Keeper_turn_terminal_code.Agent_core_error of string` 과 `Provider_runtime_error of string` 이 opaque wire 를 나르므로, in-process 소비자(:155, status bridge blocker)는 문자열을 되파는 수밖에 없다. RFC-0042 PR-1 이 의도적으로 유예한 sub-sum 이 바로 이 지점이다.
- **설계**: (a) 렌더 지점(`:281`, 유일하게 원본 `Error.t` 를 손에 쥔 곳)에서 typed 관측(`provider_timeout : { source; phase option } option` 등)을 함께 파생해 terminal code 에 병행 탑재 — `Agent_core_error of { wire : string; observation : boundary_observation option }`. **wire 필드는 바이트 불변**이므로 receipt 영속 포맷 무변경. (b) 사슬의 4개 타입(terminal_code → Keeper_turn_terminal.t → disposition 경유 → registry failure_reason)에 같은 방식으로 typed 관측을 스레딩. (c) `:155` 는 관측 `Some` 이면 typed 소비, `None`(영속 재수화·pre-변경 값)이면 기존 문자열 파스 — 문자열 경로는 영속 경계 파서로 수렴.
- **한 배치 강제**: 4개 타입을 관통하므로 부분 스레딩(N-of-M)은 금지 — 생산 1곳·소비 2곳·타입 4개를 한 PR 로. 이 관통이 이 항목이 B12 본 배치에서 분리된 이유이며, 착수 시 이 설계 절을 인용한다.
- permissive default 값 자체의 변경(예: tool_catalog unknown→true)은 동작 변화이므로 범위 밖 — 별도 이슈로.
- 테스트 코드의 같은 패턴(에러 메시지 문구에 결합된 단언 ~142곳, fixture cwd 추측)은 프로덕션 정리 후 별도 트랙.

## 7. 부록 — 인벤토리 (69건, 심각도순)

계측 스크립트와 검증 판정 원문은 워크플로 저널(`wf_c46ff023-afa`)에 보존. 아래 표본 캡(스캐너당 15건)을 유의하고 읽을 것.

| 위치 | 심각도 | 검증 | 요지 |
|---|---|---|---|
| `lib/fusion/fusion_agent_core.ml:63` | boundary-smell | confirmed | agent_core 의 error.ml 이 렌더한 "Provider '%s' ..." 메시지와 fusion_official_client.ml:23 이 렌더한 "runtime_id: detail" 을 재파싱해 표시 귀속 |
| `lib/keeper/keeper_agent_error.ml:281` | core-violation | confirmed | typed Agent_core.Retry variant 를 wire 문자열로 렌더한 뒤 즉시 'typed' 생성자에 opaque string 으로 다시 싼다 |
| `lib/keeper/keeper_board_attention_candidate.ml:1757` | core-violation | confirmed | 같은 status 를 두 층에서 분류 — Option 해소 후 재match, 1,600행 원거리 불변식에 assert false |
| `lib/keeper/keeper_heartbeat_loop.ml:1205` | core-violation | confirmed | cycle_status 를 bool 로 파생해 정보 폐기 후 false 분기에서 재match — boolean blindness |
| `lib/keeper/keeper_tool_execute_runtime.ml:388` | core-violation | confirmed | 툴 실행마다 env 읽어 스트리밍 여부 결정, `<> Some "false"` permissive 파싱 |
| `lib/keeper/keeper_tool_registered_runtime.ml:115` | core-violation | confirmed | mint+guarded_dispatch 이중 실행 — pre-hook·observer·span 중복, 텔레메트리 오염 |
| `lib/keeper/keeper_turn.ml:439` | core-violation | confirmed | 직접 메시지 턴 1건에 keeper 존재 검증 4회 (디스크 3 + 레지스트리 1) |
| `lib/keeper_runtime/keeper_internal_error.ml:963` | core-violation | confirmed | typed masc_internal_error 를 JSON 렌더해 Error.Internal 메시지 문자열에 박고 같은 프로세스가 재파싱 |
| `lib/runtime/runtime_agent.ml:259` | core-violation | confirmed | 사람용 description 필드에 "runtime:%s/runtime" 를 밀수해 되읽음 |
| `lib/server/masc_grpc_service.ml:246` | core-violation | confirmed | directive 계산이 workspace store 의 typed 읽기를 우회해 raw JSON 프로브 — 생산자 0 필드로 이미 drift |
| `lib/server/server_auth.ml:563` | core-violation | confirmed | mutation 인가 게이트가 요청마다 env 재독 |
| `lib/server/server_routes_http_routes_channel_gate.ml:298` | core-violation | confirmed | 존재 확인을 위해 status 전체 디스패치 실행, typed Ok None 이 문자열이 되어 substring 재분류 |
| `lib/tool_input_validation.ml:835` | core-violation | confirmed | typed params → JSON 렌더 → 재파싱 → failwith. typed 직접 생성자 존재(types.mli:183) |
| `lib/tool_workspace.ml:60` | core-violation | confirmed | 자기 프로세스가 putenv 한 토큰을 툴 호출마다 getenv — env 를 in-process mutable 채널로 사용 |
| `lib/workspace/workspace_task_receipts.ml:23` | core-violation | confirmed | keeper↔agent 이름 관계가 codec 없이 문자열 관습 — 렌더 4곳 산포, 매직 오프셋 역파싱 |

(boundary-smell 30 · dead-guard 12 · info 11 건의 전체 목록은 워크플로 저널과 구현 배치 PR 에서 인용한다. 표가 리뷰를 압도하지 않도록 core-violation 만 본문에 실었다.)
