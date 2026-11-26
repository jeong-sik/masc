---
rfc: "official-clients-share-one-type-and-the-host-runs-their-turn"
title: "공식 클라이언트는 type 하나로 부르고, 턴의 순서는 host 가 밟는다"
status: Draft
created: 2026-11-20
updated: 2026-11-26
author: claude
supersedes: []
superseded_by: null
related: ["a-persons-keeper-runs-on-the-engine", "retained-results-carrier-shrinks-to-an-address", "keeper-turn-ends-while-waiting-for-a-receipt-state-machine"]
---

# 공식 클라이언트는 type 하나로 부르고, 턴의 순서는 host 가 밟는다

- 이슈: #53656 (판정 댓글: https://github.com/jeong-sik/masc/issues/53656#issuecomment-7027856576)
- §1 의 사실은 main `a26795cff182c` 의 코드에서 읽었다. §1.1 의 fix 기록은 2026-11-20 에 git 기록에서 셌다.
- 공식 클라이언트는 Codex, Claude Code, Antigravity, ACP 넷이다.
- ACP 는 driver 로 Muse Code, Mistral Vibe, Kimi Code, Antigravity 를 띄운다(`Runtime_acp_client.driver`). 그래서 Antigravity 는 CLI 클라이언트로도, ACP driver 로도 뜬다.
- **정한 데까지**: 목표 모양(§2), 묶음 순서와 확인 방법(§3), 지킬 것(§4). 방식 여덟은 열린 결정이다(§5).

## 0. 요약

**어댑터 넷이 같은 턴 순서를 각자 밟는다. 그 순서를 host 가 한 번 밟고, 어댑터는 클라이언트마다 다른 점만 준다. 클라이언트 이름은 type 하나로 부른다.**

- 지금 host 는 도구 상자다. 어댑터가 host 의 함수를 자기 순서로 부른다.
- 그래서 session claim, prompt 조립, 끝맺음이 네 번 있다. 그 순서에 생긴 결함은 네 번 고친다.
- 2026-10-21~11-20 의 fix 74건 가운데 25건이 이 탓이었다(§1.1). 37건은 클라이언트마다 다른 wire 동작이라 합쳐도 남는다.
- 클라이언트 이름만 담은 열거가 다섯 개, 철자가 세 벌이다(§1.4).

## 1. 지금 동작

### 1.1 fix 기록

2026-10-21~11-20 에 어댑터와 host 파일을 고친 커밋은 117건이고, 그중 fix 는 74건이었다.

| 갈래 | 건수 | 예 |
|---|---|---|
| 같은 결함을 한 커밋에서 어댑터 2~5곳에 손으로 고쳤다 | 19 | #45563 ordinal, #45614 완료 증거, #52856 spawn 거절, #52945 세션 거절 |
| 같은 결함을 어댑터마다 다른 PR 로 고쳤거나, 한 곳만 빠졌다가 따라잡았다 | 6 | #47132·#47146·#47154·#47228(같은 stack 에서 어댑터마다 PR 하나), #48005, #52137 |
| host 한 곳만 고쳤다 | 12 | #49680, #46154 |
| 그 클라이언트의 wire·CLI 동작이다 | 37 | #47921 Codex `account/read`, #48773 Antigravity print mode |

- #46936 과 #46942 는 한 결함을 두 PR 로 나눠 고쳤다. 준비 지침이 실패하면 체크포인트와 원래 입력을 잃는 결함이다.
- 넷째 줄은 이 RFC 로 줄지 않는다. 이 RFC 가 줄이는 것은 첫째·둘째 줄이다.

### 1.2 어댑터 넷이 같은 순서를 밟는다

host 의 모듈 주석은 어댑터가 도구 기록을 wire 로 옮기기만 한다고 적는다(`Keeper_official_client_host`). 실제로는 어댑터마다 `run_without_lifecycle` 하나가 턴 전체를 밟는다.

