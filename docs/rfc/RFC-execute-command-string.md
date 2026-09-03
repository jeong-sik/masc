---
rfc: "execute-command-string"
title: "Execute 는 명령 하나를 받는다 — typed 파이프라인 객체는 걷어내고, 도구 표면은 캐시 접두사로 다룬다"
status: Draft
created: 2026-09-02
updated: 2026-09-02
author: vincent
related: ["0091", "execute-subset-dispositions", "execute-boundary-is-the-sandbox", "tools-as-shell-commands", "skills-as-tools"]
---

# RFC: Execute 는 명령 하나를 받는다

## 0. Summary

`Execute` 의 모델 입력을 벤더가 2026년에 내는 셸 도구 모양으로 줄인다. 받는 것은
`argv`(프로세스 벡터) 또는 `script`(셸 한 줄) 중 하나와 `cwd`, `timeout_sec`, `shell`
뿐이다. 파이프·리다이렉트·순차·환경변수는 `script` 문법으로만 받고, 그것을 JSON 객체로
다시 쓰게 하던 `pipeline`, `then`, `stdin`, `stdout`, `stderr`, `env` 는 스키마에서
사라진다. 런타임은 `script` 를 `shell`(기본 `sh`) `-c` 한 호출로 내린다
(`keeper_tool_execute_typed_input.ml`, `script_to_shell`). 파서(`bash_subset.mly`)는 이 경로에
없다. 파서를 `script` 판정에 넣는 것은 08-31 RFC(Draft)의 일이고, 이 RFC 는 그 앞을 막지
않는다. 정책은 Gate·path jail·샌드박스가 진다. 스키마는 6.8 KB 에서 약 1.5 KB 로, 설명문은
1,362 B 에서 694 B 로 준다.

2장은 같은 눈으로 도구 표면 전체를 본다. 요청마다 62~69개, 90~113 KB 의 도구 정의가
나가고 그 안의 목록 두 개가 턴마다 바뀌어 캐시 접두사를 깬다. 벤더 지침은 요청당 도구
10~20개, 그 이상은 검색으로 미루라는 것이다.

근거 기록: `~/me/memory/procedural-memory/2026-09-02-tool-schema-vendor-support-evidence-record.md`.

## 1. Execute

### 1.1 지금

| 항목 | 값 | 근거 |
|---|---|---|
| 최상위 파라미터 | `argv`, `pipeline`, `then`, `env`, `cwd`, `timeout_sec`, `stdin`, `stdout`, `stderr`, `script`, `shell` (11개) | `config/tools/tool_execute.toml` |
| 스키마 크기 | 6,776 B, 중첩 7단, exec 단계 shape 이 top·pipeline·then·then.pipeline 에 네 번 | agent-core 스냅샷, `test_keeper_tool_schema_bytes` 주석 |
| 설명문 | 1,362 B. "typed stdin/stdout/stderr 객체로 리다이렉트하고 pipeline 필드로 파이프하라" 고 가르침 | TOML `description` |
| TOML | 515줄 중 312줄이 `pipeline`·`then` 파라미터 | 같은 파일 |
| OCaml | `keeper_tool_execute_typed_input.ml` 976줄, pipeline/then/redirect 언급 99곳 | rg |
| 두 형태의 합류 | `argv`/`pipeline`/`then` 도 `script` 도 같은 `Shell_ir.t` 로 내려간다 | `keeper_tool_execute_typed_input.ml:851-911`, 626 |

### 1.2 실측 (2026-09-01~02, Execute 866건)

| 입력 형태 | 건수 | 비율 | 실패 |
|---|---|---|---|
| `argv` (+ `cwd`/`timeout_sec`) | 684 | 79.0% | 전부 인프라(remote_ssh 불통, docker 이미지) |
| `script` (+ `cwd`/`shell`/`timeout_sec`) | 169 | 19.5% | 인프라 4, `cwd_not_directory` 2 |
| `pipeline`, `then`, typed `stdin` | 3 | 0.3% | 3건 중 2건이 `$.stdin must name exactly one of …` 스키마 오류 |
| `env`, `stdout`, `stderr` 객체 | 0 | 0 | — |

