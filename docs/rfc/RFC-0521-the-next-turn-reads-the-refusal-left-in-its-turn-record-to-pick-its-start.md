---
rfc: "0521"
title: "다음 턴은 턴 기록에 남은 거절을 읽고 시작점을 고른다"
status: Draft
created: 2026-11-15
updated: 2026-11-15
author: claude
supersedes: []
superseded_by: null
related: ["librarian-lifecycle", "keeper-context-window-in-tokens", "tool-results-age-out-of-context", "retained-results-carrier-shrinks-to-an-address", "0449"]
---

# RFC-0521: 다음 턴은 턴 기록에 남은 거절을 읽고 시작점을 고른다

- 상태: 초안.
- 이슈: #52053.
- 관련 이슈: #50020(문장만 있는 400 이 `Unknown_invalid_request` 가 된다), #49634(retained-results carrier 가 창보다 커졌다), #47789(Muse 새 세션 씨앗이 창을 넘었다).
- 먼저 있는 결정:
  - 2026-09-23 운영자 결정(#38286): 사유를 모르는 거절로는 범위를 줄이지 않는다. 예외는 RFC-librarian-lifecycle §4.10 규칙 1(경계 재전송) 하나다.
  - 창 RFC(RFC-keeper-context-window-in-tokens) §1 결정 2: masc 는 바이트 상한을 선언하지 않는다. 보내기 전에 재지도 않는다. 요청이 너무 큰지는 공급자가 판정한다.
  - 2026-11-12 Muse 규칙(RFC-librarian-lifecycle §4.10 의 Muse 항목): 같은 런타임이 거절한 새 세션 씨앗은, 다음 새 세션에서 거절된 시작점보다 엄격히 뒤에서 연다.
- 코드 좌표는 `origin/main` `70c1c015e983` 에서 읽었다. 운영 로그는 읽지 않았다. 사건 수치는 #52053 에 적힌 값이다.

## 읽기 전에 — 말의 뜻

- **턴**: Keeper 실행 한 번이다. 턴 번호(`absolute_turn`)가 붙고, 끝나면 턴 기록(`Turn_record`) 하나를 남긴다. heartbeat 는 턴을 하나씩 돌린다. 프로세스가 턴 중간에 끝나면 그 턴은 기록을 남기지 못한다.
- **끝 줄**: `Turn_ended` 줄이다. 끝난 턴만 쓴다. 실패한 Agent Core 턴은 쓰지 않는다.
- **턴 경계**: 마지막 끝 줄이 말하는 끝 atom 이다.
- **이번 턴의 시작**: 이번 턴이 시작할 때 이력이 가진 atom 수다(`history_at_start`). 그 자리의 atom 이 이번 턴 입력(user 메시지)이다.
- **run 중간 거절**: 같은 턴에서 앞 요청이 응답을 받은 뒤, 뒤 요청이 거절된 것이다. 턴의 첫 요청이 거절된 것은 **첫 요청 거절**이라 부른다.
- **규칙 N(이름)**: RFC-librarian-lifecycle §4.10 의 번호 목록이다. 이 RFC 가 부르는 것은 규칙 1(경계 재전송), 규칙 2(받아들여진 시작점), 규칙 4(gap 블록), 규칙 5(Librarian 이 따라잡으면 돌아옴), 규칙 6(이번 턴 강등), 규칙 7(경계 상한), 규칙 8(이번 턴 시작 재전송)이다. 다른 RFC 의 번호에는 문서 이름을 붙인다.

## 0. 요약

이 RFC 는 공급자가 크기 거절을 문장으로만 말하는 경우를 다룬다.

2026-11-13 15:10 에 Keeper 하나가 일을 받았다. 이 RFC 는 그것을 「15:10 에 시작한 일」이라 부른다. 그 일은 끝나지 않았다. 재시작, 네트워크 오류, rate limit 이 턴마다 실행을 끊었다. 턴마다 도구가 돌았고, 결과는 checkpoint 에 저장됐다. 실패한 턴은 끝 줄을 남기지 않는다. 그래서 턴 경계는 atom 8971 에 머물렀다.

요청은 그 경계부터 실렸다. 실린 범위는 878 KB, 1.58 MB, 2.10 MB, 3.21 MB 로 자랐다. 도구 결과는 모두 원문이었다.

```
model input carried range ... first_atom=8971 atoms=373/9344 transmitted_bytes=3216821 reserved_bytes=128509 current_turn_results=verbatim ...
```

레인의 후보는 Kimi coding 하나다. 모델 창은 1,048,576 토큰이다. 바인딩의 `max-context` 는 500000 이다. 첫 거절은 1,048,968 토큰을 요청했다고 말했다. 창보다 392 토큰 컸다. 그 뒤로 턴마다 약 3.3 MB 의 같은 요청이 나갔다. 1분에 한 번꼴로 약 1,350번이다. 턴은 매번 같은 거절로 끝났다.

실패 줄은 `max_context=500000 context_budget=500000 system_and_user_bytes=246013` 이라고 적었다. 두 값 모두 나간 요청을 말하지 않는다. 500000 은 이 요청을 묶지 않았다. 246 KB 는 실린 범위를 빼고 잰 값이다.

2026-11-14 에 같은 endpoint(`api.kimi.com/coding/v1`, `kimi-k3.1-pro`)에 창보다 큰 입력을 보내 보았다. 답은 HTTP 400 이다.

```json
{"error":{"message":"Invalid request: Your request exceeded model token limit: 1048576 (requested: 1150120)","type":"invalid_request_error"}}
```

크기는 문장에만 있다. `type` 은 일반적인 `invalid_request_error` 이고 `code` 는 없다. `requested` 에는 `max_tokens` 가 더해지지 않는다. coding API 에는 토큰 셈 endpoint 가 없다(404).

masc 는 이 400 을 `Unknown_invalid_request` 로 읽는다. 문장을 읽어 크기 거절로 바꾸면 문자열 분류가 된다. 그래서 규칙 6(이번 턴 강등)과 규칙 8(이번 턴 시작 재전송)은 돌지 않는다. 규칙 1(경계 재전송)은 사유 모르는 400 도 받는다. 그러나 범위가 이미 경계에서 열려 있어 시작점을 옮길 자리가 없다. 거절은 프로세스 메모리에만 남는다. 다음 턴은 같은 checkpoint 에서 같은 범위를 조립한다.

같은 모양의 사건이 전에도 있었다. RFC-0449 B5 의 code-reviewer 는 2,628,071~2,628,082 토큰짜리 요청을 20 턴 보냈다(RFC-0449 §6 근거 줄). 모두 사유 모르는 400 이었다. 공급자가 크기 거절을 문장으로만 말하고 범위가 이미 경계에서 열려 있으면, 어느 걸음도 시작점을 옮기지 못한다.

이 RFC 는 세 가지를 정한다.

1. 끝나지 못한 앞 턴의 도구 결과는, 이번 턴의 시작보다 앞이면 조립 때 마커로 나간다(D1). 대상은 `artifact_read` 가 있는 Keeper 의 본문 2 KB 이상 결과다. 크기는 재지 않는다. 마커로 바꾸는 선의 위치만 옮긴다.
2. Agent Core 레인도 받아들여지지 않은 범위를 턴 기록에 남긴다(D2). Muse 가 쓰는 `refused_model_input` 칸을 쓴다.
3. 같은 런타임의 다음 조립은 그 기록을 읽고 시작점을 고른다(D3). 거절된 시작점보다 엄격히 뒤인 턴 경계나 이번 턴의 시작에서 연다. 이번 턴의 시작보다 뒤로는 가지 않는다. run 중간 거절이면 같은 시작점에 D1 을 적용한 요청을 먼저 보낸다.

실패 줄에는 마지막 요청의 `transmitted_bytes` 를 싣는다(§4). D1 과 D2·D3 는 각각 운영자 결정 뒤에 들어간다(§7 의 1).

## 1. 지금 동작

### 1.1 공급자 경계

- HTTP 400·422 는 `InvalidRequest { reason = Unknown_invalid_request }` 가 된다(`packages/agent_core/lib/llm_provider/retry.ml:370-371`). 413 만 상태 줄로 `Request_body_refused_by_provider` 가 된다(:372-380).
- 본문에서는 `error.message` 만 꺼낸다. `error.type` 과 `error.code` 는 남기지 않는다(`packages/agent_core/lib/llm_provider/api_common.ml:55-69`).
- typed 넘침은 셋뿐이다. GLM 의 code 1261, HTTP 413, 빈 응답의 `ContextWindowExceeded` 종료 사유다(#50020).
- `Unknown_invalid_request` 는 재시도 대상이 아니다. 바꾸지 않은 요청에는 영구적인 거절이다(`lib/keeper_runtime/keeper_runtime_failure_route.mli:78-86`).
- `kimi_coding` 은 `openai_compat` 이다(`packages/agent_core/models.toml:2960-2961`, `config/runtime.toml:354-356`).

### 1.2 바인딩 예산이 닿는 곳

- 바인딩의 `max-context` 는 provider config 의 `max_context` 로 간다(`lib/runtime/runtime_adapter.ml:732-734`, `packages/agent_core/lib/llm_provider/provider_config.ml:310-315`).
- agent_core 는 `Require_exact_fit` 일 때만 그 값과 요청을 비교한다. provider 의 셈 endpoint 로 입력 토큰을 센다. 넘으면 보내기 전에 typed `ContextOverflow` 로 거절한다(`packages/agent_core/lib/llm_provider/prepared_completion_request.ml:363-389`, `packages/agent_core/lib/pipeline/pipeline_stage_route.ml:164-178`). 그 요청은 나가지 않는다.
- `Require_exact_fit` 는 셈을 지원하는 종류(`Anthropic`, `Kimi`)나 serving constraint 를 선언한 모델에만 걸린다(`lib/runtime/runtime_agent_context.ml:199-206`, `packages/agent_core/lib/llm_provider/count_tokens_sync.ml:124-130`).
- `kimi_coding` 은 `openai_compat` 이라 `Body_only` 다. `kimi_coding` 레인에서 500000 은 아무것도 묶지 않는다. 공급자는 자기 창 1,048,576 으로 셌다. 첫 거절이 1,048,968 을 말한 이유다.
- 실패 줄은 그 값을 그대로 찍는다(`lib/keeper/keeper_unified_turn.ml:1068-1104`). `system_and_user_bytes` 는 system prompt, world state, user message 의 합이다. 실린 범위는 들지 않는다. 코드 주석도 어림값이라고 적는다(:1093-1098).

### 1.3 범위 조립

파일은 모두 `lib/keeper/keeper_turn_driver_try_provider.ml` 이다.

- 범위의 시작은 `choose_range_start` 한 곳이 고른다(:1279-1299). Librarian 지점이 없으면 ledger, 거절이 옮긴 앞머리, 냉시동 씨앗, 턴 경계 순이다(`carried_front`, :1677-1718).
- 턴 경계는 마지막 끝 줄의 끝 atom 이다. 실패한 Agent Core 턴은 끝 줄을 쓰지 않는다. stage save 가 그 atom 을 들고, 다음 끝 줄이 그 구간을 덮는다(`lib/keeper/keeper_agent_run.ml:1960-1980`).
- Librarian 지점이 있으면, 받아들여진 시작점은 경계보다 뒤로 가지 않는다(규칙 7, `within_turn_boundary`, :1234-1259). 그래서 그 Keeper 에서는 끝 줄 없이 끝난 턴의 atom 이 늘 실린다. `within_turn_boundary` 를 부르는 곳은 `from_librarian_point` 하나다(:1271). Librarian 지점이 없으면 씨앗을 상한 없이 쓴다(`without_point`, :1281-1288).
- 끝난 턴의 도구 결과는 본문이 2,048 바이트 이상이면 마커로 나간다(`aged_result_min_bytes`, :1047). 「끝난 턴」은 경계 앞의 atom 이다(`finished_turn_atoms`, :1054-1058; 조립 :1414-1429). 경계를 모르면 0 이라 아무 결과도 마커가 되지 않는다. 경계 뒤의 결과는 모두 원문이다. 실패한 턴들의 결과도 여기에 든다.
- 이번 턴의 시작은 ctx 에 이미 있다(`history_at_start`, :418; `this_turn_start`, :1204-1212). 조립 함수도 이미 받는다(:1384). 이 파일에서 그 값을 읽는 곳은 규칙 8 과 규칙 7 의 예외뿐이다.
- 범위를 이번 턴의 시작이나 경계에서 열면 첫 atom 은 user 메시지다. 그때는 생략 안내문(preamble)이 붙지 않는다(`lib/runtime/runtime_model_input_tail_window.ml:406`). 안내문은 첫 atom 이 assistant·tool·system 일 때만 붙는다(:407-409).
- `reserved_bytes` 는 도구 스키마와 system prompt 의 바이트다(:963-976). 로그와 manifest 에만 쓰인다. 주석은 「창에서 먼저 뺀다」고 적는다(:960-962). 실제로는 아무것도 빼지 않는다.
- 실린 범위 로그 줄은 시도마다 첫 요청에서 한 번만 찍힌다(:1902, :2103-2142). run 중간 요청의 크기는 어느 줄에도 없다.

### 1.4 거절 사다리

아래 걸음은 안에서 밖으로 감싼다(:3367-3523).

| 걸음 | 함수 | 받는 거절 | 다시 보내는 조건 |
|---|---|---|---|
| carrier·memory | `memory_capacity_retry_sequence` :3354-3365 | `is_size_refusal` | carrier 나 memory 가 엄격히 줄 때 |
| 규칙 1(경계 재전송) | `turn_boundary_resend_sequence` :3218-3262 | `boundary_resend_on`(:3164-3193): typed 둘과 `Unknown_invalid_request` | 경계가 거절된 첫 atom 보다 엄격히 뒤(:3243) |
| 규칙 6(이번 턴 강등) | `current_turn_demotion_sequence` :3277-3297 | `is_size_refusal`(:3013-3057) | 강등한 조립이 엄격히 작을 때 |
| 규칙 8(이번 턴 시작 재전송) | `this_turn_start_resend_sequence` :3313-3344 | `is_size_refusal` | 이번 턴 시작이 엄격히 뒤(:3333) |

- `is_size_refusal` 은 `ContextOverflow` 와 `Request_body_refused_by_provider` 에만 참이다. `Unknown_invalid_request` 갈래의 주석은 두 가지를 적는다(:3017-3027). 짧은 범위로 다시 보내 받아들여지면, 크기가 문제가 아니었는데도 잘린 앞머리가 이후 모든 턴에 남는다. 문장만 있는 크기 거절도 여기 오며, 그 크기에는 parse 경계의 typed 사유가 필요하다.
- 규칙 1 은 경계에서 다시 보낸 요청이 크기 밖의 이유로 거절되면 앞머리를 되돌린다(:3250). 주석은 그 이유를 「크기와 무관한 거절로 맥락을 자른다」로 적는다(:3211-3217).
- 모든 걸음은 run 이 durable checkpoint 단계에 닿기 전에만 돈다(`same_run_retry_allowed`, :802-806).
- carrier 걸음(#49634)도 문장만 있는 400 에는 닿지 않는다. RFC-retained-results-carrier-shrinks-to-an-address 가 그렇게 적는다.

### 1.5 #52053 에 대 보면

1. 범위는 이미 경계 8971 에서 열렸다. origin 이 `Carried` 나 `Past_librarian_point` 면 규칙 1 의 조건 `8971 > 8971` 이 거짓이다. `Turn_start` 면 규칙 1 의 첫 갈래에 들지 않는다. 어느 쪽이었는지는 확인 필요다. 결과는 같다.
2. 거절은 `Unknown_invalid_request` 다. carrier·memory, 규칙 6, 규칙 8 은 돌지 않는다.
3. 후보가 하나라 턴이 그 오류로 끝난다. `turn terminal (non-exhaustion error)` 가 찍힌다(`lib/keeper/keeper_unified_turn_terminal_error.ml:41-46`). 실패 연속 수가 오르고, lifecycle 은 active 로 남는다(`lib/keeper/keeper_unified_turn_failure.ml:13-77`).
4. route 는 `Unattributed` 를 `Rotate_now { Request_refused }` 로 읽는다(`lib/keeper_runtime/keeper_runtime_failure_route.ml:332-339`). 같은 경로에 같은 본문을 보내면 같은 답이 온다고 적는다(:761-785). chat 작업의 지연 재개만 이 판정을 읽는다.
5. heartbeat 는 실패한 턴의 자극을 그대로 둔다(`Batch_no_action`, `lib/keeper/keeper_heartbeat_loop.ml:743-749`). 다음 턴은 평소 간격으로 돈다.

### 1.6 거절이 남기는 것

- 거절된 범위를 typed 로 적는 칸은 있다(`Turn_record.refused_model_input`, `lib/types/turn_record.mli:134-148`). 생성자는 Muse 의 `Model_error_not_retryable` 하나다. 칸은 턴 기록마다 하나다(`turn_record.mli:284`).
- `refused_model_input` 을 채우는 런타임은 Muse 하나다(`lib/keeper/keeper_turn_driver.ml:3322`, :3356). Codex, Antigravity, Claude Code 는 버린다(:3006, :3185, :3475). Agent Core 갈래는 부르지 않는다. 기록을 쓰는 길은 이미 있다(`keeper_agent_run.ml:1605-1606`, :2362). 그 길은 거절이 올 때마다 칸을 덮어쓴다.
- 읽는 쪽도 공식 클라이언트 host 하나다(`lib/keeper/keeper_official_client_host.ml:491-552`). Agent Core 조립은 씨앗 읽기 결과에서 `seed` 만 읽는다(`keeper_turn_driver_try_provider.ml:1951`, :1985).
- 읽는 쪽의 scan(`scan_refusal`, `lib/keeper/keeper_carried_front.ml:151-158`)은 새 기록부터 읽는다. 응답이 있는 기록을 만나면 그 기록의 거절도 답한 것으로 본다(:139-143). Muse 는 새 세션 씨앗의 거절만 적는다. 그래서 Muse 의 기록에서는 같은 기록의 응답이 늘 거절 뒤다. Agent Core 는 응답마다 응답 칸을 덮어쓴다(`keeper_turn_driver_try_provider.ml:2370-2393`, `keeper_agent_run.ml:1601-1604`).
- 실패한 턴의 `model_input_window` 는 시도한 마지막 범위다. 응답 관측이 없으면 끊긴 연결과 모양이 같다(`turn_record.mli:150-158`). 거절이라는 표시가 없다.
- 거절이 옮긴 앞머리는 `run_named` 한 번에만 산다(`keeper_turn_driver.ml:2219`). 그 칸은 턴의 것이다. 같은 턴의 모든 Agent Core 후보가 읽고(:3720-3722), 공식 클라이언트 씨앗도 읽는다(:2219-2243). ledger 는 프로세스 메모리이고 응답에서만 움직인다.
- 턴 기록은 턴 끝에서 한 번 쓴다(`keeper_agent_run.ml:2317-2362`). 프로세스가 턴 중간에 끝나면 그 턴의 응답도 거절도 파일에 남지 않는다.

그래서 다음 턴은 같은 범위를 같은 원문으로 조립한다.

## 2. 목표와 하지 않는 것

### 2.1 목표

1. 같은 런타임이 받지 않은 범위를, 시작점을 옮길 자리가 있는 동안 다음 턴이 같은 본문으로 다시 보내지 않는다.
2. 끝나지 못한 앞 턴들의 도구 결과가 원문으로 쌓이는 길을 조립 때 줄인다.
3. 실패 줄이 실제로 실린 범위의 크기를 보인다.

수용 기준은 셋이다.

- #52053 모양의 시험(§5 C-11)에서 공급자는 거절한 본문을 다시 받지 않는다.
- 다음 턴의 시작점은 거절된 시작점보다 엄격히 뒤다. 예외는 둘이다. 후보 0 은 같은 시작점에서 D1 이 바꾼 본문을 보낸다. 바닥에서는 같은 범위가 다시 나간다(§3.2 D3).
- D3 가 고른 시작점은 이번 턴의 시작보다 뒤로 가지 않는다. 그래서 그 요청은 이번 턴 입력을 싣는다.

### 2.2 하지 않는 것

- 오류 문장을 읽지 않는다. `exceeded model token limit` 도 읽지 않는다.
- 바이트를 토큰으로 바꾼 값을 공급자 셈처럼 쓰지 않는다. 바인딩 예산과 masc 의 바이트를 비교하지 않는다.
- 재시도 횟수 상한, cooldown, 타이머, dedup 을 넣지 않는다.
- 바닥에서 같은 범위를 다시 보내는 일을 막지 않는다. 바닥은 이번 턴의 시작이 거절된 시작점보다 뒤가 아닐 때와, 이번 턴의 시작을 모를 때다(§3.3).
- 규칙 1·6·8 의 트리거는 바꾸지 않는다. `is_size_refusal` 은 그대로다. 그러나 typed 레인의 다음 턴 동작은 바뀐다(§6 L3).
- 실패한 턴의 새 끝 줄을 만들지 않는다. RFC-librarian-lifecycle §4.10 규칙 8 의 하위 항목이 네 이유로 버렸다.
- Keeper 를 멈추는 Gate 를 더하지 않는다. lane 회전 규칙도 그대로다.
- 옛 턴 기록을 읽는 reader 를 만들지 않는다.
- 공식 클라이언트 레인의 시작점 규칙은 바꾸지 않는다. scan 을 고친 결과가 Muse 에 닿는 경우는 §3.2 D3 에 적는다.
- 턴 기록의 거절 칸은 하나로 둔다. 후보마다 남기는 것은 §7 의 11 이다.

## 3. 설계

이 절과 §4 에서 파일 이름 없이 적은 줄 번호는 `lib/keeper/keeper_turn_driver_try_provider.ml` 의 줄이다.

### 3.1 후보

#### A. 보내기 전에 바인딩 예산으로 범위를 묶는다

조립할 때 실린 범위를 실패 줄이 찍는 예산(500000)에 대 본다. 이번 턴도 포함한다. 넘으면 지금은 거절 뒤에만 도는 규칙 6 의 강등을 보내기 전에 돌린다.

- 장점
  - 거절된 요청이 아예 나가지 않는다.
  - 바인딩이 고른 500000 이 Agent Core 요청을 처음으로 묶는다.
- 단점
  - 예산은 토큰이다. 이 레인에서 masc 는 바이트만 잰다. 셈 endpoint 도 없다(404). 바이트를 토큰으로 바꾸는 순간 어림값이 공급자 셈 자리에 선다.
  - 창 RFC §1 결정 2 와 맞선다. 창 RFC §13.2 가 `max-prompt-bytes` 를 지운 이유(critic 30턴 실패)와 같은 모양이 된다.
  - 조립 때 이번 턴을 마커로 보내는 일은 창 RFC §13.6 이 남긴 설계다. 창 RFC §1 결정 6 과 §13.7 이 RFC-librarian-lifecycle §7 (라)를 선행 조건으로 건다.
  - 셈 endpoint 가 있는 레인에는 이미 길이 있다. `Require_exact_fit` 가 보내기 전에 typed `ContextOverflow` 를 낸다(§1.2). 규칙 6·8 이 그 거절에 답한다. `kimi_coding` 에는 셀 수단이 없다.
- 판정: 예산 비교는 넣지 않는다. 크기를 재지 않는 부분, 곧 마커로 바꾸는 선의 위치만 D 로 남긴다.

#### B. 한 번 거절된 범위의 사유 모르는 400 을 답으로 보고 한 번 강등한다

규칙 1 은 이미 사유 모르는 400 에 한 번 다시 보낸다. 같은 판정을 규칙 6 에도 넓히는 안이다.

- 장점
  - 범위를 좁히지 않는다. 결과는 마커로 남아 `artifact_read` 로 다시 열린다.
  - 바뀌는 코드가 작다.
- 단점
  - 같은 턴 안에서 같은 범위는 두 번 나가지 않는다. 규칙 1 은 시작점이 움직일 때만 다시 보낸다. 그래서 「한 번 거절된」을 알려면 거절을 어딘가 적어야 한다.
  - 프로세스 메모리에 세면 횟수 문턱이 된다. 재시작이 그 수를 지운다. #52053 의 턴들을 끊은 것이 재시작이다. 파일에 적으면 C 가 된다.
  - #38286 은 마커 강등을 typed 크기 거절 둘로 묶었다. B 는 그 결정을 같은 턴 안에서 되돌린다.
  - 강등은 도구 결과만 줄인다. assistant 글, 인자, 이미지는 그대로다. 결과 밖의 몫이 크면 B 뒤에도 같은 거절이 되풀이된다. 3.21 MB 중 결과 본문 몫은 재지 않았다.
- 휴리스틱인가
  - 판정 재료는 두 가지다. 「이 범위가 거절됐다」는 기록과 `Unknown_invalid_request` 라는 생성자다. 둘 다 문장이 아니고 어림값도 아니다. 그래서 문자열 분류는 아니다.
  - 그러나 처방으로 강등을 고르면 원인을 크기로 읽는 셈이다. 사유 모르는 거절에서 확실한 사실은 하나다. 바꾸지 않은 본문은 같은 답을 받는다. 무언가를 바꿔 보내야 한다는 데까지는 맞다. 무엇을 바꿀지는 거기서 나오지 않는다.
  - 「같은 턴 안에서 한 번 거절됐으면」으로 두면 횟수 문턱이라 휴리스틱이다. 기록 대조로 두면 C 와 같아진다.
- 판정: 단독으로 넣지 않는다. 거절을 적는 일은 D2 가, 바꿔 보내는 일은 D3 가 맡는다.

#### C. 거절된 범위를 증거로 적고, 다음 턴은 다른 범위를 보낸다

- 장점
  - 보내는 때는 바꾸지 않는다. 보내는 범위만 바꾼다. Gate 가 아니다.
  - 걸음은 시작점을 엄격히 뒤로 옮길 때만 있다. 횟수를 세지 않고 끝난다.
  - 턴 기록은 파일이다. 재시작 뒤에도 같은 값을 읽는다.
  - 칸과 읽는 법이 이미 있다. Muse 규칙(#47789)과 규칙 2(받아들여진 시작점)가 같은 칸, 같은 scan 을 쓴다.
- 단점
  - 사유 모르는 400 이 크기와 무관할 수 있다. 도구 스키마 오류, 지원하지 않는 파라미터, 읽지 못하는 이미지가 그렇다. 그때 C 는 맥락을 헛되이 뺀다. 응답이 올 때까지 턴마다 거절되는 요청이 하나씩 더 나간다.
  - 원인이 풀린 뒤 받아들여진 시작점이 받아들여진 시작점이 된다. Librarian 지점이 있으면 Librarian 이 따라잡을 때 돌아온다(규칙 5). 없으면 그 시작점이 이후 모든 턴에 남는다(`without_point`, :1281-1288). 빠진 atom 은 checkpoint 에만 남는다.
  - 지금 코드는 같은 턴 안에서 이 비용을 일부러 막는다. `is_size_refusal` 의 주석(:3017-3023)과 규칙 1 의 앞머리 되돌리기(:3250)다. C 는 턴을 넘어 그 비용을 되살린다.
  - 규칙 1 과 판단이 갈린다. 규칙 1 은 경계에서 다시 보낸 요청도 크기 밖 이유로 거절되면 「경계는 이 거절에 답하지 못했다」고 보고 앞머리를 되돌린다. D2 는 그 경계 범위를 마지막 요청으로 적고, 다음 턴에 D3 는 경계보다 뒤로 옮긴다.
  - 같은 꼴의 위험을 이미 잡는 모델이 있다. `specs/bug-models/LibrarianContinuityWidth.tla` 는 크기 밖 거절에 폭을 좁히는 것을 버그(`RefuseOtherNarrowing`, `LibrarianContinuityWidth.tla:162-173`)로 두고, `WidthHoldsOnOtherRefusal`(`LibrarianContinuityWidth.tla:120-121`)로 막는다. 그 모델은 거절의 원인을 안다. 여기서는 원인을 모른다.
  - C 도 원인을 크기로 보고 범위를 줄인다. B 와 다른 점은 판정 재료다. 세는 수가 아니라 digest 로 맞춰 본 기록이다. 요청에서 masc 가 바꿀 수 있는 것은 범위뿐이다. 시도 안에서 system prompt 와 도구는 고정이다. 그래서 바꿔 보내는 요청은 범위가 다른 요청일 수밖에 없다.
  - 운영자 결정이 필요하다(§7 의 1 (나)).
- 판정: 넣는다. 운영자 결정 전에는 L3 를 Draft 로 둔다.

#### D. 마커로 바꾸는 선을 이번 턴의 시작으로 옮긴다

코드를 읽다가 찾은 후보다. RFC-tool-results-age-out-of-context 는 규칙을 「현재 턴(마지막 user 메시지)보다 앞」으로 적는다. 코드는 끝난 턴의 경계를 선으로 쓴다. 실패한 턴이 끼면 둘이 갈린다.

- 장점
  - 거절 전에 자라는 길을 줄인다. 크기를 재지 않고 위치만 본다.
  - age-out RFC 에 적힌 규칙과 코드가 같아진다.
  - 결과는 마커와 preview 로 남는다. `artifact_read` 로 다시 열린다. 「끝나지 못한 턴은 이어받을 일일 수 있다」는 규칙 6 의 이유를 지킨다.
  - prefix cache 비용은 끝난 턴의 규칙과 같다. 결과마다 한 번 바뀐다.
  - 창 RFC §11 의 1d 를 되돌리지 않는다. 1d 는 바이트 상한에 맞추던 마지막 수단(#28845 강등)을 거절 뒤로 옮겼다. D 는 상한을 보지 않고 위치만 본다.
- 단점
  - 이어받은 일의 결과를 모델이 원문으로 보지 못한다. 필요하면 `artifact_read` 를 불러야 한다.
  - 본문 2 KB 이상인 결과만 줄인다. 다른 몫이 크면 여전히 창을 넘는다.
  - `artifact_read` 가 없거나 이번 턴 시작을 모르면(resume, digest 불일치) 지금과 같다.
  - 두 RFC 가 이 구간을 다르게 부른다. age-out RFC 에서 [경계, 이번 턴의 시작) 은 지난 턴이다(`RFC-tool-results-age-out-of-context.md:221`). RFC-librarian-lifecycle 규칙 8 은 규칙 1 의 눈으로 그 구간을 이번 턴으로 보고 남긴다. 그 구간의 결과는 typed 크기 거절 뒤에 규칙 6 이 마커로 바꾼다(RFC-librarian-lifecycle.md:620). D 는 거절 없이 바꾼다.
  - 규칙 8 의 끝 줄 거절 이유 ④ 는 두 가지를 적었다(RFC-librarian-lifecycle.md:635). 경계가 실패한 턴의 끝으로 가면 규칙 1 이 규칙 6 보다 먼저 그 구간을 통째로 뺀다. 그리고 그 구간의 결과가 끝난 턴의 결과로 셈해져 마커가 된다. D 는 경계를 옮기지 않으므로 앞의 것은 생기지 않는다. 뒤의 것은 D 가 일부러 하는 일이다.
  - 창 RFC §13.6 의 「지금 턴의 결과도 조립 때 마커로」는 §1 결정 6 과 §13.7 선행 조건 아래에 있다. D 가 그 「지금 턴」에 드는지는 위의 두 정의 가운데 무엇을 따르느냐에 달렸다.
  - age-out RFC 의 다시 읽기 측정은 끝난 턴의 마커만 쟀다. 만든 턴 안에서 바꾸는 경우는 못 쟀다고 적었다(`RFC-tool-results-age-out-of-context.md:139`). 끝나지 못한 턴의 마커를 다시 읽는 몫도 재지 않았다.
- 판정: 넣는다. 위 두 정의 사이의 판단은 운영자가 한다(§7 의 1 (가)). 그 전에는 L2 를 Draft 로 둔다.

#### E. parse 경계에서 typed 사유를 읽는다(#50020)

`is_size_refusal` 주석이 가리키는 길이다. GLM 의 code 1261 이 그 예다. 측정한 Kimi 본문에는 읽을 typed 칸이 없다. Kimi 문서가 기계가 읽을 신호를 주는지는 확인 필요다. 신호가 있는 공급자에서는 E 가 먼저다. C 는 typed 로 남지 않는 거절에 대한, 턴을 넘는 답으로 남는다.

#### F. 실패한 턴에 typed 끝 줄을 쓴다

RFC-librarian-lifecycle §4.10 규칙 8 의 하위 항목이 네 이유로 버렸다. 다시 열지 않는다.

### 3.2 결정

D 와 C 를 넣는다. A·B 는 넣지 않는다. E 는 신호가 있는 공급자에서 따로 한다.

D 가 먼저다. 끝나지 못한 앞 턴의 결과를 마커로 보내고도 창 안에 들면 거절 자체가 없다. 들지 않으면 C 가 다음 턴의 시작점을 고른다.

C 의 걸음 가운데 같은 시작점에서 바꿔 보내는 것은 후보 0 하나다. 첫 요청 거절이면, 마커가 켜진 Keeper 의 그 요청은 이미 D1 을 거쳤다. 앞 턴들의 2 KB 이상 결과가 이미 마커였다. 그래서 같은 시작점에서 D1 이 더 바꿀 것이 없다. run 중간 거절은 다르다. 거절된 요청에는 그 턴의 결과가 원문으로 실려 있었다. 다음 턴에는 그 결과가 D1 의 선 앞에 든다. 그래서 같은 시작점에서도 본문이 달라질 수 있다. 후보 0 이 그 요청을 먼저 보낸다. 규칙 6 이 규칙 8 보다 먼저인 이유와 같다. 남길 수 있으면 남긴다(RFC-librarian-lifecycle.md:627). `artifact_read` 가 없는 Keeper 는 규칙 6 도 아무것도 바꾸지 못한다(`demotion_base_path` 가 빈다, :1879). 2 KB 미만 결과와 인자의 몫은 재지 않았다(§7 의 4).

#### D1. 마커 선은 이번 턴의 시작이다

- `finished_turn_atoms` 가 이번 턴의 시작을 받는다. 선은 아는 값 가운데 뒤의 것이다. 이번 턴의 시작을 알면 그 값이다. 끝난 턴은 이번 턴 전에 끝났으므로 경계가 그보다 뒤일 수 없다.
- 이번 턴의 시작은 `this_turn_start ~history_digest_at history_at_start` 로 읽는다. 모르면 턴 경계다. 그래서 resume 턴과 digest 가 맞지 않는 턴은 지금과 같다.
- 경계를 모르고(`Turn_boundary_unknown`) 이번 턴의 시작을 알면, 선은 이번 턴의 시작이다. 지금은 0 이라 아무 결과도 마커가 되지 않는다(:1054-1058). 경계를 모른다고 이번 턴의 시작 앞이 지난 턴이 아니게 되지는 않는다. `finished_turn_atoms` 의 주석도 같이 고친다. 둘 다 모르면 0 이다.
- 가장 새 atom 은 지금처럼 늘 원문이다(`Keeper_carried_front.clamp`).
- 바뀌는 것은 `Finished_turns_as_markers` 의 범위뿐이다. 인자, 문턱 2,048, `Current_turn_demoted`, 범위의 시작은 그대로다.
- 선은 턴 시작에 한 번 정해진다. 같은 시도의 요청마다 다시 계산하지 않는다.
- 모듈: `lib/keeper/keeper_turn_driver_try_provider.ml`(`finished_turn_atoms`, `compose_carried_model_input` :1414-1429).
- RFC-tool-results-age-out-of-context 「구현 방향」의 「자리」 항목은 턴 경계를 `demote_before` 로 넘긴다고 적는다. 같은 PR 에서 「이번 턴의 시작」으로 고친다.

#### D2. Agent Core 레인도 받아들여지지 않은 범위를 적는다

`Turn_record.model_input_refusal` 에 생성자 셋을 더한다. `Retry` 생성자와 하나씩 맞는다.

| `Agent_core.Error` | 기록 | JSON |
|---|---|---|
| `Api (ContextOverflow _)` | `Context_overflow` | `"context_overflow"` |
| `Api (InvalidRequest { reason = Request_body_refused_by_provider _ })` | `Request_body_refused` | `"request_body_refused"` |
| `Api (InvalidRequest { reason = Unknown_invalid_request })` | `Invalid_request_reason_unknown` | `"invalid_request_reason_unknown"` |
| 그 밖의 모든 생성자 | 없음 | 없음 |

- 분류는 `range_refusal_of_error` 한 함수가 한다. catch-all 없이 모든 생성자를 적는다.
- `boundary_resend_on` 은 이 함수의 `Option.is_some` 으로 바꾼다. 같은 분류를 두 곳에 적지 않는다.
- 후보의 시도가 이 세 거절 가운데 하나로 끝나면, 그 후보가 마지막으로 조립한 요청의 범위(`state.last_request`)를 `on_refused_model_input` 으로 넘긴다. 사다리를 다 걸은 뒤의 마지막 요청이다. 조립한 요청이 없으면 아무것도 적지 않는다.
- `state.last_request` 는 보낼 때가 아니라 조립할 때 채워진다(`keeper_turn_driver_try_provider.ml:2237-2250`). 그래서 `Require_exact_fit` 레인이 보내기 전에 낸 `ContextOverflow` 도 그 범위로 적힌다(§1.2). 그 요청은 나가지 않았다. 두 경우는 `Agent_core.Error` 값으로 갈리지 않는다. 기록이 말하는 사실은 「이 런타임이 이 범위를 받지 않았다」이다. 공급자가 판정했는지, agent_core 가 공급자 셈으로 판정했는지는 가르지 않는다. 어느 쪽이든 같은 범위는 같은 답을 받는다.
- 규칙 1 이 경계 재전송 뒤 크기 밖 거절로 앞머리를 되돌린 경우에도, 적히는 범위는 마지막으로 보낸 경계 범위다. 이 충돌은 §3.1 C 의 단점에 적었고, §7 의 1 (나)에서 함께 정한다.
- 기록 칸은 턴마다 하나다. 후보가 여럿인 레인에서 둘 이상이 거절하면 마지막 후보의 거절만 남는다. 이 RFC 는 그 모양을 바꾸지 않는다. 비용은 §3.3, 바꿀지는 §7 의 11 이다.
- Agent Core 갈래가 `on_refused_model_input` 을 받는다. 기록을 쓰는 길은 지금 것을 그대로 쓴다.
- 판정 근거는 `Retry` 생성자뿐이다. 문장은 읽지 않는다.
- 사용 창 조건은 두지 않는다. 쓰는 쪽에도 읽는 쪽에도 두지 않는다. 이유는 셋이다.
  - HTTP 레인은 401·402·403·404·429 를 다른 생성자로 나눈다(`retry.ml:357-390`). 400 의 원인을 사용 창으로 가를 typed 근거가 없다.
  - 거절 뒤에 읽은 사용 창은 그 거절의 원인을 말하지 않는다.
  - 읽는 시각에 `~now` 로 묻는 값을 쓰면 같은 기록이 시각에 따라 다른 시작점을 낸다. 규칙 2 가 기대는 「턴 기록은 파일이므로 다시 띄워도 같은 값을 읽는다」(RFC-librarian-lifecycle.md:612)가 깨진다.
  - Muse 는 이와 다르다. Muse 의 `Model_error` 는 한도와 모델 부재를 한데 담는다. 그래서 Muse 는 쓰는 쪽에서, 거절 뒤에 읽은 사용량과 카탈로그로 기록 여부를 정한다(`keeper_muse_runtime.ml:127-140`, :1846-1850). 이 RFC 는 그 규칙을 바꾸지 않는다.
- 모듈: `lib/types/turn_record.ml(i)`, `keeper_turn_driver_try_provider.ml(i)`, `keeper_turn_driver.ml`.

#### D3. 다음 조립은 기록된 거절을 읽고 시작점을 고른다

Agent Core 후보는 시도마다 한 번 `Keeper_carried_front.read_seed` 의 `refused_start` 를 읽는다. 기록은 아래 조건을 모두 채울 때만 쓴다.

- 그 후보의 `runtime_id` 가 `refused_start.runtime_profile` 과 같다.
- 그 거절에 답한 응답이 없다. 더 새 기록의 응답은 지금처럼 답이다. 같은 기록 안의 응답은 그 window 의 `total_atoms` 가 거절 window 의 `total_atoms` 이상일 때만 답이다. 작으면 그 응답은 거절보다 앞의 요청에 대한 것이다. 같은 run 에서 응답 뒤에 도구 결과가 붙고서야 다음 요청이 나가기 때문이다. 이 판정은 `scan_refusal` 이 한다(`keeper_carried_front.ml:151-158`).
- 거절된 시작 atom 의 digest 가 지금 이력과 맞는다(`refused_start_for_history`).
- Librarian 지점이 거절된 시작점보다 뒤가 아니다.
- 이 후보가 D3 없이 고를 시작점이 거절된 시작점보다 뒤가 아니다.

시작점은 아래에서 처음으로 맞는 자리다.

0. 거절된 시작점. 기록이 run 중간 거절이고, 마커가 켜져 있고(`Finished_turns_as_markers`), 이번 턴의 시작이 거절된 요청의 atom 수(`total_atoms`) 이상일 때만이다. 그때 거절된 요청이 실은 atom 은 모두 D1 의 선 앞에 든다. 판정은 기록의 atom 위치로만 한다. 크기는 재지 않는다.
1. 턴 경계. 거절된 시작점보다 엄격히 뒤일 때.
2. 이번 턴의 시작. 거절된 시작점보다 엄격히 뒤일 때. 이번 턴의 시작을 알 때만 후보다.

맞는 자리가 없으면 바닥이다.

- 이번 턴의 시작을 알면, 이번 턴의 시작은 거절된 시작점과 같다. Agent Core 의 범위는 그 턴의 시작보다 뒤에서 열리지 않는다(규칙 1·8 과 D3 모두 그렇다). digest 가 맞는 이력에서 앞 턴의 시작은 이번 턴의 시작보다 뒤일 수 없다. 그래서 거절된 시작점도 이번 턴의 시작보다 뒤일 수 없다. C-6 이 이 경우를 고정한다. 시작점은 그 자리다. 더 앞의 시작점으로 넓히지 않는다. 같은 범위가 다시 나간다. WARN 을 남긴다(사유 `no_start_past_refused`).
- 이번 턴의 시작을 모르면(resume, digest 불일치) D3 는 시작점을 바꾸지 않는다. 조립은 D3 가 없을 때처럼 시작점을 고른다. WARN 을 남긴다(사유 `this_turn_start_unknown`). 가장 새 atom 으로 가지 않는다. resume 턴의 checkpoint 는 이번 턴 입력과 진행을 이미 담는다(RFC-librarian-lifecycle.md:617). 가장 새 atom 에서 열면 이번 턴 입력이 빠진다. 규칙 7 의 하위 항목(RFC-librarian-lifecycle.md:619)은 시작점을 이번 턴 안으로 옮기지 말라고 적는다.

나머지 규칙은 이렇다.

- 고른 시작점은 그 후보의 조립 안에서만 쓴다. 턴 칸(`refused_carried_front`)에는 넣지 않는다. 그 칸은 턴의 것이라 같은 턴의 다른 후보와 공식 클라이언트 씨앗도 읽는다(§1.6). 한 모델의 창이 거절했다는 사실은 다른 후보의 창을 말해 주지 않는다(RFC-librarian-lifecycle.md:669).
- Librarian 지점이 없는 후보에서는 고른 시작점이 `carried_front` 의 앞머리 자리에 선다. 그래서 ledger 보다 뒤면 ledger 를 이긴다(:1677-1718). Librarian 지점이 있는 후보에서는 `accepted` 자리에 선다(:1980-1986).
- 출처 이름을 하나 더한다: `Keeper_carried_front.Past_recorded_refusal of { turn : int }`. 로그 origin 은 `past_recorded_refusal` 이다.
- 규칙 7(`within_turn_boundary`)은 이 출처를 `This_turn_start_*` 와 같은 갈래로 둔다. 상한은 경계와 이번 턴의 시작 가운데 뒤의 것이다. D3 의 시작점은 이번 턴의 시작을 넘지 않으므로 이 상한에 걸리지 않는다. 경계 갈래에 두면 거절된 범위를 다시 보낸다. 규칙 7 의 하위 항목(RFC-librarian-lifecycle.md:618)도 넓힌 상한을 「이번 턴이 잡은 앞머리」에만 건다고 적는다. D3 의 시작점이 그런 앞머리다.
- 규칙 1 의 match 에도 이 origin 을 적는다. 이 origin 으로 연 범위가 거절되면 규칙 1 의 조건(경계 > 거절된 첫 atom)은 거짓이다. D3 가 경계를 넘거나 경계에서 열기 때문이다.
- 시작점을 후보 1·2 로 옮기면, 요청에 생략 블록 하나를 싣는다. 블록이 담는 값은 셋이다. 빠진 구간의 첫 atom(거절된 시작점), 끝 atom(새 시작점, 미포함), 거절이 적힌 턴 번호다. 문장은 고정 문구에 이 세 정수만 넣는다. 한 시도 안에서 바이트가 같다. 자리는 규칙 4 의 gap 블록과 같다. Librarian 스냅숏 블록 바로 뒤이고, 스냅숏이 없으면 첫 실린 atom 바로 앞이다. 후보 0 은 블록을 싣지 않는다. 빠진 atom 이 없고, 마커가 제 주소를 말한다.
  - 블록을 싣는 이유: 이번 턴의 시작에서 열면 첫 atom 이 user 메시지라 생략 안내문이 붙지 않는다(§1.3). 그러면 모델은 앞 턴들에서 자기가 한 일이 빠진 줄 모른다. #52053 에서는 373 atom 이고, 이미 실행한 도구 호출도 들어 있다. 모델이 효과가 있는 호출을 다시 할 수 있다. masc 규칙은 「과거 사실은 context 로 보여 주고, 다음 행동은 Keeper 가 고른다」이다.
  - 규칙 4 의 gap 블록은 측정이 차이를 보일 때까지 싣지 않기로 했다(RFC-librarian-lifecycle.md:675). 그 판단은 Librarian 스냅숏이 빠진 구간 앞까지를 정리해 두는 Keeper 에서 나왔다. D3 가 빼는 구간은 끝나지 못한 이 일의 진행이고, Librarian 지점이 없는 Keeper 에서는 정리한 것도 없다. 그래서 D3 에는 블록을 싣는다.
- 고르는 함수는 `Keeper_carried_front` 에 하나 둔다. 함수가 받는 것은 지금 Muse 가 읽는 쪽에서 쓰는 조건뿐이다. digest 로 맞춘 거절, Librarian 지점, 이미 뒤인 시작점, 후보 목록이다. 후보 목록은 부르는 쪽이 넘긴다. 공식 클라이언트 host 의 `past_refused_start`(`keeper_official_client_host.ml:522-552`)는 [경계; 가장 새 atom] 을 넘기고, 바닥에서 거절된 시작점에 선다. Muse 의 씨앗에는 이번 턴 입력이 들지 않으므로 가장 새 atom 이 그 레인의 바닥이다. Agent Core 는 [경계; 이번 턴의 시작] 을 넘긴다. 후보 0 은 Agent Core 쪽에서 함수 앞에 따로 본다. 같은 규칙을 두 곳에 손으로 적지 않는다.
- scan 을 고친 결과는 Muse 에도 닿는다. 같은 기록에 다른 후보의 앞선 응답(`total_atoms` 가 작음)과 Muse 의 거절이 함께 있을 때다. 지금은 그 거절을 답한 것으로 본다. 고친 뒤에는 거절이 선다. Muse 혼자 쓴 기록에서는 결과가 같다(§5 C-10).
- 다음 요청 예측(`lib/keeper/keeper_next_request_forecast.ml:764-776`)도 같은 함수로 같은 시작점을 본다.
- 턴은 여전히 그 거절로 끝난다. 거절은 오류로 올라간다(창 RFC §1 결정 2). 바뀌는 것은 다음 턴이 보내는 범위뿐이다.

#52053 에 대 보면 이렇다. 턴 N 이 [8971, 끝) 으로 거절되면 시작점 8971 이 적힌다. 거절이 첫 요청 거절이면, 턴 N+1 에서 경계 8971 은 엄격히 뒤가 아니다. 그래서 이번 턴의 시작부터 열고 생략 블록을 싣는다. 8971 부터 이번 턴의 시작 앞까지는 checkpoint 에 남는다. 거절이 run 중간 거절이면, 턴 N+1 은 후보 0 으로 8971 에서 다시 연다. 턴 N 의 결과는 D1 마커로 나간다. 첫 거절이 어느 쪽이었는지는 확인 필요다(§7 의 2). 첫 거절은 창보다 392 토큰 컸다.

### 3.3 남는 비용

- **끝 줄 없이 끝나는 턴이 이어질 때.** Librarian 지점이 있는 Keeper 에서, D3 로 받아들여진 턴이 다시 끝 줄 없이 끝날 수 있다. 다음 턴은 그 시작점을 턴 기록에서 읽고, 규칙 7 이 경계로 되돌린다. 경계부터 연 범위가 다시 거절되면 D2 가 적고, 그다음 턴이 옮긴다. 끝 줄이 하나 생길 때까지 두 턴에 한 번꼴로 거절이 난다. RFC-librarian-lifecycle.md:626 이 적은 비용과 같은 종류다. Librarian 지점이 없는 Keeper 는 시작점을 그대로 쓰므로 이 비용이 없다.
- **바닥에서 되풀이될 때.** 이번 턴의 시작이 거절된 시작점과 같으면 같은 범위가 다시 나간다. 거절된 턴이 atom 을 남기지 않았을 때다. 이번 턴의 시작을 모르는 resume 턴에서도 D3 는 시작점을 바꾸지 않는다. 그때 매 턴 붙는 부분과 이번 턴 입력만으로 넘치거나, 거절이 크기와 무관하다. 시작점을 옮겨서는 풀리지 않는다. 이 RFC 는 그 반복을 멈추는 장치를 더하지 않는다. WARN, 실패 줄의 `transmitted_bytes`, 턴 기록의 같은 거절 시작점이 그 상태를 보인다. 운영자가 lane 이나 매 턴 붙는 부분을 고쳐야 풀린다.
- **걸음 수.** 거절된 턴이 atom 을 남기지 않으면 시작점은 많아야 두 번 옮긴다(경계, 이번 턴의 시작). 후보 0 은 run 중간 거절마다 한 번이다. 거절된 턴이 atom 을 남기면 상한이 없다. wake atom, admission 이 더한 결과, stage save 가 그런 atom 이다. 그러면 다음 턴의 시작은 그만큼 뒤이고, D3 는 턴마다 그 턴의 시작으로 옮긴다. 응답이 올 때까지 요청은 턴마다 그 턴의 atom 만 싣는다. 거절된 턴이 atom 을 남기는지는 확인 필요다(§7 의 10). C-14 가 이 경우를 고정한다.
- **크기와 무관한 400.** 응답이 올 때까지 턴마다 거절되는 요청이 하나씩 나간다. 그동안 시작점은 이번 턴의 시작까지 간다. 원인이 풀리면 그 시작점이 받아들여진 시작점이 된다. Librarian 지점이 있으면 규칙 5 로 돌아온다. 없으면 이후 모든 턴에 남는다(`without_point`, :1281-1288). 영구 비용이다. C-14 가 이 비용을 고정한다. 운영자 결정 대상이다(§7 의 1 (나)).
- **후보가 여럿인 레인.** 턴 기록에는 거절이 하나만 남는다(§1.6). 두 후보가 모두 거절하면 마지막 후보의 거절만 남는다. 앞 후보는 다음 턴에 자기가 거절한 범위를 다시 보낸다. 한 후보가 거절하고 다른 후보가 같은 범위를 받으면, 그 응답이 거절에 답한다. 다음 턴의 받아들여진 시작점은 모든 후보에 쓰인다. 그래서 창이 작은 앞 후보에게 같은 범위가 다시 나간다. 두 경우 모두 앞 후보에서 턴마다 거절되는 요청이 하나씩 나간다. C-15 가 이 비용을 고정한다. 바꿀지는 §7 의 11 이다.
- **재시작으로 끊긴 턴.** 턴 기록은 턴 끝에서만 쓴다(§1.6). 턴 N 이 시작점 B 로 거절되고, 턴 N+1 이 D3 로 받아들여져 도구를 돌린 뒤 재시작으로 끊겼다고 하자. N+1 의 응답은 파일에 없다. 턴 N+2 의 scan 은 여전히 N 의 거절을 읽는다. D3 는 N+2 의 시작에서 연다. 그래서 N+1 이 한 일이 요청에서 빠진다. 생략 블록이 그 구간을 알린다. N+2 가 resume 이면 이번 턴의 시작을 모르므로 D3 는 시작점을 바꾸지 않는다. C-13 이 이 비용을 고정한다. 끊긴 턴의 시작을 D3 가 보게 할지는 §7 의 12 이다.
- **빠진 구간의 내용.** 생략 블록은 빠진 구간이 있다는 것만 알린다. 이 RFC 는 그 atom 을 다시 여는 도구를 더하지 않는다. Librarian 지점이 있으면 그 구간은 기억으로 들어온다(RFC-librarian-lifecycle.md:625).

## 4. 기록과 관측

### 4.1 턴 기록

- 실패한 턴의 기록에 `refused_model_input` 이 남는다. 런타임, 받아들여지지 않은 범위, `Retry` 에서 온 거절 종류다.
- 범위는 지금도 `model_input_window` 에 있다. 새로 남는 것은 「이 런타임이 이 범위를 받지 않았다」는 typed 판정이다. 공급자의 거절일 수도 있고, `Require_exact_fit` 레인이 보내기 전에 낸 판정일 수도 있다(§3.2 D2). 끊긴 연결과 거절이 이제 기록에서 갈린다.
- 디코더는 문자열을 정확히 요구한다. 새 바이너리는 옛 기록을 읽는다. 옛 바이너리로 되돌리면 새 문자열이 든 기록을 읽지 못한다. 읽지 못한 기록은 지금처럼 수와 첫 사유로 보인다. 옛 기록을 위한 reader 는 만들지 않는다. 1.0 전 hard cut 이다.

### 4.2 로그

- 조립이 적힌 거절보다 뒤에서 열면 INFO 한 줄을 남긴다. `model input carried range opens past a recorded refusal runtime=%s refused_first_atom=%d refused_turn=%d first_atom=%d`.
- 후보 0 으로 같은 시작점에서 열면 INFO 한 줄을 남긴다. `model input carried range reopens a refused start with its turn's results as markers runtime=%s refused_first_atom=%d refused_turn=%d this_turn_start=%d`.
- 바닥이면 WARN 한 줄을 남긴다. 사유는 `no_start_past_refused` 와 `this_turn_start_unknown` 둘이다. 닫힌 합으로 둔다. 앞의 것의 문구는 공식 클라이언트 host 의 문구와 같다.
- 시도 안에서 한 번씩만 찍는다. 같은 사실을 요청마다 되풀이하지 않는다.

### 4.3 실패 줄의 `transmitted_bytes`

`keeper cycle FAILED` 줄에 `transmitted_bytes=` 를 더한다.

- 값은 `error_origin` 후보가 마지막으로 조립한 요청의 `transmitted_bytes` 다. 실린 범위 줄과 같은 이름이고, 같은 함수로 센다. 실린 메시지의 `measure_message_bytes` 합이고, system prompt 와 도구는 뺀다.
- 조립한 요청이 없으면 `not_composed` 다.
- 이유: #52053 의 실패 줄은 `system_and_user_bytes=246013` 만 보였다. 실린 범위는 3,216,821 바이트였다. 진단은 246 KB 를 요청 크기로 읽고 출발했다. 실린 범위 줄은 시도의 첫 요청에서만 찍혀, run 중간 요청의 크기는 어디에도 없다.
- `system_and_user_bytes` 는 그대로 둔다. 매 턴 붙는 부분의 크기를 말한다. 다른 질문에 답하는 값이다.
- 공급자 토큰 셈이 아니다. 실린 범위 줄은 첫 요청에서만 찍히므로, 시험은 로그 줄이 아니라 마지막 조립의 `composed.transmitted_bytes` 와 비교한다(§5 O-2).
- 값을 실패 줄까지 옮기는 길은 L1 에서 정한다. 지금 `attempt_state.last_request` 에는 바이트가 없다. `sent_request` 에 `transmitted_bytes` 를 더하는 안이 가장 짧다.

### 4.4 주석과 manifest

- `declared_request_reserve_bytes` 주석의 「창에서 먼저 뺀다」를 「보고만 한다」로 고친다(:960-962).
- manifest 는 바꾸지 않는다. `History_projection_observed` 가 첫 요청의 `projected_bytes` 를 이미 싣는다.

## 5. 시험

각 시험은 옆 칸의 변형을 넣으면 실패해야 한다. 비용을 고정하는 시험(C-13, C-14, C-15)은 그 비용을 없애는 변형에서도 실패한다. 동작을 바꾸려면 이 RFC 부터 고친다.

거절 사다리 자체를 다루는 TLA+ 모델은 없다. 가까운 모델은 `specs/bug-models/` 에 둘 있다. `LibrarianContinuityWidth.tla` 는 Librarian 회차의 폭을 다룬다. 버그 셋을 각자의 Next 로 둔다. 그 가운데 「좁힌 폭을 다음 회차로 넘기지 않는다」는 #52053 과 같은 꼴이다. 「크기 밖 거절에도 좁힌다」는 §3.1 C 의 비용과 같은 꼴이다. `RetainedResultCarrier.tla` 는 carrier 걸음을 다룬다. `specs/` 에는 TLA+ 모듈이 모두 39개 있다. L3 는 새 모델 하나를 더한다(§5.4).

### 5.1 L1: 관측과 fixture

| 시험 | 파일 | 확인 | 잡는 변형 |
|---|---|---|---|
| O-1 | `packages/agent_core/test/test_retry.ml` | 측정한 Kimi 본문과 status 400 이 `InvalidRequest { reason = Unknown_invalid_request; message = "Invalid request: Your request exceeded model token limit: 1048576 (requested: 1150120)" }` 이 된다 | 문장에 `exceeded model token limit` 가 있으면 `ContextOverflow` 로 읽는 갈래. message 대신 본문 전체를 싣는 변형 |
| O-2 | 실패 줄을 만드는 함수의 단위 시험(위치는 L1 에서 정한다) | 둘째 요청에서 거절된 run 의 실패 줄 `transmitted_bytes` 가 둘째 조립의 `composed.transmitted_bytes` 와 같다 | 첫 요청 값을 쓰는 변형. `system_and_user_bytes` 를 복사하는 변형 |

O-1 의 본문은 측정한 바이트 그대로 fixture 로 둔다. 2026-11-14 측정이라는 출처를 시험 주석에 적는다.

### 5.2 L2: D1

파일은 `test/test_keeper_continuity_request_view.ml` 이다. 이력은 경계 4, 이번 턴 시작 8(`Continued_history_from`, digest 일치), 가장 새 atom 10 이다. atom 6 과 atom 9 에 본문 2,048 바이트 이상인 결과가 있다.

| 시험 | 확인 | 잡는 변형 |
|---|---|---|
| D-1 | `Finished_turns_as_markers` 에서 atom 6 은 마커, atom 9 는 원문 | 선을 턴 경계에 두는 변형(지금 코드). 선을 가장 새 atom 까지 미는 변형 |
| D-2 | atom 7 의 digest 가 다르면 atom 6 은 원문 | digest 확인을 빼는 변형 |
| D-3 | `Continued_history` 면 atom 6 은 원문 | resume 을 가장 새 atom 이나 atom 수로 읽는 변형 |
| D-4 | `Finished_turns_verbatim` 이면 아무것도 바뀌지 않는다 | 읽는 도구 없이 마커를 내는 변형 |
| D-5 | 같은 시도의 둘째 요청에서 atom 9 는 여전히 원문이다. 첫 요청이 실은 atom 들의 바이트가 그대로다 | 선을 요청마다 그 요청의 atom 수로 다시 계산하는 변형 |
| D-6 | atom 6 의 인자는 그대로다 | 인자도 선에 맞춰 바꾸는 변형 |
| D-7 | 경계를 모르고(`Turn_boundary_unknown`) 이번 턴 시작 8 을 알면 atom 6 은 마커 | 경계를 모르면 선을 0 으로 두는 변형(지금 코드) |

### 5.3 L3: D2·D3

축소한 #52053 모양: 경계 8, 이번 턴 시작 12, 가장 새 atom 13, 런타임 하나. 다른 모양을 쓰는 시험은 칸에 적는다.

| 시험 | 파일 | 확인 | 잡는 변형 |
|---|---|---|---|
| C-1 | `test/test_turn_record.ml` | 새 문자열 셋이 왕복한다. 모르는 문자열은 거절한다 | 모르는 문자열을 `Model_error_not_retryable` 로 읽는 변형 |
| C-2 | `test/test_keeper_carried_range_eviction.ml` | `range_refusal_of_error` 표가 §3.2 D2 의 표와 같다. `boundary_resend_on` 이 같은 표에서 나온다. `Require_exact_fit` 의 보내기 전 `ContextOverflow` 도 `Context_overflow` 다 | `NetworkError` 를 기록하는 변형. `Json_parse_error` 를 기록하는 변형 |
| C-3 | `test/test_keeper_continuity_dispatch.ml` | 범위를 경계보다 앞인 씨앗(atom 4, origin `Carried`)에서 연다. 첫 요청이 HTTP 400 과 측정한 Kimi 본문을 받으면 규칙 1 이 경계 8 에서 다시 보낸다. 그것도 같은 400 이면 마지막 요청 범위(시작 8)와 `Invalid_request_reason_unknown` 이 기록된다. `NetworkError` 면 기록이 없다 | 기록하지 않는 변형. 첫 조립 범위(시작 4)를 적는 변형 |
| C-3b | `test/test_keeper_carried_front.ml` | 한 기록에 응답(window `total_atoms` 10)과 거절(`total_atoms` 13)이 함께 있으면 거절이 선다. 응답의 `total_atoms` 가 13 이상이면 답한 것이다 | 같은 기록의 응답이 늘 거절을 가리는 변형(지금 코드). `total_atoms` 를 비교하지 않고 같은 기록의 응답을 무시하는 변형 |
| C-3c | `test/test_keeper_continuity_dispatch.ml` | 첫 요청은 받아들여지고, 도구 뒤 둘째 요청이 400 이다. 기록에 응답과 거절이 함께 남고, 다음 읽기에서 거절이 선다 | 둘째 요청 대신 첫 요청 범위를 적는 변형. 거절을 적지 않는 변형 |
| C-4 | `test/test_keeper_carried_front.ml` | 거절된 시작 8(첫 요청 거절)이 적혀 있으면 다음 조립은 12 에서 연다 | 기록을 무시하는 변형(8). 가장 새 atom 으로 가는 변형(13). `>` 를 `>=` 로 바꾼 변형(8) |
| C-5 | 같은 파일 | 거절된 시작 4, 경계 8 이면 8 에서 연다 | 경계를 건너뛰는 변형 |
| C-6 | 같은 파일 | 거절된 시작 12 이면 12 에서 열고 WARN(`no_start_past_refused`)이다. 8 로 넓히지 않고 13 으로 가지 않는다 | 경계로 되돌리는 변형. 가장 새 atom 으로 가는 변형 |
| C-6b | 같은 파일 | `Continued_history`(resume)에서 거절된 시작 8 이면 시작점을 바꾸지 않고 WARN(`this_turn_start_unknown`)이다. 이번 턴 입력이 실린다 | 가장 새 atom 으로 가는 변형(이번 턴 입력이 빠진다) |
| C-7 | 같은 파일 | 다른 런타임, digest 불일치, 더 새 기록의 응답, 거절된 시작보다 뒤인 Librarian 지점, 이미 뒤인 시작점이면 기록을 쓰지 않는다 | 조건 하나씩 뺀 변형 다섯 |
| C-7b | 같은 파일 | 사용 창이 다 찼다는 관측이 있어도 같은 기록에서 같은 시작점이 나온다 | 읽는 쪽에 `Runtime_quota_window.is_exhausted` 조건을 넣는 변형 |
| C-8 | `test/test_keeper_carried_range_eviction.ml` 의 `this turn's start` 묶음 | Librarian 지점 2, 경계 8, 거절된 시작 8, 이번 턴 시작 12 에서 12 로 연다. 규칙 7 이 8 로 되돌리지 않는다 | 새 출처를 경계 갈래에 넣는 변형 |
| C-9 | `test/test_keeper_next_request_forecast.ml` | 같은 기록에서 예측 시작점이 조립 시작점과 같다(RFC-librarian-lifecycle §4.10 의 시험 B13 과 짝) | 예측이 `refused_start` 를 무시하는 변형 |
| C-10 | `test/test_keeper_official_client_host.ml` | Muse 의 기존 시험이 공용 함수와 scan 고침 뒤에도 그대로 통과한다 | Muse 에 이번 턴 시작을 넘기는 변형 |
| C-11 | `test/test_keeper_continuity_dispatch.ml` | 같은 이력에서 두 턴을 잇는다. 대본 공급자는 첫 atom 이 8 이하인 요청을 HTTP 400 과 Kimi 본문으로 거절하고, 나머지는 받는다. 첫 턴은 실패하고 둘째 턴은 받아들여진다. 공급자는 요청 둘을 받고, 두 본문은 다르다. 둘째 요청에 생략 블록(8, 12, 첫 턴 번호)이 있다 | D2 를 뺀 변형(둘째 턴이 같은 본문을 보낸다). D3 가 경계를 고르는 변형(다시 거절된다) |
| C-11b | 같은 파일 | 첫 턴은 첫 요청을 받고, 자란 둘째 요청(atom 10 의 결과가 원문)을 거절당한다. 대본 공급자는 atom 10 의 결과가 원문인 요청만 거절한다. 둘째 턴은 후보 0 으로 8 에서 열고 atom 10 의 결과를 마커로 보낸다. 받아들여진다 | 후보 0 없이 이번 턴 시작으로 가는 변형(시작 12) |
| C-12 | `test/test_keeper_continuity_request_view.ml` | D3 가 12 로 옮긴 시도의 모든 요청에 생략 블록이 하나 있고, 바이트가 같다. 후보 0 의 요청에는 없다 | 블록을 빼는 변형. 블록을 요청마다 그 요청의 atom 수로 만드는 변형 |
| C-13 | `test/test_keeper_continuity_dispatch.ml` | 세 턴: 턴 1 은 시작 8 로 거절, 턴 2 는 12 에서 받아들여져 도구를 돌리고 기록 없이 끊김, 턴 3 은 자기 시작에서 열고 생략 블록이 턴 2 의 구간을 덮는다 | 턴 2 의 구간을 싣는 변형(이 RFC 가 고르지 않은 동작). 블록을 빼는 변형 |
| C-14 | 같은 파일 | 대본 공급자는 범위와 상관없이 모든 요청을 400 으로 거절하다가, 셋째 턴부터 받는다. 턴마다 시작점이 그 턴의 시작으로 간다. Librarian 지점이 없으면 넷째 턴도 셋째 턴의 시작에서 연다 | 사유 모르는 거절에 시작점을 옮기지 않는 변형(L3 이전 동작). 넷째 턴에 경계로 되돌아가는 변형(이 RFC 가 고르지 않은 동작) |
| C-15 | 같은 파일 | 두 후보 레인(A 의 창이 B 보다 작다). 둘 다 거절하면 기록에는 B 의 거절만 남는다. 다음 턴에 A 는 거절된 범위를 다시 보내고, B 는 뒤에서 연다 | A 의 거절을 남기는 변형(B 가 같은 범위를 다시 보낸다) |
| C-16 | 같은 파일 | 두 후보 레인에 A 의 거절이 적혀 있으면 A 만 뒤에서 연다. B 와 공식 클라이언트 씨앗은 D3 없는 시작점에서 연다 | 고른 시작점을 턴 칸에 넣는 변형 |
| C-17 | 같은 파일 | GLM code 1261 대본과 HTTP 413 대본에서 같은 턴 안의 규칙 1·6·8 은 전처럼 돈다. 사다리 끝에서도 거절되면 다음 턴은 D3 시작점에서 연다 | D2 가 `Unknown_invalid_request` 만 적는 변형. typed 거절에 규칙 1·6·8 을 건너뛰는 변형 |

### 5.4 L3: TLA+ 모델

L3 는 `specs/bug-models/RefusedRangeCarry.tla` 를 더한다. 정상 cfg 와 buggy cfg 를 모두 돌린다.

- 상태: 이력 atom 수, 턴 경계, 이번 턴의 시작, 기록된 거절(시작, `total_atoms`, run 중간 여부), 요청의 시작점.
- 정상 `Next`: 응답, 첫 요청 거절, run 중간 거절, 턴 시작(D3), 끊긴 턴.
- 속성
  - `ThisTurnInputCarried`: 요청의 시작점은 이번 턴의 시작을 넘지 않는다.
  - `NoRefusedStartReoffered`: 기록된 거절이 서 있으면, 새 턴의 시작점은 거절된 시작점보다 뒤다. 예외는 바닥과 후보 0 이다.
- `BugAction` 셋. 각 buggy cfg 는 위 속성 가운데 하나를 어겨야 한다.
  - `NoCarry`: 거절을 기록에 넘기지 않는다(지금 코드).
  - `ResponseMasksLaterRefusal`: 같은 기록의 앞선 응답이 거절을 가린다(지금 scan).
  - `PastThisTurnStart`: 이번 턴의 시작을 모를 때 가장 새 atom 으로 간다.
- 크기 밖 거절에도 시작점이 옮겨지는 것은 버그로 두지 않는다. §7 의 1 (나)가 받아들일지 정하는 비용이다. 그래서 `LibrarianContinuityWidth` 의 `WidthHoldsOnOtherRefusal` 같은 속성을 이 모델에는 두지 않는다. 모델 주석에 그 이유를 적는다.

## 6. 단계

native stack 으로 묶는다. 각 층은 자기 changelog 조각을 싣는다.

| 층 | 내용 | 동작 변화 | 먼저 있어야 할 것 |
|---|---|---|---|
| L0 | 이 RFC | 없음 | 없음 |
| L1 | 실패 줄 `transmitted_bytes`, 거짓 주석 고침, Kimi 본문 fixture. 시험 O-1·O-2 | 관측만 | 없음 |
| L2 | D1 과 age-out RFC 한 줄 고침. 시험 D-1~D-7 | 앞 턴들의 결과가 마커로 나간다. 경계를 모르는 턴도 이번 턴 시작 앞은 마커다 | §7 의 1 (가) 운영자 결정. #52053 checkpoint 를 D1 으로 다시 조립해 잰 `transmitted_bytes`(읽기 전용, 운영자 데이터) |
| L3 | D2·D3: 생성자 셋, `range_refusal_of_error`, Agent Core 기록, scan 고침, 공용 시작점 함수, 후보 0, 생략 블록, 규칙 7 갈래, 예측, TLA+ 모델. 시험 C-1~C-17 | 다음 턴의 시작점이 뒤로 간다. typed 레인(GLM 1261, HTTP 413, `Require_exact_fit`)도 바뀐다. 같은 턴 안의 규칙 1·6·8 은 그대로 돌고, 사다리 끝에서도 거절되면 다음 턴은 사다리를 처음부터 다시 걷지 않고 D3 시작점에서 연다 | §7 의 1 (나) 운영자 결정 |

- L2 의 측정은 Ready 전에 한다. 숫자를 문턱으로 쓰지 않는다. D1 이 그 사건을 막았을지를 PR 본문에 적는 데 쓴다.
- L2 의 배포 뒤 확인 항목은 끝나지 못한 턴에서 마커가 된 결과를 다시 읽은 수다. 지금 장부에는 마커로 바꾼 사건과 그 뒤의 읽기를 잇는 칸이 없다(`RFC-tool-results-age-out-of-context.md:139`). 그 칸을 L2 가 같이 더할지는 §7 의 1 (가)에서 정한다.
- L2·L3 는 운영자 결정 전에는 Draft 로 둔다.

## 7. 열린 질문

1. **운영자 결정 두 가지.**
   - (가) D1. [경계, 이번 턴의 시작) 의 결과를 거절 없이 조립 때 마커로 보낼지. age-out RFC 는 그 구간을 지난 턴으로 본다. RFC-librarian-lifecycle 규칙 8 은 규칙 1 의 눈으로 이번 턴으로 보고, 그 결과는 typed 크기 거절 뒤에만 규칙 6 이 바꾼다. 창 RFC §13.6 의 「지금 턴의 결과도 조립 때 마커로」는 §1 결정 6·§13.7 선행 조건 아래에 있다. D1 이 그 조건 밖이라고 볼지, 같은 조건 아래 둘지 운영자가 정한다. 끝나지 못한 턴의 마커를 다시 읽은 수를 잴 칸을 더할지도 같이 정한다.
   - (나) D2·D3. 2026-11-12 Muse 규칙을 Agent Core 의 사유 모르는 400 에 넓힐지. #38286 은 같은 턴 안에서만 막았다. 같은 걱정(크기와 무관한 거절로 맥락을 줄인다)이 턴을 넘어 생긴다. 비용은 셋이다. 응답이 올 때까지 턴마다 거절 요청 하나가 나간다. Librarian 지점이 없는 Keeper 에서는 원인이 풀린 뒤에도 잘린 시작점이 이후 모든 턴에 남는다. 규칙 1 이 「경계는 답하지 못했다」고 되돌린 경우에도 D3 는 경계 너머로 옮긴다.
   - (나) 와 휴리스틱 금지 규칙. D3 의 판정 재료는 기록 대조다. 문장도 횟수도 어림값도 아니다. 그러나 처방은 원인을 크기로 본다. 저장소 규칙은 휴리스틱을 금지한다. 규칙 1(2026-09-23 결정)과 Muse 규칙(2026-11-12)은 같은 처방을 이미 좁게 허락했다. 그 허락을 Agent Core 의 턴 사이로 넓혀도 되는지가 질문이다. 넓히지 않으면 #52053 같은 Keeper 는 D1 으로 들어가지 않는 한 바닥처럼 같은 범위를 다시 보낸다. 규칙 1 의 경계 범위를 적을지, 되돌린 앞머리의 범위를 적을지도 같이 정한다.
2. **#52053 의 origin 과 첫 거절의 모양.** 거절된 요청의 origin 이 `Turn_start`, `Carried`, `Past_librarian_point` 중 무엇이었는지. 첫 거절이 첫 요청 거절인지 run 중간 거절인지. 로그로 확인 필요다. origin 은 §1.5 의 첫 줄을 고친다. 거절 모양은 D3 가 후보 0 을 고를지를 정한다.
3. **#52053 의 Keeper 에 마커가 켜져 있었는지.** `finished_turn_results=markers` 였는지(`artifact_read` 사용 가능). 아니었다면 D1 과 후보 0 은 그 Keeper 에서 아무것도 바꾸지 않는다.
4. **결과 본문의 몫.** 3.21 MB 가운데 2 KB 이상 도구 결과 본문이 얼마인지 재지 않았다. 2 KB 이상 결과 본문의 몫을 재야, D1 만으로 창 안에 드는지 안다. D3 앞에 규칙 6 의 강등 걸음이 따로 필요한지도 그 값으로 안다.
5. **#52053 턴들의 시작 상태.** `history_at_start` 가 `Continued_history_from` 이었는지. resume 이었다면 D1 은 지금과 같고, D3 는 시작점을 바꾸지 않는다. 그러면 이 RFC 는 #52053 을 막지 못한다.
6. **Kimi 의 신호.** Kimi 공식 문서가 크기 거절에 기계가 읽을 신호(error code, header)를 주는지. 확인 필요다. 있으면 E 가 먼저다.
7. **Kimi 의 셈 endpoint.** Kimi 의 Anthropic 호환 endpoint 가 `count_tokens` 를 받는지. 확인 필요다. 받는다면, 그 endpoint 로 묶은 Kimi 레인은 `Require_exact_fit` 가 되어 바인딩 예산이 보내기 전에 걸린다.
8. **`context_fit` 표시.** 실패 줄에 `context_fit=body_only|exact_fit` 도 실을지. `max_context=` 가 그 요청을 묶었는지가 한 줄에서 보인다.
9. **걸음의 시간.** 기록이 이끄는 걸음을 같은 턴 안에서도 돌릴지. 지금 안은 걸음마다 턴 하나가 걸린다.
10. **거절된 턴이 atom 을 남기는지.** 첫 요청 거절로 끝난 턴이 wake atom, admission 결과, 이번 턴 입력을 checkpoint 에 남기는지. 남기면 §3.3 의 걸음 수에 상한이 없고, 바닥에 닿지 않는다. #52053 의 본문이 정말 같았는지도 이 답에 달렸다.
11. **후보마다 거절을 남길지.** 턴 기록의 거절 칸을 런타임마다 하나씩 남기는 모양으로 바꿀지. 바꾸면 C-15 의 비용이 사라진다. 다른 후보의 응답이 이 후보의 거절에 답하는지도 런타임마다 가려야 한다. 받아들여진 시작점(규칙 2)은 지금 런타임을 가리지 않는다. 저장 모양 변경이므로 1.0 전 hard cut 이다.
12. **끊긴 턴의 시작.** 재시작으로 끊긴 턴의 시작을 D3 가 보게 할지. 보려면 응답을 받은 때 무언가를 파일에 남겨야 한다. 턴 기록은 지금 턴 끝에서만 쓴다. 남기지 않으면 C-13 의 비용이 남는다.