| 단계 | Codex | Claude Code | Antigravity | ACP |
|---|---|---|---|---|
| Eio env·clock 확인(`Eio_context.get_env_opt`) | 있음 | 있음 | 있음 | 있음 |
| 도구 receipt hook(`Keeper_official_client_tool_receipts.create`) | 있음 | 있음 | 있음 | 있음 |
| `load_reconciled_for_runtime → plan_claim` | 있음 | 있음 | 있음 | 있음 |
| `resolve_native_posture` | 있음 | 있음 | 있음 | 있음 |
| `validate_continuation → reconcile_tool_surface` | 있음 | 있음 | 있음 | 있음 |
| 저장한 context 가 바뀌면 새 세션(`reconcile_context`) | — | — | 있음 | 있음 |
| 쥔 context 읽기(`held_context_for_resume`) | 있음 | 있음 | 있음 | 있음 |
| `claim_with_context_frontier → mark_turn_starting → mark_turn_started` | 있음 | 있음 | 있음 | 있음 |
| `settle`·`settle_holding` / `require_recovery` / `release_transient` | 있음 | 있음 | 있음 | 있음 |

- 시도 하나의 결과와 효과 기록 칸은 하나다(`Keeper_official_client_attempt`, #53701). 어댑터 넷이 같은 `outcome` 을 돌려주고 같은 `Effect_cell` 에 적는다.
- 어떤 사건을 효과로 읽을지는 어댑터가 정한다. 읽은 값을 합치는 규칙은 `Effect_cell` 이 정한다.
- MASC 도구에 들어가는 길은 넷 다 `Keeper_official_client_attempt.fence_effect_capable_call` 을 지난다.
- 시도마다 switch 와 lifecycle event 는 `Keeper_official_client_attempt.run` 이 연다.
- Codex 만 `outcome` 에 `successful_tool_completion` 을 붙인 `attempt_outcome` 을 돌려준다.
- 크기 거절 뒤 씨앗을 줄이는 규칙은 넷이 같이 쓴다(`Keeper_turn_driver_try_provider.context_overflow_shrink_sequence`). 줄이는 폭과 재시도 허락은 어댑터가 준다.
- 크기: 어댑터 Codex 2517줄, Claude Code 2179줄, Antigravity 2073줄, ACP 3949줄이다. host 는 2624줄(`.mli` 1015줄)이다.

### 1.3 turn driver 갈래 넷

- turn driver 는 클라이언트마다 갈래 하나를 둔다. 갈래마다 그 어댑터의 `run` 을 부른다(`Keeper_codex_runtime.run`, `Keeper_claude_code_runtime.run`, `Keeper_antigravity_runtime.run`, `Keeper_acp_runtime.run`).
- 갈래마다 같은 일을 한다. 계정 판정, `run` 호출, `apply_official_client_accept`, `settle_accepted_official_client_results`, `observe_official_result`, `selected_runtime_result`, `official_client_dispatch` 다.
- 계정 판정은 둘로 갈린다. Codex·Claude Code 는 `authorize_account` 를, Antigravity·ACP 는 `authorize_host_account` 를 부른다.
- Codex 갈래만 `successful_tool_completion` 을 읽고 빈 글 완료를 받아들인다.

### 1.4 클라이언트 이름

클라이언트 이름만 담은 열거가 다섯이다. 생성자는 둘에서 여섯까지 서로 다르다.

| type | 생성자 |
|---|---|
| `Keeper_semantic_execution.official_client_kind`. `Keeper_official_client_session_store.client_kind` 는 이것을 다시 내보낸다 | `Codex` `Claude_code` `Antigravity` `Acp` |
| `Runtime_account_declaration.client` | `Claude_code` `Codex` `Antigravity` |
| `Runtime_account_home_layout.client` | `Codex_home` `Claude_home` |
| `Runtime_official_cli_install.client` | `Codex` `Claude` `Antigravity` `Mistral_vibe` `Kimi_code` `Muse_code` |
| `Runtime_setup_login_client.client` | `Codex` `Claude` `Antigravity` `Mistral_vibe` `Kimi_code` `Antigravity_acp` |

- 철자는 세 벌이다.
  - runtime TOML protocol: `codex-app-server` `claude-code` `antigravity-cli` `acp`(`Runtime_protocol`)
  - 저장 철자: `codex` `claude_code` `antigravity` `acp`(`Keeper_semantic_execution`)
  - 실행 파일 이름: `codex` `claude` `agy` `vibe-acp` `kimi` `muse`(`Runtime_official_cli_install`)
- 공식 클라이언트를 더 큰 합이나 부분 집합으로 다시 적은 type 이 여덟이다. `Runtime_execution.t`, `Runtime_schema.api_format`, `Runtime_setup_spec.choice`, `Sandbox_prerequisites.dependency`, `Keeper_exact_walk_failure.native_family`, `Fusion_official_client.failure`, `Model_catalog.suggested_client`, `bin/main_eio.ml` 의 `wizard_model_client` 다.
- 서로 옮기는 함수를 손으로 쓴다. `Server_runtime_setup_actions` 와 `bin/main_eio.ml` 이 `Runtime_setup_login_client` 의 값을 `Runtime_official_cli_install.client` 로 옮기는 `match` 를 따로 둔다.
- protocol 글자(`"claude-code"` 등)는 `lib`·`bin` 의 OCaml 파일 열세 곳에 따로 있다(§3 S2 의 `rg`).
- `Server_runtime_setup_actions.import_account` 는 JSON 글자 `"antigravity-cli"` 를 비교해 흐름을 정한다.

### 1.5 Fusion

`Fusion_official_client` 는 panel 질문 하나를 클라이언트 넷에 보낸다. session store 를 쓰지 않는 한 번짜리 호출이라 Keeper 턴과 순서가 다르다. 다만 usage 를 옮기는 함수 넷(`claude_usage`, `codex_usage`, `antigravity_usage`, `acp_usage`)이 어댑터의 `api_usage_of_*` 와 같은 wire 값을 따로 옮긴다.

## 2. 목표 모양

### 2.1 클라이언트 type 하나

- 맨 아래 library 에 `Official_client.t` 를 둔다. 생성자는 Codex, Claude Code, Antigravity, ACP 다. ACP 생성자는 driver 를 담는다.
- `[@@deriving enumerate]` 로 `all` 을 만든다.
- 바깥 글자마다 codec 은 이 모듈에 하나만 둔다. 바깥 글자는 runtime TOML protocol 과 저장 철자다. 실행 파일 이름은 vendor 가 정한 argv 라 install 모듈에 둔다.
- §1.4 의 열거 다섯을 지운다. 클라이언트별 사실(설치 URL, 계정 home 위치 등)은 그 사실을 가진 모듈이 `Official_client.t` 위의 전체 함수로 둔다.
- 더 큰 합은 공식 클라이언트 자리를 생성자 하나로 묶는다. 예: `Http of http_format | Official of Official_client.t`. payload 가 클라이언트마다 다른 `Runtime_execution.t` 는 D3 이 정한다.
- 일부만 받는 부분 집합(`suggested_client`, 계정 home 이 있는 둘)은 D4 가 정한다.

### 2.2 host 가 턴 순서를 밟는다

| 단계 | 지금 | 목표 |
|---|---|---|
| Eio 확인, receipt hook | 어댑터 넷 | host |
| session claim 과 continuation·tool surface 확인 | 어댑터 넷 | host |
| native posture | 어댑터가 host 함수를 부른다 | host 가 부른다. 기본값과 none 지원은 어댑터가 준다 |
| 계정 판정 | turn driver 갈래마다 부른다. 판정 함수는 둘이다 | 어댑터가 `account` type 과 판정을 준다. host 가 부른다 |
| 계정 home·작업 폴더 준비 | 어댑터 | 어댑터 |
| 준비 지침(`on_guidance_prepared`)을 부르는 때 | 어댑터마다 부른다 | host 가 한 자리에서 부른다 |
| `prepare_turn`, Start·Resume prompt 모양 | 어댑터가 host 함수를 조합한다 | host |
| context 가 바뀔 때 | Antigravity·ACP 는 새 세션으로 간다. Codex·Claude Code 는 쥔 context 로 이어 간다 | 어댑터는 종류만 선언한다. host 가 그 종류대로 한다 |
| task reference | Codex·Claude Code 는 메시지로 넣고, Antigravity·ACP 는 거절한다 | 어댑터가 지원 여부를 선언한다. host 가 거절한다 |
| 프로세스 띄우기, wire stream 읽기 | 어댑터 | 어댑터 |
| stream 을 MASC 사건으로 옮기기 | 어댑터 | 어댑터가 typed 사건을 넘긴다 |
| 어떤 사건이 어떤 효과 단계인지 | 어댑터 | D5 |
| client error → core error, recovery failure | 어댑터 | 어댑터. 전체 함수다 |
| settle, recovery, release, host stop result | 어댑터 넷 | host |
| usage → `api_usage` | 어댑터 넷과 Fusion 넷 | wire 모듈이 한 번 |

- host 는 단계마다 모듈로 나눈다(claim, prompt, 끝맺음). 지금 host 한 파일에 순서를 더하면 파일이 커진다.
- 어댑터가 주는 것을 담는 방식은 D6 이 정한다.

### 2.3 turn driver 갈래 하나

- `Codex_app_server _ | Claude_code _ | Antigravity_cli _ | Acp _` 는 갈래 하나로 host 의 `run` 을 부른다.
- 갈래 안의 계정 판정은 어댑터가 준 판정을 부른다.
- `successful_tool_completion` 을 어떻게 둘지는 D7 이 정한다.

## 3. 묶음

작업은 gh stack 으로 쌓는다(constitution `execution_protocol` `work_unit`). 한 단계는 어댑터 넷을 한 번에 옮긴다. 어댑터 하나만 옮긴 상태로 병합하지 않는다. 그 상태가 곧 일부만 고친 fix 다.

| # | 묶음 | 확인 |
|---|---|---|
| S1 | `Official_client.t` 와 codec. §1.4 의 열거 다섯을 지운다 | `rg -n '^type (official_client_kind\|client_kind)\b' lib` 가 비었다. §1.4 의 `client` 네 모듈에 `type client` 가 없다. codec 은 `Official_client.all` 전부에서 왕복한다. CI type-check |
| S2 | protocol 글자를 쓰는 곳이 codec 을 읽는다. `Server_runtime_setup_actions.import_account` 의 글자 비교를 지운다 | `rg -l '"codex-app-server"\|"claude-code"\|"antigravity-cli"' lib bin --type ocaml` 에 codec 파일과 `antigravity-cli` 폴더 이름을 쓰는 파일(`runtime_antigravity_home.ml`, `runtime_antigravity_policy.ml`, `runtime_acp_client.ml`)만 남는다 |
| S4a | session claim 을 host 함수 하나로 옮긴다. 결과는 typed `claimed_session` 이다 | `rg -n 'load_reconciled_for_runtime\|plan_claim' lib/keeper/keeper_{codex,claude_code,antigravity,acp}_runtime.ml` 이 비었다. 가짜 클라이언트로 continuation 불일치가 dispatch 전에 거절되는지 본다 |
| S4b | Start·Resume prompt 와 context 종류를 host 로 옮긴다 | 어댑터에 `start_prompt`·`resume_prompt`·`framed_prompt_for_turn`·`reconcile_context` 호출이 없다. 보낸 prompt 를 가짜 클라이언트가 받은 그대로 비교한다 |
| S4c | 끝맺음(settle, recovery, release, host stop)을 host 로 옮긴다 | 어댑터에 `Session_store.settle` 계열 호출이 없다. 실패 종류마다 저장한 session 상태를 본다 |
| S4d | 어댑터가 주는 것을 D6 의 모양으로 묶는다. 어댑터의 `run_without_lifecycle` 을 지운다 | 어댑터 파일에 `run_without_lifecycle` 이 없다 |
| S5 | turn driver 갈래를 하나로 합친다 | `rg -n 'Keeper_(antigravity\|claude_code\|codex\|acp)_runtime\.run' lib` 이 비었다 |
| S6 | usage 변환을 wire 모듈 하나로 모은다. Fusion 과 어댑터의 사본을 지운다 | `fusion_official_client.ml` 에 `*_usage` 함수가 없다 |

- S4a~S4c 동안 어댑터의 공개 `run` 모양은 그대로 둔다. 어댑터 시험이 `run` 을 부르므로 그 시험이 옮긴 순서를 확인한다.
- S4d 끝에서 어댑터 넷과 host 의 줄 수를 다시 잰다. 지금 값은 §1.2 에 있다.
- 가짜 클라이언트 시험은 보낸 요청, 저장한 session 상태, 결정만 본다(constitution `build_and_ci`).

provider 종류 표는 이 RFC 밖이다. `Runtime_setup_spec.http_kind` 와 discovery `protocol`(`Runtime_model_discovery`)은 `Provider_kind.t` 에서 전체 함수로 옮겨 오므로 그대로 둔다.

## 4. 지킬 것

- S1~S4c 는 동작을 바꾸지 않는다. 바꾸는 것은 D2 의 저장 철자뿐이고, 그때는 changelog 에 `Fresh state required` 를 적는다.
- 호환 reader, 옛 철자 별칭, 옮기는 코드를 만들지 않는다.
- wire 모듈(`lib/runtime/runtime_{codex_app_server,claude_code,antigravity,acp_client}.ml`)의 vendor 프로토콜은 바꾸지 않는다.
- 클라이언트 열거를 `_ ->` 로 받지 않는다. 새 클라이언트를 더하면 컴파일러가 빠진 자리를 잡아야 한다.
- 어댑터가 주는 것은 클라이언트마다 다른 사실뿐이다. 둘 이상이 같은 값을 주면 host 로 올린다.

## 5. 열린 결정

| # | 정할 것 | 후보 | 먼저 읽을 것 |
|---|---|---|---|
| D1 | `Official_client.t` 가 사는 library | 새 leaf library, 또는 `masc.masc_types` | `masc_runtime` 과 `masc_keeper_chat_operations` 는 서로 의존하지 않는다(`lib/runtime/dune`, `lib/keeper_chat_operations/dune`). 둘과 `bin` 이 모두 닿아야 한다. ACP 생성자가 담을 `Runtime_acp_client.driver` 는 지금 `masc_runtime` 에 있다 |
| D2 | 저장 철자 | 저장 철자를 protocol 글자(`claude-code`)로 합친다(Fresh state), 또는 철자 둘을 codec 모듈 안에 둔다 | session store 와 semantic execution 기록을 읽는 곳 전부 |
| D3 | `Runtime_execution.t` 가 클라이언트별 설정을 담는 법 | 생성자 넷을 둔다, 또는 `Official of` 와 클라이언트로 색인한 GADT 를 쓴다 | `Runtime_execution` 을 match 하는 곳 전부, 다계정 판정(`Runtime_account_access`, #53668) |
| D4 | 부분 집합 | 그 집합만 받는 함수가 있으면 닫힌 부분 type 과 `to_official` 하나를 둔다. 사본이면 지운다 | `Runtime_account_home_layout.client`, `Model_catalog.suggested_client`, `Runtime_account_access.host_client` 를 쓰는 곳 |
| D5 | 효과 단계를 정하는 표 | host 가 칸과 합치기만 하고 사건의 뜻은 어댑터가 정한다, 또는 (posture, 사건) 표 하나를 host 가 쥔다 | Codex `observe_failed_dispatch`, Claude Code `recording_effect_attempt`·`observe_stream_effect`, ACP·Antigravity 가 `Native_full` 에서 부르는 `observe_effect_unavailable` |
| D6 | 어댑터가 주는 것을 담는 방식 | `module type CLIENT` 와 functor, 함수 record, first-class module | 넷의 dispatch loop 와 stream projection. 클라이언트마다 error·usage·account type 이 다르다 |
| D7 | `successful_tool_completion` | Codex 만 둔다, 또는 host 가 도구 결과를 보고 넷 모두에 둔다 | turn driver 의 Codex 갈래가 `successful_tool_completion` 을 읽는 자리. 넷 모두에 두면 셋의 도구만 있는 완료를 받는 동작이 바뀐다 |
| D8 | Fusion | usage 변환만 합친다, 또는 panel 호출도 host 를 거친다 | `Fusion_official_client.run_with_images` |

D6 의 추천은 functor 다. error·usage·account type 이 클라이언트마다 다르고, functor 는 그 type 을 감싸지 않고 정적으로 둔다. 함수 record 는 클라이언트별 error 를 감싸는 existential 이 필요하다. 넷의 dispatch loop 를 다 읽기 전이라 결정은 S4d 직전에 한다.

## 6. 겹치는 일

- `RFC-a-persons-keeper-runs-on-the-engine`(#53446·#53675 병합)은 다계정에서 Codex 턴을 시작 전에 거절한다고 적는다(§2 「하지 않는 것」). 클라이언트별 거절은 D6 에서 어댑터가 주는 사실이 된다.
- 다계정 판정은 `Runtime_account_access` 에 있다. turn driver 갈래가 `authorize_account`·`authorize_host_account` 로 그 판정을 부른다. S5 는 이 부르는 자리를 하나로 합친다.
- `RFC-retained-results-carrier-shrinks-to-an-address` 는 Claude Code 와 Codex 어댑터의 줄 번호를 인용한다. S4b 가 그 코드를 host 로 옮기므로, 그 RFC 를 구현할 때는 옮긴 자리를 읽는다.

## 기록

- 2026-11-20: 처음 씀. 이슈 #53656 판정(일부 진짜) 뒤.