`script` 169건 안에서 모델이 쓴 문법: 파이프 149, 리다이렉트 134, `&&`/`||` 77, 제어문 16,
커맨드 치환 15. 즉 모델은 파이프와 리다이렉트를 셸 문법으로 쓴다. 같은 것을 JSON 으로
쓰라는 두 번째 문법은 안 쓰이고, 썼을 때는 틀린다. 그 두 번째 문법이 매 요청 모든 keeper 에게
약 5 KB 로 나간다.

### 1.3 이 스키마가 생긴 이유와 그 이유가 사라진 시점

- RFC-0091(2026-05, Implemented): `cmd` 문자열 하나를 받던 시절에 사후 lexer 가 메타문자를
  잡아 거부하는 것이 워크어라운드라서, 문자열을 없애고 typed `argv` 와 `Pipeline` IR 을
  모델에게 쓰게 했다.
- RFC-execute-subset-dispositions(08-24): 파서가 못 읽는 14가지를 한 답(거부)으로 접던 것을
  갈랐다. "파서를 버리고 OS 경계에서만 막자" 는 사람 없는 keeper 라서 기각했다.
- RFC-execute-boundary-is-the-sandbox(08-31, Draft): `script` 는 파서가 판정만 하고 원문이
  진짜 셸로 간다는 제안. 조사한 여섯 제품 중 masc 만 "파서 결과가 실행되는" 도구였다. 이
  RFC 는 "`argv` 와 `pipeline` 의 typed 경로는 유지" 라고 남겼다.

0091 이 typed IR 을 도입한 이유는 "문자열을 읽을 파서가 없어서" 였다. 오늘 `script` 는 파서를
지나지 않고 `shell -c` 한 호출로 내려간다(`script_to_shell`). 그런데 1.2 의 실측은 모델이 typed
IR 을 쓰지 않는다는 것이고, 정책 판정은 파서가 아니라 Gate·path jail·샌드박스가 진다. 남는
typed IR 의 존재 이유는 없다. 이 RFC 는 08-31 RFC 의 마지막 유보를 거둔다. `argv` 는 남긴다.
79% 가 쓰고, 셸을 거치지 않는 경로라 가장 안전하며, OpenAI `local_shell` 과 Codex
`prefix_rule` 이 같은 모양을 쓴다.

### 1.4 벤더가 내는 셸 도구 (2026-09-02 확인)

| 도구 | 입력 |
|---|---|
| Anthropic `bash_20250124` | `command` string, `restart` bool. 두 필드 |
| OpenAI Responses `shell` | `commands: string[]`(셸 문자열들), `timeout_ms`, `max_output_length` |
| OpenAI `local_shell` | argv 배열, `timeout_ms`, `working_directory`, `env` |
| Codex CLI `exec_command` | `cmd` string, `workdir`, `tty`, `yield_time_ms`, `max_output_tokens`, 권한 enum + `justification` + `prefix_rule`, `output_schema` 선언 |
| Claude Code `Bash` | 명령 문자열, `timeout`, `run_in_background`. 복합 명령 파싱은 런타임이 사후에 |

typed pipeline/redirect 를 모델 입력으로 노출하는 벤더 도구는 없다. 유일한 구조체 입력은
Codex 의 권한 승격 객체이고 명령 자체는 문자열이다. 샌드박스는 스키마 밖에서 강제한다.

### 1.5 설계

```toml
# config/tools/tool_execute.toml (v2)
[[params]] name = "argv"        # string[], 비어 있지 않음. 셸을 거치지 않는다
[[params]] name = "script"      # string. 셸 한 줄. shell -c 한 호출로 샌드박스의 진짜 셸이 실행
[[params]] name = "shell"       # "sh" | "bash" | "zsh" | "dash" | "ksh". script 에만. 기본 sh
[[params]] name = "cwd"         # string. 상대 경로, path jail 안
[[params]] name = "timeout_sec" # number, > 0. 없으면 600
# argv 와 script 중 정확히 하나
```

