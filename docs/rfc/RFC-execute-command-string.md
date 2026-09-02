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
사라진다. 런타임은 지금처럼 문자열을 파서(`bash_subset.mly`)로 읽어 정책을 판정하고
샌드박스가 봉쇄한다. 스키마는 6.8 KB 에서 약 1.5 KB 로, 설명문은 1,362 B 에서 약 600 B 로
준다.

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
- RFC-execute-boundary-is-the-sandbox(08-31): `script` 는 파서가 판정만 하고 원문이 진짜
  셸로 간다. 조사한 여섯 제품 중 masc 만 "파서 결과가 실행되는" 도구였다. 이 RFC 는
  "`argv` 와 `pipeline` 의 typed 경로는 유지" 라고 남겼다.

0091 이 typed IR 을 도입한 이유는 "문자열을 읽을 파서가 없어서" 였다. 08-31 시점에 파서가
있고 `script` 가 그 파서를 지난다. 그러면 남는 typed IR 의 존재 이유는 없다. 이 RFC 는 08-31
RFC 의 마지막 유보를 거둔다. `argv` 는 남긴다. 79% 가 쓰고, 셸을 거치지 않는 경로라 가장
안전하며, OpenAI `local_shell` 과 Codex `prefix_rule` 이 같은 모양을 쓴다.

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
[[params]] name = "script"      # string. 셸 한 줄. 파서가 판정, 샌드박스의 진짜 셸이 실행
[[params]] name = "shell"       # "sh" | "bash". script 에만. 기본 sh
[[params]] name = "cwd"         # string. 상대 경로, path jail 안
[[params]] name = "timeout_sec" # integer
# argv 와 script 중 정확히 하나
```

- 파이프·리다이렉트·`;`/`&&`/`||`·환경변수 선행 대입은 `script` 로만. 파서 부분집합이
  이미 받는다(`lib/exec/parser/bash.mli`). heredoc·커맨드 치환·제어문은 부분집합 밖이지만
  08-31 RFC 대로 진짜 셸이 실행하며, 이틀간 거절 문장은 1건이었다.
- `stdin` literal 은 `printf '…' | cmd` 로. `env` 는 `FOO=1 cmd` 로.
- 설명문은 네 문장. 무엇을 하는가, `argv` 와 `script` 중 언제 무엇을 쓰는가, `cwd` 는
  상대 경로, `masc` 예약 명령. Anthropic 지침("3–4 sentences", "as you would describe your
  tool to a new hire")에 맞춘다.
- 출력 스키마(`execute_output_schema`: `ok`, `status.kind/code/signal`, …)는 그대로 둔다.
  Codex 가 `output_schema` 를 선언하는 것과 같은 방향이다.
- 런타임: `keeper_tool_execute_typed_input.ml` 에서 pipeline/then/redirect 디코딩과 lowering
  을 지운다. `Shell_ir` 과 샌드박스 레인 계약은 그대로다. 모델이 `pipeline` 을 보내면 지금의
  스키마 검증이 모르는 필드로 거절한다(#32343 의 렌더).
- `$defs`/`$ref` 는 쓰지 않는다. 중복이 사라지면 필요 자체가 없고, Gemini `parameters` 와
  llama.cpp 의 중첩 ref 문제를 피한다(근거 기록 4번째 항목).

### 1.6 바뀌지 않는 것

- Gate, path jail, 샌드박스 프로필, 원격 레인 프로토콜, `Shell_ir`.
- `argv` 의 execve 의미. 메타문자는 데이터다.
- RFC-tools-as-shell-commands 의 `masc` 예약 명령. `script` 가 유일한 결합 표면이 되므로
  오히려 그 RFC 의 자리가 분명해진다.

## 2. 도구 표면

### 2.1 지금

| 항목 | 값 |
|---|---|
| 요청당 항상 싣는 도구 | 62~69개, 90~113 KB (deepseek, minimax, glm keeper 스냅샷) |
| 보류(`defer_loading = true`) | 30개. 배열에 0개. `keeper_tool_search` 설명에 이름만 1~2 KB |
| 빈도로 더 미룰 수 있는 것 | 이틀간 호출 2회 이하 4개, 2 KB |
| 큰 것 | Execute 11.4 KB, `keeper_surface_post` 4.3, `keeper_surface_read` 4.0, `keeper_skill` 4.0(설명에 스킬 identity JSON 목록), `Read` 3.2, `masc_board_list` 3.2 |
| 턴마다 바뀌는 설명문 | `keeper_skill` 의 Available 목록, `keeper_tool_search` 의 보류 이름 목록 |
| 시스템 프롬프트 | 8.1~9.6 KB, 그중 `<available_goals>` 5.2 KB(활성 goal 37개, 전 keeper 공통) |
| 요청당 입력 토큰 | minimax-m3 세션 479회 호출, 입력 2,610만 토큰(호출당 5.4만), 캐시 읽기 41%. deepseek 12% |

### 2.2 벤더 지침

- OpenAI: 턴 시작 시 도구 20개 미만. Gemini: 활성 10~20개 최대. Anthropic: 10개 이상이거나
  정의가 10k 토큰 넘으면 tool search, 30~50개부터 선택 정확도 하락, 가장 자주 쓰는 3~5개만
  비보류.
- 캐시 접두사는 세 벤더 모두 tools → system → messages. 도구 하나의 이름·설명·순서가 바뀌면
  Anthropic 은 system 과 messages 까지 무효, OpenAI 는 "entire rendered prefix" 일치 요구.
  Anthropic 은 `defer_loading` 도구를 캐시 키 계산 전에 뺀다. MCP 2026-07-28 은 `tools/list`
  를 "deterministic order … improves LLM prompt cache hit rates" 로 명시.

### 2.3 설계

1. **동적 목록을 도구 설명에서 뺀다.** `keeper_skill` 의 Available 목록과 `keeper_tool_search`
   의 보류 이름 목록은 턴마다 바뀌는 텍스트라 도구 접두사를 매 턴 깬다. 둘 다 시스템 문맥의
   접두사 뒤(`extra_system_context`) 또는 도구 결과로 옮긴다. 스킬 목록은
   RFC-skills-as-tools 레인이라 그 RFC 의 표면으로 옮기는 것으로 적고 여기서는 자리만 비운다.
2. **보류 도구는 이름 + 첫 문장.** 이름만으로는 부를 이유를 못 찾는다. 첫 문장(≤120 B)을
   같이 실으면 30개 × 120 B = 3.6 KB 다. 지금 이름 목록 2 KB 와의 차이는 캐시로 흡수된다(1번
   뒤에는 이 목록이 접두사 밖이다).
3. **항상 싣는 집합을 turn 단위 손익으로 다시 고른다.** 빈도(호출 수)가 아니라 "그 도구를
   쓰는 턴의 비율" 로 본다. 한 턴에 여러 번 부르는 도구(`keeper_artifact_read` 470회)는
   턴 비율이 낮을 수 있다. 목표는 항상 싣는 집합 20개 안팎, 나머지는 2번의 검색으로.
4. **goal 목록은 시스템 프롬프트 밖.** 37개 5.2 KB 가 전 keeper 에게 같은 내용으로 가고,
   goal 이 하나 늘면 system 접두사가 통째로 바뀐다. `masc_goal_list` 가 있다. 자기 task 가
   걸린 goal 만 `extra_system_context` 로 준다.
5. **순서 고정.** 도구 배열은 결정적 순서(카탈로그 순서)로 내고 그 순서를 핀한다.
   `test_keeper_runtime_schemas_toml_parity` 가 하는 것을 전체 배열로 넓힌다.
6. **`$defs` 는 provider capability 뒤에서만.** Execute 축소 뒤에도 `keeper_surface_*` 같은
   중복이 남으면, Anthropic strict·OpenAI strict·MCP 에서만 켜고 llama-server·ollama cloud·GLM
   은 카나리 1회 뒤 결정한다. 이 RFC 의 필수 항목이 아니다.

## 3. 단계

| PR | 내용 | 동작 변화 | 증명 |
|---|---|---|---|
| 1 | Execute v2: TOML 파라미터 5개, 설명문 4문장, `typed_input` 에서 pipeline/then/redirect/env 삭제, 테스트 갱신 | `pipeline`/`then`/typed `stdin` 입력이 스키마 거절(이틀간 3건) | `test_execute_tool_toml_parity` 새 바이트 핀, `test_keeper_tool_schema_bytes` 하락, `test_keeper_tool_execute_typed_input` 축소, exec_dispatch 스위트 불변 |
| 2 | 도구 배열 순서 핀 + 동적 목록 두 개를 설명문 밖으로 | 설명문 바이트만 | 순서 핀 테스트, 스냅샷 diff 로 도구 접두사가 턴 간 동일함 |
| 3 | goal 목록을 `extra_system_context` 의 task 범위로 | 시스템 프롬프트 -5 KB | 골든 갱신, 스냅샷 system 바이트 |
| 4 | 보류 도구 이름 + 첫 문장, 항상 싣는 집합 재선정(turn 단위 손익 측정 스크립트 포함) | 요청당 도구 수 | 스냅샷 도구 수·바이트, `keeper_tool_search` 호출 뒤 성공률 |
| 5 | (선택) provider capability 뒤 `$defs` | provider 별 | 카나리 로그 |

각 PR 은 ≤20k 토큰 단위, 적대 리뷰 병렬, 로컬 dune 빌드 없이 CI `@check` 와 핀으로.

## 4. 측정

배포 경계마다 24h 창을 같은 시각대로 비교한다(`scripts/measure-tool-roundtrips.py` + 스냅샷).

| 지표 | 지금 | 목표 |
|---|---|---|
| Execute 스키마 바이트 | 6,776 | ≤ 1,600 |
| Execute 실패율(인프라 제외) | 09-02 재기동 전 7.3% 전체, 스키마 오류 3/866 | 스키마 오류 0, 전체 실패율 비상승 |
| 요청당 도구 바이트 | 90~113 KB | PR1 뒤 -5 KB, PR4 뒤 ≤ 40 KB |
| 캐시 읽기 비율(usage.total_cache_read / total_input) | minimax 41%, deepseek 12% | PR2·3 뒤 상승(캐시가 있는 provider 에서) |
| 시스템 프롬프트 바이트 | 8.1~9.6 KB | PR3 뒤 ≤ 4.5 KB |

## 5. 위험

- `pipeline`/`then` 을 아는 모델이 계속 보낸다: 이틀간 3건. 거절 문장이 `script` 를 가리키면
  된다. 24h 안에 1%/일을 넘으면 되돌린다(근거 기록의 롤백 조건).
- heredoc·`$(…)`·제어문은 파서 밖이라 정책 판정이 약하다: 08-31 RFC 가 이미 진짜 셸로
  실행하며 샌드박스가 봉쇄한다는 입장이다. 이 RFC 는 그 입장을 바꾸지 않는다. 그 부분집합을
  넓히는 RFC-shell-ir-* 은 그대로 진행한다.
- 골든·바이트 핀 다수 갱신: 테스트 파일 85개가 `tool_execute` 를 언급한다. PR1 에서 실제로
  움직이는 핀만 골라 갱신하고, 실행 결과로 확인한다.

## 6. 다른 RFC 와의 관계

- RFC-0091: `argv` 는 유지, JSON `Pipeline` IR 노출은 철회. 0091 §1 의 문제(사후 lexer)는
  파서로 해결된 상태다.
- RFC-execute-subset-dispositions: 불변. 파서가 못 읽는 것의 처분은 그대로.
- RFC-execute-boundary-is-the-sandbox: 확장. "`pipeline` 의 typed 경로 유지" 유보를 거둔다.
  이 RFC 가 병합되면 그 RFC 의 §0 한 줄을 갱신한다.
- RFC-tools-as-shell-commands: 불변, 강화.
- RFC-skills-as-tools: 2.3-1 의 스킬 목록 이동은 그 RFC 의 표면으로 넘긴다.
