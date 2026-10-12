# A. Runtime Failover · Multi Lane · Provider Admission — 감사 2026-10-07

기준: HEAD 7fb34c7172 (= origin/main). 라이브는 `~/me/.masc` 를 읽기만 했다(GET `/api/v1/dashboard/standalone-lanes`, `/api/v1/runtime/resolved`, `logs/system_log_2026-10-0{5,6}.jsonl`, `tool_calls/2026-10/06.jsonl`). `masc-server-8935.log` 는 부팅마다 새로 써서 10-07 00:05~01:37 만 담고 있다. 그래서 이틀 치 숫자는 일별 `system_log_*.jsonl`(UTC 날짜)에서 셌다.
라이브 `runtime.toml` 은 10-07 04:22 KST 에 바뀌었다. 로그 숫자 일부는 그 전 설정에서 나왔다. 해당 숫자에는 표시를 달았다.

## 1. 날짜별 변경 (이 영역만)

| 날짜 | 변경 |
|---|---|
| 09-30 | 여러 계정이 model set 을 나눠 쓰게 함(#40096). GPT-6.1 Sol ultra(#40090). Codex 사용량 거절 증거 보존(#39997). native resume 이 같은 context 를 다시 보내지 않게 함(#39972) |
| 10-01 | 한 provider 쿼터 때문에 lane 전체가 멈추지 않게 함(#40503). 요청을 보내기 전 네트워크 실패는 격리하지 않음(#40397). Ultra admission 을 provider 경계로 좁힘(#40361). Codex sub-agent 를 막아 D1-02 원인을 줄임(#40364). context window 를 binding 단위로 매김(#40493). config 로딩 리팩터(#40112·#40139·#40213) |
| 10-02 | runtime 재바인딩 뒤에도 exact lane backpressure 귀속을 유지(#40742). 스트리밍 수정(#40736·#40750) |
| 10-03 | exact lane 후보를 원자적으로 교체하고 맨 앞으로 올림(#40723). provider admission 선언 충돌 거절(#40802). 큐 실패 때 admission 상태 노출(#40797). 모르는 capability key 거절(#40926) |
| 10-04 | 조용히 무시되던 provider 필드 거절(#41048 → D1-10 닫힘). 의미 없는 승격 거절(#40874). 계정 identity·usage 정리(#41107·#41109·#41117·#41143) |
| 10-05 | TUI default route 유지(#40824). `max-prompt-bytes` 제거 커밋 18b85e62df(10-06 #41224 로 머지) |
| 10-06 | 우선순위 permit(#41316·#41332). 실행 중 계정 허용량을 바꾸는 config 거절(#41359). Muse 사용률을 한 출처로 기록하고 소진 계정을 먼저 쉬게 함(#41360·#41362). 관리 설정의 Muse observer 정리(#41349·#41355). Exact 를 끄면서 설정 보존(#41162·#41178) |
| 10-07 | 이 영역 코드 변경 없음(7fb34c7172 기준) |

## 2. 기능 표

| 기능 | Happy path | Edge cases | Observability | 판정 | 근거 |
|---|---|---|---|---|---|
| 실패 분류 | 상태 코드와 typed 오류만 읽는다. 오류 문장은 분류에 쓰지 않는다 | OpenAI 호환 HTTP 400 context 초과는 typed overflow 가 아니라 `Unattributed` → `Request_refused` 로 분류된다. 다음 후보로는 넘어가지만 shrink 는 일어나지 않는다 | route label | OK | `retry.ml:327-361`, `candidate_fault.ml:27-51`, `keeper_runtime_failure_route.ml:238-280` |
| Keeper lane 걷기 | 선언 순서로 걷고, 쿼터나 backpressure 가 있는 후보는 뒤로 민다 | 쉬는 후보도 건너뛰지 않고 맨 뒤에서 결국 부른다. Retry-After 없는 429 는 시간이 지나도 풀리지 않는다(#38471) | NEXT REQUEST band | Partial | `keeper_turn_driver.ml:221-277` |
| sticky 마지막 성공 후보 | 없음. #36881(RFC-0457)에서 지웠다 | 아래 "Sticky" 절 참고 | — | OK | `rg Runtime_lane_preference` 결과 0건 |
| 쉼 기록(쿼터·429) | 프로세스 메모리 `Hashtbl`/`Atomic` | 부팅하면 지워진다. 10-05~06 사이 부팅 12번 | 없음 | Partial(D1-06) | `runtime_quota_window.ml:23-25` |
| Exact lane(HTTP slot) | 순서만 바꾼다 | 쉬는 slot 도 계속 부른다 | run record | Partial(L2-04) | `runtime_exact_lane_backpressure.ml:54-61` |
| Exact lane CLI 꼬리 | `order_slots` 로 쿼터 순서만 바꾼다 | "every declared candidate remains eligible" | run record | Partial(D1-01) | `keeper_lane_cli_oneshot.mli:100-105` |
| Vision media_failover | 쿼터 순서만 바꾼다 | 403 이 와도 usage 를 읽지 않고 아무것도 기록하지 않는다 | tool_calls `vision_candidate` | Partial(신규 측정) | `keeper_vision_tool.ml:84-90,546-556,700-712` |
| 403 뒤 usage-read | Keeper 걷기에서만 읽는다. 다 쓴 window 면 scope 를 reset 까지 쉬게 한다 | 429 에서는 읽지 않는다(D1-07). vision·exact·fusion 걷기는 읽지 않는다 | `provider usage read after a 403` | Partial | `keeper_turn_driver.ml:970-982` |
| Standalone lane 7개 | 7개 모두 `configuration_state=ready` | hitl_auto_judge·browser_stagehand·candle_appraiser 는 run 기록이 0건이다 | projection | OK | 라이브 projection |
| 판정 lane 다중화 | verifier: HTTP 2 + CLI 5 | hitl_auto_judge·board_attention 은 slot 하나(glm-5.3-flash)뿐이고 CLI 꼬리도 없다 | projection | Partial(D1-09) | `runtime.toml:88-101` |
| Admission 우선순위 | HTTP exact flow 는 모두 `Standalone_lane.admission_class` 를 넘긴다 | 새로 찾은 구멍 없음. 추적 중인 PR·이슈는 다시 파지 않았다 | `/runtime` | OK(범위 안) | `keeper_librarian_runtime.ml:436`, `hitl_summary_worker.ml:420`, `keeper_board_attention_exact_flow.ml:196` |

## 3. 10-01 발견의 현재 상태

| id | 상태 | HEAD 근거 |
|---|---|---|
| D1-01 | **열림. 라이브에서 더 커짐** | `keeper_lane_cli_oneshot.mli:100-105` 는 여전히 순서만 바꾼다. 10-05 에 Librarian CLI 꼬리가 quota_blocked 상태의 `claude_code.claude-sonnet-5-5-medium` 을 **1,265번** 불렀다(같은 날 `Claude Code turn failed (kind=quota_blocked)` 1,312줄). 10-06 에는 HTTP slot `ollama-cloud-glm-5-3-flash` 에서 429 가 254번 났다 |
| L2-04 | 열림 | `runtime_exact_lane_backpressure.ml:54-61` `order_at` 은 아직 `serving @ resting` 으로 순서만 바꾼다. 10-05 verifier 는 7일 window 를 다 쓴 kimi 를 223번 불렀다(`evaluator unavailable runtime=kimi… retryable=false`). 10-06 에 운영자가 설정에서 kimi 를 빼서 사라졌다 |
| D1-02 | 사실상 닫힘 | #40364 뒤 `identity does not match` 가 10-05·06 이틀 동안 0건이다. 다만 오류 문장에 받은 id 를 넣는 진단 개선은 하지 않았다(`runtime_codex_app_server.ml:1080`) |
| D1-03 | 열림(운영 설정) | 배정 29명 중 **11명**(이전 27명 중 15명)이 후보 하나뿐이다. 아래 "단일 후보" 표 참고 |
| D1-06 | **열림. 피해를 처음 숫자로 확인** | `runtime_quota_window.ml:23-25` 는 여전히 `Hashtbl` 이다. kimi 7일 window(10-07 10:10Z 까지)를 10-06 01:03Z 에 읽었지만 01:32Z 부팅(`masc-start-1006-1032`)에서 사라졌다. 10-05~06 사이 부팅은 12번이다 |
| D1-08 | 열림 | `server_dashboard_runtime_resolved_json.ml:29,37` 이 `failed_attempt = _` 로 버린다 |
| D1-09 | 일부 닫힘(운영자) | verifier 에 HTTP 2개와 Claude Code CLI 5개가 붙었다. hitl_auto_judge·board_attention 은 여전히 slot 하나다 |
| D1-10 | **닫힘** | #41048: `runtime_toml.ml:813-830` 에서 `unknown_table_keys ~expected:provider_keys` 를 호출한다 |
| D1-04/05/07 | 설계대로(10-01 판정 유지) | D1-07 은 라이브 비용이 커서 아래 A-02 로 다시 올린다 |

## 4. 발견 (P0→P3)

### A-01 · P2 · Vision 걷기는 403 을 받아도 usage 를 읽지 않아, 7일 window 를 다 쓴 kimi 를 vision 호출마다 먼저 부른다
- 위치: `lib/keeper/keeper_vision_tool.ml:84-90`(`demote_order` 는 순서만 바꾼다), `:546-556`(`note_candidate_account` 는 402 만 기록), `:700-712`(403 은 `candidate_policy_http_error` 로 처리하고 바로 다음 후보로 넘어간다). 라이브 `media_failover = [kimi, deepseek]`.
- 들어온 때: #36845 이전(shallow clone 이라 더 못 거슬러 올라감).
- 실패 시나리오: kimi 가 403 "weekly (7-day) usage limit" 으로 거절한다. vision 걷기는 deepseek 으로 넘어가 답을 받는다. 남기는 기록은 없다. 다음 vision 호출도 kimi 부터 부른다. 10-06 `tool_calls/2026-10/06.jsonl` 에 kimi `candidate_policy_error` 가 **136번**, 이어서 deepseek `provider_response` 가 134번 있다. 같은 날 agent_core 의 kimi HTTP 403 경고도 정확히 136줄이다. 136줄 중 Keeper 걷기에서 나온 것은 4번(judas-priest 3, rondo 1)뿐이다.
- 고리 분석: tick 1 은 kimi 403 → deepseek 답. tick 2..N 도 같다. window 가 reset 될 때(10-07 10:10Z)까지 끝나지 않는다. Keeper 걷기가 window 를 기록해도 부팅하면 사라지고(D1-06), vision 은 다시 배우지 않는다. **열린 고리**다.
- 낭비: 거절당한 요청 본문이 하루 13.0 MB(p50 85 KB, 최대 218 KB)이고, vision 호출마다 왕복 한 번이 더 든다.
- 가장 작은 고침: 403 분기에서 Keeper 걷기와 같은 `Runtime_provider_usage_read.read_runtime_after_account_refusal rt` 를 부른다(`keeper_turn_driver.ml:2182` 와 같은 모양). 순서를 정할 때 provider 가 밝힌 `Until` window 는 맨 뒤로 보내지 말고 건너뛴다. 이 순서 함수는 `Runtime` 에 하나만 둔다.
- 확신: High(코드와 라이브 숫자가 맞는다). **tracked #38061**(2번 항목 "후보 순서 규칙 셋, vision 은 402 만 봄"). 이번 감사에서 라이브 숫자를 붙였다.

### A-02 · P2 · Ollama 세션 한도는 Retry-After 없는 429 로 온다. usage-read 를 선언했는데도 읽지 않아 같은 계정을 60초마다 다시 부른다 (D1-07 재검토)
- 위치: `keeper_turn_driver.ml:942-944`(429 는 `note_rate_limit` 만 함), `:970-982`(usage 읽기는 403 에서만), `keeper_runtime_failure_route.ml:424-439`(힌트 없는 429 의 쉼 = floor 60초, `env_config_keeper.ml:615`). 라이브 `[providers.ollama_cloud.usage-read]` 는 선언돼 있다(`runtime.toml:166`).
- 실패 시나리오: 10-06 "you have reached your session usage limit … (retry_after: none)" 가 이렇게 쌓였다. indie-geek-blue 실패 cycle 82번(00:15~12:39, 간격 p50 63초·p90 70초), you-never-change 78번, sangsu 39번, code-reviewer 32번. Librarian 의 `ollama-cloud-glm-5-3-flash` slot 은 429 254번이다. 모두 OLLAMA_CLOUD_API_KEY 하나를 쓴다. 그런데 429 기록은 runtime 후보 칸에만 남아서(`runtime_candidate_backpressure.ml:64-67`), 같은 계정을 쓰는 deepseek 와 glm-5-3-flash 가 서로의 거절을 모른다.
- 고리 분석: 단일 후보 Keeper 는 tick 마다 429 → 60초 대기 → 같은 계정 재호출이다. reset 될 때까지 bounded-but-blind 로 돈다. 다섯 소비자가 따로 배우므로 거절 횟수가 소비자 수만큼 곱해진다.
- 가장 작은 고침: Rate_limited 분기에서 `retry_after = None` 이고 provider 가 usage-read 를 선언했으면 `read_runtime_after_account_refusal` 를 그대로 부른다(이름은 `…after_refusal` 로 바꾼다). 문장은 분류하지 않는다. 429 는 읽기를 시작할 뿐이고, 판정은 typed usage report 가 한다. 이 report 는 계정 scope(`Credential_env`)에 쉼을 쓰므로, 두 runtime 이 같은 window 를 보게 된다.
- 확신: 코드 High. 효과(읽은 report 가 실제로 spent window 를 말해 줄지)는 Medium이다. 10-06 에 ollama.com usage read 가 DNS 실패로 6번 실패했다. **related #39190**. D1-07 은 "설계대로"로 닫혀 있다. 운영자가 다시 판단해야 한다.

### A-03 · P2 · Retry-After 없는 429 와 리셋 시각 없는 쿼터는 lane 맨 앞 후보를 시간 제한 없이 뒤로 민다 — 다시 생긴 sticky
- 위치: `runtime_candidate_backpressure_state.ml:44-50`(`observe` 는 `Some seconds` 일 때만 지운다), `keeper_turn_driver.ml:233-235`(`rate_limit = Some _` 이면 시각과 관계없이 `Told_to_rest`), `runtime_quota_window.ml` `Observed`(그 scope 가 성공해야만 지워진다). 같은 사실을 대기 계산(`keeper_turn_driver.ml:330-345`, noted_at + 60초)과 exact lane(`runtime_exact_lane_backpressure.ml:30-45`)은 시간으로 끝낸다. 시계가 두 개다.
- 고리 분석(lane [A, B], A 가 힌트 없는 429): tick 1 은 A 429 → 같은 턴에 B 가 답한다. tick 2..N 은 순서가 [B, A] 이고 B 가 답한다. A 는 불리지 않아서 표시가 영영 안 지워진다. 풀리는 길은 B 가 실패하거나 부팅하는 것뿐이다. 후보 칸은 runtime 에 붙어 있어 Keeper 를 가리지 않는다. 그래서 Keeper 하나의 429 가 default lane([glm-5.3-flash, muse, muse-contributor])을 쓰는 Keeper 14명을 함께 Muse 쪽으로 보낸다. 10-06 라이브에서는 default lane Keeper 의 dispatch 가 glm 383번, muse 35번이었다. 부팅 12번이 표시를 지워서 효과가 드러나지 않았다.
- 고침: 대기 계산과 같은 `path_rest_sec` 시각으로 demotion 을 끝낸다. 지난 뒤 tick 에서는 head 를 다시 부른다. RFC-0457 §6 의 "head 헛호출 1회/사이클" 비용과 같다.
- 확신: 코드 High, 라이브 영향 Low. **tracked #38471**.

### A-04 · P3 · `Candidate_fault.of_transport_error` 는 부르는 곳이 없고(테스트 포함 0건), 쓴다면 모든 HttpError 를 `Binding Server` 로 판정한다
- 위치: `packages/agent_core/lib/llm_provider/candidate_fault.ml:59-87`, `.mli:82`. 들어온 때: #38931(09-25) 무렵, RFC #38531 "한 판정으로 모든 걸음".
- 판정이 하나라는 RFC 는 Keeper route 에만 들어갔다. exact HTTP(`runtime_exact_lane_backpressure.ml:69-80`, Rate_limited 만 봄), CLI(`refused_for_binding_rest`), vision(402 만 봄), fusion(`fusion_official_client.ml:336-361`)은 각자 분류한다. N-of-M 이다.
- 고침: 죽은 export 를 지운다. 나머지 걷기는 `of_api_error` 결과를 같은 기록 함수에 넘긴다. tracked #38061.

### A-05 · P3 · 운영 설정 위생(코드 결함 아님)
- 선언 lane 14개 중 7개는 어느 배정도 가리키지 않는다(`fast-and-light`, `codex_subscription.codex-gpt-6-sol-xhigh`, `sol-high-then-glm`, `luna-*` 2개, `opus-high-then-codex`, `leader-opus-then-codex`).
- 이름과 후보가 다르다. `sol-low-then-glm` 은 [glm, kimi], `opus-high-then-codex` 는 [glm, kimi] 이다.
- default lane 의 두 Muse 후보는 같은 계정(`muse_d242bc1a`)이다. 이 계정이 소진되면 Keeper 14명이 갈 곳이 glm 하나만 남는다.

### 단일 후보 Keeper (라이브 `/runtime/resolved`, 29명 중 11명)
code-reviewer·indie-geek-blue·won-chik(ollama deepseek), e-masc-the-leader·pr-updater(claude_code_e8438773 sonnet), ocaml-refactor-woman·wkbl-web-leader(a9a8ad15 opus), wkbl-growth(a9a8ad15 sonnet), wkbl-data(a8c76d7a sonnet), sangsu·you-never-change(muse_d242bc1a).
Claude Code CLI slot 5개는 `sonnet-5-5-medium` lane 에 있지만, 그 lane 을 쓰는 Keeper 는 msx-retro-mania 하나다. 그 5개 계정을 쓰는 다른 Keeper 6명은 runtime id 를 직접 배정받아 failover 가 없다.
Librarian 의 CLI 꼬리(a9a8ad15 sonnet)는 Keeper 3명과 같은 계정이다.

### Standalone lane (질문에 대한 답)
7개 모두 `configuration_state=ready`, `admission_error=null` 이다. **설정 때문에 절대 돌 수 없는 lane 은 없다.**
돌아간 기록이 0건인 lane 은 셋이다.
- hitl_auto_judge: gate 가 always_allow 라서 불리지 않는다.
- browser_stagehand: run record 를 남기지 않는다.
- candle_appraiser: CLI 전용(a8c76d7a opus)이다. HTTP slot 이 없으면 `server_candle_appraiser.ml:309-330` 이 CLI 로 넘어가니 경로는 이어져 있다.
잠복 결함 하나가 남아 있다. workspace_curator 는 `cli_slots` 가 하나라도 있으면 lane 전체를 거절한다(`server_workspace_memory_curator.ml:157`, 09-29 RT-A2). 라이브에는 cli_slots 가 없어 지금은 문제가 없다.
verifier 의 라이브 run 기록은 129건 중 실패 58건, p50 900.2초다. 900초 stall 은 D6 영역이다.

### Sticky (질문에 대한 답)
`Runtime_lane_preference` 는 HEAD 에 없다(#36881). 후보마다 맨 앞 후보로 돌아오는 때는 이렇다.
- 힌트 있는 429: 힌트 시각 뒤 첫 tick 에 돌아온다(닫힘).
- provider 가 밝힌 `Until`: reset 뒤 첫 tick 에 돌아온다(닫힘).
- 힌트 없는 429 와 `Observed`: B 가 실패하거나 부팅할 때까지 돌아오지 않는다(열림, A-03).

### 문자열 분류 위치 (질문에 대한 답)
걷기 경로는 모두 typed 다. HTTP 는 상태 코드(`retry.ml:327-361`, 문장은 "never classified" `:286`), Claude Code 는 `terminal_reason` enum(`runtime_claude_code.ml:1194-1306`), Codex 는 `codexErrorInfo` 전수 match(`runtime_codex_app_server.ml:468-500`)로 분류한다.
남은 prefix/문자열 match 는 걷기에 영향이 없다.
- `keeper_terminal_reason.ml:66-189`: 저장된 receipt wire code 를 읽는 쪽.
- `keeper_internal_error.ml:381-382`
- `fusion_agent_core.ml:198-214`: 표시 문장의 prefix 를 바꾸는 쪽.
- `backend_ollama.ml:904`: 인라인 테스트.

## 5. Context·토큰 낭비 (실측)
- kimi vision 403: 10-06 하루 136번, 13.0 MB(A-01).
- Librarian CLI 의 quota_blocked 재호출: 10-05 하루 1,265번. 매번 Claude Code 프로세스가 뜨고 프롬프트를 보낸다. 바이트는 로그에 없어 못 셌다.
- verifier 의 kimi 재호출: 10-05 223번(L2-04).
- Ollama 세션 한도 429: 10-06 Keeper cycle 231번(indie-geek-blue 82, you-never-change 78, sangsu 39, code-reviewer 32), Librarian 254번. 요청 바이트는 로그에 없다.

## 6. 결합
- 걷기 본체가 `lib/keeper/keeper_turn_driver.ml`(3,216줄)에 있다. `lib/server/server_lane_addon_sampling.ml:42` 와 `keeper_next_request_forecast.ml:508` 이 `Keeper_turn_driver.assignment_walk_order` 를 부른다. server 가 keeper 의 turn driver 에 기대는 것이다. 순서 함수는 `Runtime` 으로 옮겨 떼어낼 수 있다.
- `lib/runtime/runtime_exact_lane_backpressure.ml:36` 과 `runtime_candidate_backpressure_state.ml:28` 이 `Keeper_runtime_failure_route`(`lib/keeper_runtime`)를 부른다. 아래층(runtime)이 위층에 기대는 방향이다. `path_rest_sec`·`usable_retry_after` 는 runtime 층에 두는 것이 맞다.
- 쉼 기록을 쓰는 곳이 다섯 군데다. Keeper turn driver, usage read, Muse usage, fusion official client, lane-addon sampling(`server_lane_addon_sampling.ml:63-64`). 읽는 순서 규칙은 세 벌이다(#38061). 기록 함수와 순서 함수를 하나씩만 두면 A-01·A-03·A-04 가 한 번에 닫힌다.