- 파이프·리다이렉트·`;`/`&&`/`||`·환경변수 선행 대입은 `script` 로만. `script` 는
  `Simple { bin = shell; args = ["-c"; text] }` 하나로 내려가고 샌드박스의 진짜 셸이 읽는다
  (`keeper_tool_execute_typed_input.ml`, `script_to_shell`). 파서 부분집합
  (`lib/exec/parser/bash.mli`)은 이 경로에 없다. 파서를 `script` 판정에 넣는 것은 08-31
  RFC(Draft)의 일이며, 이 RFC 는 그 앞을 막지 않는다.
- `stdin` literal 은 `printf '…' | cmd` 로. `env` 는 `FOO=1 cmd` 로.
- 설명문은 694 B. 무엇을 하는가(path jail·샌드박스·Gate 경계, 프로그램 의미는 해석하지
  않음), `argv` 와 `script` 중 언제 무엇을 쓰는가, `cwd` 는 상대 경로, 백그라운드 lifecycle
  없음, `masc` 도구는 `argv:["masc", …]` 한 건. `script` 안의 `masc …` 줄은 오늘 라우팅되지
  않으므로(rewrite 는 `Shell_ir.Simple.bin == "masc"` 만 본다,
  `keeper_shell_tool_command.ml`) `;`/`&&` 로 잇는 약속은 하지 않는다. Anthropic
  지침("3–4 sentences", "as you would describe your tool to a new hire")에 맞춘다.
- 출력 스키마(`execute_output_schema`: `ok`, `status.kind/code/signal`, …)는 그대로 둔다.
  Codex 가 `output_schema` 를 선언하는 것과 같은 방향이다.
- 런타임: `keeper_tool_execute_typed_input.ml` 에서 pipeline/then/redirect/env 디코딩과
  lowering 을 지운다(PR2·PR3). `Shell_ir` 과 샌드박스 레인 계약은 그대로다. 스키마 검증
  (`Tool_input_validation.validate_args`)이 `of_json` 보다 먼저 돌므로 PR1 만 병합돼도 모델이
  `pipeline` 을 보내면 `Tool 'Execute' received unsupported field(s): pipeline; accepted: argv,
  script, shell, cwd, timeout_sec` 로 거절된다(class `Policy_rejection`, #32343 의 렌더).
- `$defs`/`$ref` 는 쓰지 않는다. 중복이 사라지면 필요 자체가 없고, Gemini `parameters` 와
  llama.cpp 의 중첩 ref 문제를 피한다(근거 기록 4번째 항목). `Json_schema_shared_defs` 는
  소비자 0 이 되므로 PR1 에서 마지막 호출부(`tool_bridge.ml`)와 같이 지운다.

### 1.6 바뀌지 않는 것

- Gate, path jail, 샌드박스 프로필, 원격 레인 프로토콜, `Shell_ir`.
- `argv` 의 execve 의미. 메타문자는 데이터다.
- RFC-tools-as-shell-commands 의 `masc` 예약 명령. 오늘 구현된 경로는 `argv:["masc", …]`
  한 건뿐이고, `script` 안의 `masc …` 라우팅은 그 RFC 의 일이다. `;`/`&&` 로 잇던 유일한
  typed 경로 `then`(Sequence, 사용 0건)이 사라지므로 결합 표면은 `script` 하나가 된다.

## 2. 도구 표면

### 2.1 지금

| 항목 | 값 |
|---|---|
| 요청당 항상 싣는 도구 | 62~69개, 90~113 KB (deepseek, minimax, glm keeper 스냅샷) |
| 보류(`defer_loading = true`) | 30개. 배열에 0개. `keeper_tool_search` 설명에 이름만 1~2 KB(이름만 싣는 것은 #32484, 09-02 의 결정) |
| 빈도로 더 미룰 수 있는 것 | 이틀간 호출 2회 이하 4개, 2 KB |
| 큰 것 | Execute 11.4 KB, `keeper_surface_post` 4.3, `keeper_surface_read` 4.0, `keeper_skill` 4.0(설명에 스킬 identity JSON 목록), `Read` 3.2, `masc_board_list` 3.2 |
| 턴마다 바뀌는 설명문 | `keeper_skill` 의 Available 목록, `keeper_tool_search` 의 보류 이름 목록 |
| 시스템 프롬프트 | 8.1~9.6 KB, 그중 `<available_goals>` 5.2 KB(활성 goal 37개, 전 keeper 공통) |
| 요청당 입력 토큰 | minimax-m3 세션 479회 호출, 입력 2,610만 토큰(호출당 5.4만), 캐시 읽기 41%. deepseek 12%. ollama 백엔드는 cache_read 를 0 으로 파싱하므로(`backend_ollama.ml`) 이 수치의 출처는 PR4 계측에서 확정한다 |

### 2.2 벤더 지침

- OpenAI: 턴 시작 시 도구 20개 미만. Gemini: 활성 10~20개 최대. Anthropic: 10개 이상이거나
  정의가 10k 토큰 넘으면 tool search, 30~50개부터 선택 정확도 하락, 가장 자주 쓰는 3~5개만
  비보류.
- 캐시 접두사는 세 벤더 모두 tools → system → messages. 도구 하나의 이름·설명·순서가 바뀌면
  Anthropic 은 system 과 messages 까지 무효, OpenAI 는 "entire rendered prefix" 일치 요구.
  Anthropic 은 `defer_loading` 도구를 캐시 키 계산 전에 뺀다. MCP 2026-07-28 은 `tools/list`
  를 "deterministic order … improves LLM prompt cache hit rates" 로 명시.

### 2.3 설계

1. **동적 목록을 도구 설명에서 뺀다 — 잰 뒤에.** `keeper_skill` 의 Available 목록과
   `keeper_tool_search` 의 보류 이름 목록(이미 부른 도구는 빠지므로 턴마다 다르다,
   `keeper_identity_tool_search.ml` `description_of`)은 도구 접두사를 턴마다 깰 수 있다. 옮길
   자리로 적었던 `extra_system_context` 는 시스템 접두사가 아니라 대화 꼬리의 User 메시지다
   (`agent_turn.ml`). 히스토리에 남지 않고 post-tool 라운드에서 필터되므로
   (`prompt_block_id.ml`, `keeper_run_tools_hooks.ml`) 옮기면 그 라운드에서 목록이 사라지고
   `injected_on_post_tool_round=true` 비용을 붙여야 한다. 그래서 옮기기 전에 PR4 fingerprint 로
   "연속 턴 사이 tools 접두사가 실제로 바뀌는가" 를 24h 잰다. 스킬 목록은 RFC-skills-as-tools
   레인이라 그 RFC 의 표면으로 옮기는 것으로 적고 여기서는 자리만 비운다.
2. **보류 도구는 이름만 — 지금은.** 이름만 싣는 것은 #32484(09-02)의 결정이다. 한 줄 요약을
   같이 실었을 때 목록 57~86개에서 요청마다 6~9 KB, 도구 표면의 7~14% 였다는 측정이
   `keeper_identity_tool_search.ml` 의 주석에 있다. 되돌리지 않는다. 요약(≤120 B) 재도입은
   PR4 fingerprint 결과와 `Loaded_unused` 관측(`keeper_identity_tool_search.mli`
   `turn_discovery`)으로 PR6 에서 정한다.
3. **항상 싣는 집합을 turn 단위 손익으로 다시 고른다.** 빈도(호출 수)가 아니라 "그 도구를
   쓰는 턴의 비율" 로 본다. 한 턴에 여러 번 부르는 도구(`keeper_artifact_read` 470회)는
   턴 비율이 낮을 수 있다. 목표는 항상 싣는 집합 20개 안팎, 나머지는 2번의 검색으로.
4. **goal 목록은 시스템 프롬프트 밖.** 37개 5.2 KB 가 전 keeper 에게 같은 내용으로 가고,
   goal 이 하나 늘면 system 접두사가 통째로 바뀐다. system 의 `<available_goals>` 블록을
   지우고, 관측 레이어 `### Active Goals`(`keeper_unified_prompt.ml`)는
   `Workspace_goal_index.goals_for_task` 로 현재 task 에 링크된 goal 만 싣는다. task 없는
   keeper 는 프롬프트에서 goal 을 못 보고 `masc_goal_list` 로 본다. 대시보드 프리뷰는 같은
   함수라 함께 좁혀진다.
5. **순서 고정.** 도구 배열은 결정적 순서(카탈로그 순서의 `always_loaded` 뒤에
   `keeper_tool_search`)로 내고 그 순서를 핀한다. `tool_surface_sha256` 은 이름순 정렬
   해시라 순서를 못 보므로(`keeper_official_client_session_store.ml`), `Tool_schemas`
   fingerprint 를 순서대로 이어붙인 schema JSON 의 SHA256 으로 채우고
   (`keeper_agent_prompt_metrics.ml`) `check_projection` 은 집합 비교 대신 순서 보존·중복
   검출로 바꾼다(`keeper_run_tools_setup.ml`).
6. **`$defs` 는 하지 않는다.** Execute 축소 뒤 반복 shape 이 없고, provider 지원이
   갈린다(llama-server·ollama cloud·GLM). 1.5 의 결정과 같다.

## 3. 단계

| PR | 브랜치 | 내용 | 동작 변화 | 증명 |
|---|---|---|---|---|
| 1 | `execute-v2-schema` (main 기반) | TOML 파라미터 5개, 설명문 694 B, `check-execute-async-surface.sh` 문장 갱신, `subset_rewrite` 의 `Move_to_field Stdin` 조언 → `Unrepresentable`, `Json_schema_shared_defs` 삭제, 문서 3종 | `pipeline`/`then`/typed `stdin`/`env` 입력이 스키마 거절(이틀간 3건) | `test_execute_tool_toml_parity` 구조 핀(properties, oneOf required, 여섯 이름 부재, 설명문 ≤700 B), `test_keeper_tool_schema_bytes` 하락, `registry_integrity` 새 문장 핀 |
| 2 | `execute-typed-input-drops-then-and-env` (PR1 스택) | `typed_input` 에서 `then`/`conditional`/`env` 디코딩·lowering 삭제, 게스트 레인 typed env 거절과 remote_ssh GH 토큰 env 검사 삭제(도달 불가) | 없음(스키마가 이미 거절) | `test_keeper_tool_execute_typed_input`, `test_keeper_github_identity`, `test_keeper_tool_dispatch_runtime` |
| 3a | `execute-typed-input-argv-or-script` (PR2 스택) | 리다이렉트: `input_source`/`output_sink`/`redirect_namespace`/`Redirect_*` 와 runtime 의 Docker Bound_mount 사전 거절 삭제 | 없음 | `test_keeper_tool_execute_typed_input` 리다이렉트 20건 삭제 |
| 3b | 같은 브랜치 | 파이프라인: `program`/`parse_pipeline`, `Staged` → `Argv of string list`, `Execute_shell_ir.pipeline`, `tui_decode` 프리뷰 분기, docker_route typed e2e 8곳 삭제 | 없음 | `test_tui_decode`, `test_keeper_sandbox_docker_route`, `test_exec_dispatch*`, `test_exec_shell_command_gate` 불변 |
| 4 | `tool-array-order-and-fingerprint` (main 기반) | `Tool_schemas` fingerprint 를 순서 SHA256 으로, `check_projection` 순서 보존·중복 검출, 첫 요청 도구 순서 테스트 | 없음(계측) | `test_keeper_prompt_metrics`(같은 리스트 같은 값, 순서 바꾸면 다른 값), 새 순서 테스트 |
| 5 | `goals-out-of-system-prompt` (main 기반) | system 의 `<available_goals>` 삭제, 관측 레이어 Active Goals 를 현재 task 링크 goal 로 | 시스템 프롬프트 -5 KB | 골든 재생성, `test_keeper_system_prompt_bytes`, `test_keeper_goal_phase_projection` |
| 6 | `always-loaded-reselection` (D1 배포 24h 뒤, TOML·스크립트만) | `measure-tool-roundtrips.py` 도구별 턴 점유율 표, `defer_loading = true` 플립(데이터로 결정), 보류 목록 요약 재도입 여부 | 요청당 도구 수 | 스냅샷 도구 수·바이트, `keeper_tool_search` 호출 뒤 같은 턴 로드 도구 호출 비율, `Loaded_unused` 경고 수 |

각 PR 은 한 worktree, Draft, 적대 리뷰 병렬, CI `@check`, 병합 전 소유자 스위트 실행, PR 본문
한국어. 스택은 PR1 → PR2 → PR3 순으로만 병합한다. 바이트 리터럴 핀은 로컬 빌드 없이 재생성할
수 없으므로 구조 핀으로 바꾼다.

## 4. 측정

배포 경계마다 24h 창을 같은 시각대로 비교한다(`scripts/measure-tool-roundtrips.py` + 스냅샷).

| 지표 | 지금 | 목표 |
|---|---|---|
| Execute 스키마 바이트 | 6,776 | ≤ 1,600 |
| Execute 실패율(인프라 제외) | 09-02 재기동 전 7.3% 전체, 스키마 오류 3/866 | 스키마 오류 0, 전체 실패율 비상승 |
| 요청당 도구 바이트 | 90~113 KB | PR1 뒤 -4.5 KB, PR6 뒤 ≤ 40 KB |
| 캐시 읽기 비율(usage.total_cache_read / total_input) | minimax 41%, deepseek 12%(출처 미확정, 2.1) | PR4 계측으로 출처 확정 뒤 PR4·5 뒤 상승(캐시가 있는 provider 에서) |
| 연속 턴 사이 tools fingerprint 동일 비율 | 없음(PR4 가 만든다) | 24h 측정값이 PR6 과 2.3-1 의 입력 |
| 시스템 프롬프트 바이트 | 8.1~9.6 KB | PR5 뒤 ≤ 4.5 KB |
| Gate 재생 `pending.json` 의 pipeline/then/stdin 행 | D0 에서 확인 | 0건 |

## 5. 위험

- `pipeline`/`then` 을 아는 모델이 계속 보낸다: 이틀간 3건. 거절 문장이 `script` 를 가리키면
  된다. 24h 안에 1%/일을 넘으면 되돌린다(근거 기록의 롤백 조건).
- `script` 는 파서를 거치지 않고 `shell -c` 로 간다: 정책 판정은 Gate·path jail·샌드박스가
  하고, 파서를 `script` 판정에 넣는 08-31 RFC(Draft)와 부분집합을 넓히는 RFC-shell-ir-* 은
  그대로 진행한다. 이 RFC 는 그 앞을 막지 않는다.
- typed 경로에만 있던 거절 두 층이 사라진다: 게스트 레인 typed `env` 거절과 remote_ssh 의 GH
  토큰 env 검사(`keeper_tool_execute_runtime.ml`), Docker Bound_mount 리다이렉트의 호스트 측
  사전 거절. 둘 다 `script` 텍스트로는 오늘도 우회되는 층이라 08-31 RFC 입장과 같다. PR2·PR3
  본문에 별도 항목으로 적는다.
- Gate 재생(`keeper_gate_replay.ml`)은 저장된 input 을 스키마 검증 없이 넣는다. 배포 경계에서
  `<base-path>/.masc/gate/pending.json` 에 pipeline/then/stdin 행이 0건임을 확인한다(운영
  절차). PR3 뒤 그런 행이 남아 있으면 `of_json` 의 typed 거절로 끝나며 조용히 실행되지 않는다.
- 골든·바이트 핀 다수 갱신: 테스트 파일 85개가 `tool_execute` 를 언급한다. CI 는
  `dune build @check` 뿐이라 테스트는 병합 전 소유자가 PR 마다 적힌 스위트를 돌린다.

## 6. 다른 RFC 와의 관계

- RFC-0091: `argv` 는 유지, JSON `Pipeline` IR 노출은 철회. 0091 §1 의 문제(사후 lexer)는
  파서로 해결된 상태다.
- RFC-execute-subset-dispositions: 불변. 파서가 못 읽는 것의 처분은 그대로.
- RFC-execute-boundary-is-the-sandbox: 확장. "`pipeline` 의 typed 경로 유지" 유보를 거둔다.
  PR1 이 그 RFC 의 §0 한 줄을 갱신한다.
- RFC-tools-as-shell-commands: 불변, 강화.
- RFC-skills-as-tools: 2.3-1 의 스킬 목록 이동은 그 RFC 의 표면으로 넘긴다.

## 8. 결과 (2026-09-03)

여섯 PR 이 전부 병합됐다. #32650(PR1), #32657(PR2), #32662(PR3), #32666(PR4), #32665(PR5),
#32711(PR6). 배포는 두 번이다. 09-02 00:27 KST 가 PR1~PR5 를, 09-03 11:10 KST 가 PR6 과
#32718(ask 계열 지연)을 함께 실었다.

### 4장 목표표의 실측

| 지표 | 목표 | 실측 | |
|---|---|---|---|
| Execute 스키마 바이트 | ≤ 1,600 | 도구 객체 11,386 → 5,212, 표면 계기로는 3,095 | 미달 |
| Execute 스키마 오류 | 0 | 0 (배포 뒤 1,414건 중 없어진 여섯 이름은 0건) | 달성 |
| Execute 실패율 | 비상승 | 33.9% → 7.3% (감소분은 대부분 remote_ssh·docker 인프라 회복) | 달성 |
| `unsupported field(s)` | ≤ 1%/일 | 0.051%, Execute 몫 0건 | 달성 |
| 요청당 도구 바이트 | PR6 뒤 ≤ 40 KB | polisher 53,869 · pr-updater 53,434 · sangsu 54,070 · rondo 80,411 | 미달 |
| 연속 턴 fingerprint 동일 | 24h 측정 | 지문을 내는 keeper 전부 연속 턴 동일 | 달성 |
| 시스템 프롬프트 바이트 | PR5 뒤 ≤ 4.5 KB | 배포 경계에서 keeper 다섯 모두 정확히 -5,230 B | 달성 |
| `pending.json` 의 pipeline/then/stdin | 0건 | 0건 (대기 2행, 둘 다 argv+cwd) | 달성 |
| 캐시 읽기 비율 | PR4·5 뒤 상승 | antigravity 63.4→83.2%, claude_code 57.8→70.6%, glm 76.5→79.7% | 표본 부족 |

캐시 읽기 행은 판정하지 않는다. 재기동 직후 9~13턴짜리 표본이고, ollama 백엔드는
`cache_read` 를 0 으로 파싱해서(`backend_ollama.ml`) 이 fleet 의 가장 큰 레인이 아예
안 잡힌다. 2.1 의 "minimax 41%, deepseek 12%" 출처 미확정 표기는 그대로 둔다.

### 계획이 틀렸던 곳

**요청당 도구 ≤ 40 KB 는 처음부터 도달할 수 없는 목표였다.** 지연된 도구는 이번 대화에서
한 번이라도 불리면 `already_used` 가 다음 턴 요청에 스키마째 다시 싣는다
(`keeper_tools_agent_core_bundle.ml`). 이건 결함이 아니라 왕복을 한 번으로 끝내려는 설계다.
그래서 실현되는 절감은 "그 대화에서 아직 안 쓴 지연 도구" 만큼이고, 도구 총량이 아니다.

배포 뒤 polisher 의 도구 배열을 열어보면 69개 → 50개다. PR6 이 미룬 19개 중 **15개가 빠졌고
4개**(`masc_agent_fitness`, `masc_board_stats`, `keeper_memory_retract`, `masc_run_init`)**는
그대로 남아 있다.** 넷 다 그 대화에서 이미 쓰인 것들이다. 같은 이유로 부착된 github 도구
다섯이 빠지고 하나가 새로 들어왔다.

3장의 "요청당 도구 수" 를 목표로 삼은 문장들은 이 상한을 몰랐다. 도구 표면을 줄이는 지렛대는
지연 선언이 아니라 **도구 개수 자체**이거나, `already_used` 의 유지 범위를 대화가 아니라
턴으로 좁히는 쪽이다. 후자는 왕복을 되살리는 거래라서 따로 재봐야 한다.

**Execute 스키마 ≤ 1,600 도 미달이다.** 다섯 파라미터와 694 B 설명문으로 줄인 결과가 도구
객체 5,212 B 다. 남은 무게는 파라미터 설명문이며, 더 줄이려면 설명을 깎아야 하는데 그건
모델이 argv 와 script 를 가르는 근거라 이 RFC 의 범위 밖이다.

### 남은 관찰

- 09-03 09:28 에 rondo 가 `argv` 첫 칸에 `"ls && -la"` 를 두 번 넣었다. 셸 연산자를 argv
  토큰에 쓴 것으로 설명문이 `script` 로 가라고 적어둔 자리다. 1,414건 중 2건, 한 keeper 의
  한 턴이라 입구 검사를 붙이지 않았다. 다른 keeper 에서도 나오면 다시 본다.
- `/api/v1/dashboard/tools` 는 재기동 뒤에도 `warming`, 도구 0개다(#29980). 이 측정은 turn
  record 의 `tool_surface_ref` blob 을 직접 읽어 우회했다.

### PR6 배포 뒤 관찰 (재기동 11:10 KST, 이후 308턴)

목록 뒤로 미룬 도구를 모델이 실제로 찾아 쓰는지가 남은 질문이었다.

| 관찰 | 값 |
|---|---|
| 도구를 부른 턴 | 308 |
| `keeper_tool_search` 를 부른 턴 | 1 |
| 그 턴이 불러온 도구를 같은 턴에 쓴 비율 | 1/1 |
| 표면에 없다고 거절된 호출 | 0 |
| 미룬 19개 중 호출된 것 | `masc_board_vote` 2, `keeper_memory_retract` 1 |

한 건뿐이지만 고리는 온전하다. rondo 가 `keeper_tool_search {names: [masc_ask, masc_ask_status]}` 를 부르고 같은 턴에 `masc_ask_status` 를 실행했다. 목록 → 조회 → 호출이 왕복 한 번에 끝난다.

미룬 도구가 `keeper_tool_search` 없이 호출된 세 건은 결함이 아니다. `already_used` 가 대화의 보이는 히스토리에서 ToolUse 블록을 읽어 스키마를 다시 싣는데, 그 히스토리는 재기동을 넘어 살아남는다. 그래서 절감은 재기동 직후에도 완전히 회복되지 않는다 — 위 §8 이 말한 상한이 프로세스 수명보다 대화 수명에 묶여 있다는 뜻이다.

`keeper_tool_search` 호출이 308턴에 한 번뿐인 것은 설계대로다. 미룬 19개는 드물게 쓰이도록 골랐고, 한 번 쓰이면 그 대화에서 다시 묻지 않는다.
