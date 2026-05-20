---
rfc: "0091"
title: "Keeper bash tool: cmd string → typed Argv schema (lexer/validator 박멸)"
status: Draft
created: 2026-05-17
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0084", "0089"]
implementation_prs: [15720, 16235, 16238, 16296]
---

# RFC-0091 — Keeper bash tool: cmd string → typed Argv schema

> **번호 변경 노트 (2026-05-17)**: 본 RFC 는 원래 RFC-0090 으로 push 되었으나
> 같은 시점 다른 워크로드 (`write-side success-model attribution`, PR #15651)
> 가 ledger 0090 을 먼저 머지하여 본 RFC 는 0091 로 재할당되었다. 사용자
> feedback `memory/feedback_rfc_number_reservation_needed.md` 가 명시한 ledger
> race-loss 시나리오의 실제 사례.

## §1 컨텍스트

2026-05-17 24h log audit (`<base-path>/.masc/logs/`, 7 file)이 keeper_bash 경로에서 *단일 dominant ERROR 패턴* 을 식별:

- `keeper_bash returned error result (1/3): "Path syntax blocked: shell quoting, globbing, brace expansion, and backslash escapes are not allowed for path-bearing keeper commands"` — **90 raw site emission + 60 caller-side mirror + 59 retry log + 44 registry recording = 253 ERROR (24h Top 20 ERROR의 ~40%)**

emission 코드는 `lib/worker_dev_tools.ml:611-617`:

```ocaml
let path_syntax_blocked_message token =
  let hint = path_token_error_hint token in
  "Path syntax blocked: shell quoting, globbing, brace expansion, and backslash \
   escapes are not allowed for path-bearing keeper commands. Use plain unquoted \
   paths and explicit cwd."
  ^ if hint = "" then "" else " " ^ hint
;;
```

위 message 자체는 *guardrail*이지만, *guardrail 존재 자체가 워크어라운드*다. `keeper_bash` tool의 입력 schema가
`{ "cmd": "<shell command string>" }` 한 줄 string으로 정의되어 있어, keeper가
shell metacharacter(`*`, `?`, `[]`, `{}`, `\`, `'`, `"`)를 포함한 path를 그
한 줄 안에 넣었을 때 *post-hoc lexer*가 그것을 *감지해서 거부*해야 한다. 즉
**string-as-protocol 워크어라운드 위에 string-classifier 워크어라운드가
누적된 자기참조 구조**이며, 이는 다음 두 안티패턴에 동시 해당한다:

- `instructions/software-development.md` §"워크어라운드 거부 기준 §2 String/Substring 분류기 보강"
- `instructions/software-development.md` §"AI 코드 생성 안티패턴 §2 Unknown → Permissive Default"
  (lexer가 unknown shell metachar를 만나면 default error message로 흡수)

증거로 `lib/worker_dev_tools.ml`은 현재 **1718줄 godfile**(`software-development.md` §"파일 크기 임계값 500줄+ 즉시 분할" 위반)이며, 그 본문의 대부분(line 102 ~ 750+)이
*string command를 안전성 검증하는 lexer/parser/allowlist*다. 한 줄로 요약:
**typed input schema의 부재가 그 분량의 코드를 강제한 것**.

본 RFC는 RFC-0084 sprint(`Implementation Complete`)가 dispatch path를 단일
`guarded_dispatch`로 통합한 이후의 *다음 layer* — *tool input schema 자체의
typed boundary* — 를 닫는다. RFC-0089(`string classifier → typed variant`)는
*내부 상태* 분류기를 닫는 도구이며 *외부 protocol* boundary는 §2 scope-out으로
명시 제외했으므로, 본 RFC가 그 빈자리(=tool input protocol boundary)를 채운다.

## §2 의도된 결과

1. **`keeper_bash` (그리고 형제 dev tools — `keeper_code`, `keeper_search`, `keeper_review`) 의 입력 schema 가 typed argv variant**:

   ```ocaml
   type bash_input =
     | Exec of {
         executable : string;        (* "rg" / "find" / "git" — allowlist enforced *)
         argv : string list;         (* shell이 끼지 않은 raw argv *)
         cwd : Path.t option;        (* typed path, not string *)
         env : (string * string) list;
       }
     | Pipeline of {
         stages : exec_stage list;   (* explicit pipe between Exec stages, no `|` parsing *)
       }
   ```

2. **`lib/worker_dev_tools.ml` 의 shell metachar lexer/validator 코드 박멸** —
   `path_syntax_blocked_message`, `path_token_error_hint`, `tokenize_path_args`,
   `forbidden_shell_chars[_coding][_coding_base]`, `has_process_substitution`,
   `has_unsafe_redirection`, `has_dangerous_ampersand`, `split_shell_tokens`,
   `is_safe_fd_redirect_token`, `token_value_is_redirect_to_dev_null`,
   `token_value_is_redirect_op`, `command_pattern_arg_flags` (find/rg/grep/sed
   special-casing), `token_is_inline_pattern_flag`, `command_flag_pattern_arity`,
   `rg_token_is_option_value`, `command_treats_plain_args_as_content`,
   `path_validation_tokens` — 전체 사용자 데이터 경로에서 *string parsing이
   사라진다*. allowlist (`dev_allowed_commands`, `readonly_allowed_commands`) 는
   `Exec.executable` 의 검증에 남되, *string parsing*이 아닌 *string equality*
   로만 작동한다.

3. **godfile 분해**: `worker_dev_tools.ml` 1718줄 → typed schema 모듈
   (`bash_input.ml/.mli`, ~80 LOC) + executable allowlist 모듈
   (`dev_exec_allowlist.ml/.mli`, ~120 LOC) + path SSOT 사용
   (`Host_config.cwd_for_keeper`) 로 분산. lexer 코드는 *삭제*되므로 분해 후
   총 LOC가 ~70%+ 감소할 것으로 추정한다 (검증되지 않은 추정; Implementation
   summary에 실측 기록).

4. **24h ERROR 250+ → 0**: lexer가 사라지므로 `Path syntax blocked` 메시지
   자체가 emit될 수 없다. retry 16 ERROR + registry recording 14 ERROR (둘 다
   동일 site의 mirror)도 함께 사라진다.

## §3 Non-goals

본 RFC는 다음을 다루지 않는다:

- **shell pipeline parsing 보존**. `cmd: "rg foo | head -10"` 같은 입력은
  *지원 중단*하고, keeper가 `Pipeline { stages = [Exec rg; Exec head] }` 로
  명시 보내도록 한다. shell parser 보존은 워크어라운드 #2 (string classifier)
  의 *유지*에 해당한다.
- **interactive shell** 또는 **REPL**. typed argv는 single-shot 실행만 지원.
  long-running interactive subprocess가 필요한 site는 별도 `keeper_repl` tool
  로 분리되며 본 RFC 범위 밖.
- **legacy string schema 호환**. RFC 머지 PR이 `lib/worker_dev_tools.ml`
  lexer를 *같은 PR에서* 삭제한다. transitional dual-accept(`cmd: string`
  계속 받으면서 typed 추가)는 `feedback_hardcoding_and_legacy_zero_tolerance.md`
  위반.
- **외부 MCP 서버에 노출된 bash tool schema**. RFC-0084에서 외부 노출이 이미
  `guarded_dispatch` 단일 경로로 통합됐으므로, 본 RFC는 *내부 tool descriptor*
  변경만 수반한다. MCP wire schema는 PR-4 에서 함께 갱신.
- **keeper persona prompt 변경**. RFC 본문에서 prompt를 수정하지 않는다.
  PR-3 에서 tool descriptor JSON schema가 변경되면 LLM이 그 schema에 맞춰
  argv list를 생성하므로 prompt 직접 변경 없이 동작한다. 단 *기존 keeper TOML
  fixture* 의 example bash call은 PR-3 머지에서 동시 갱신한다.

## §4 Audit (2026-05-17)

24h 로그에서 측정된 site별 ERROR 빈도와 emission 경로:

| 경로 | ERROR 건수 | 코드 위치 |
|---|---:|---|
| 직접 emission | 90 | `worker_dev_tools.ml:613` (`path_syntax_blocked_message`) |
| caller-side mirror (`keeper:<K> tool_error: Bash`) | 60 | keeper turn loop가 tool_error를 다시 WARN로 |
| retry 1/3 첫 시도 실패 | 59 | `keeper_bash returned error result (1/3)` |
| registry recording error | 44 | `registry: recording error name=<K> error=Path syntax blocked` |
| **합계** | **253** | (동일 site의 4-layer 증폭) |

증폭 비율 ~2.8× 가 보여주는 것: 한 site의 single-layer fix가 4-layer log noise
를 동시 제거. lexer를 *유지하면서* level demote 하는 워크어라운드 (telemetry-
as-fix 패턴 #1) 는 거부 — 데이터 자체는 사라지지 않는다.

worker_dev_tools.ml 의 *현재 godfile* 구성 (1718 LOC) 중 본 RFC가 삭제 대상으로 지정하는 코드의 LOC 추정:

```
$ rg -n "tokenize_path_args|path_syntax_blocked_message|path_token_error_hint|forbidden_shell_chars|has_process_substitution|has_unsafe_redirection|has_dangerous_ampersand|split_shell_tokens|is_safe_fd_redirect_token|token_value_is_redirect_|command_pattern_arg_flags|token_is_inline_pattern_flag|command_flag_pattern_arity|rg_token_is_option_value|command_treats_plain_args_as_content|path_validation_tokens|tokenize|scan|push" lib/worker_dev_tools.ml | wc -l
```

위 search 결과를 Phase 1 PR에서 정확히 측정해 Implementation summary 에 기록한다.

## §5 Migration plan (4-phase, 4 PR)

### PR-1 — typed schema 정의 + 단일 caller 변환 (foundation)

1. 신규 모듈 `lib/keeper/keeper_tool_bash_input.ml(i)` 작성:
   `bash_input` variant + `exec_stage` record + `validate_bash_input`
   (executable allowlist + cwd Path.t check만, **string parsing 없음**).
2. `worker_dev_tools.ml` 의 `dev_allowed_commands` / `readonly_allowed_commands`
   를 신규 `lib/keeper/dev_exec_allowlist.ml(i)` 로 분리.
3. 한 caller (`worker_dev_tools.run_keeper_bash` 의 single entry) 를 typed
   schema로 전환. 다른 caller는 PR-2 에서.
4. 신규 test `test/test_keeper_bash_typed_input.ml` 가 동일 입력에 대해
   legacy lexer 와 typed schema 가 동일한 외부 효과(stdout/stderr/exit)
   를 산출하는지 8개 representative invocation 으로 비교한다.

acceptance: PR-1 이후 string lexer 코드는 *그대로 남는다*. PR-2 에서 caller
전수 변환 + 같은 머지에서 lexer 삭제.

### PR-2 — caller 전수 변환 + lexer 삭제

1. `keeper_bash` tool 이 노출된 모든 caller (keeper turn loop, MCP wrap,
   test fixture) 가 `bash_input` 변형을 받도록 변환.
2. `worker_dev_tools.ml` 의 §2.2 enumerated 함수 17 개 + 그 dependent 변수
   (`forbidden_shell_chars`, `forbidden_shell_chars_coding`, `forbidden_shell_chars_coding_base`)
   삭제. 신규 LOC 0, 삭제 LOC 측정치를 PR body 에 기록.
3. test fixture (`test/test_worker_dev_tools.ml`, `test/test_keeper_tool_call_log.ml`,
   `test/test_env_config_sandbox.ml`) 의 string-cmd 입력을 typed 로 변환.
4. acceptance: `rg "Path syntax blocked"` lib/ + test/ = 0 hit.

### PR-3 — tool descriptor JSON schema 변경 + dogfooding

1. `lib/tool_shard_types_schemas_bash.ml` 에 `descriptor_variant`
   닫힌 합타입 (`Legacy_v0 | Typed_v1`) 도입. 단일 schema-build 함수
   `keeper_bash_schema ~variant` 가 *어느 variant 를 emit 하느냐* 만
   분기한다. 두 variant 가 서로 다른 코드 경로를 갖지 않으므로
   "string classifier 워크어라운드 #2" 가 재발하지 않는다.
2. `Typed_v1` variant 에서:
   - `input_schema.properties` 에서 `cmd` 필드 제거
   - `oneOf` 에서 `cmd` branch 삭제 (`executable | pipeline | stages` 3 branch)
   - top-level `required: ["executable"]` 추가
   - description prose 갱신: "Legacy cmd remains accepted" → "Execute one
     command through the keeper_bash safety gates via typed argv. … The
     legacy 'cmd' string field is no longer accepted — shell metacharacters
     in argv are data, not syntax."
3. **Reader-side reject 는 이미 존재**:
   `lib/keeper/keeper_tool_bash_input.ml:165-175` (PR-1) 가
   `Result.Error "legacy cmd string is not a typed keeper_bash input; provide
   executable/argv or pipeline stages"` 로 거부한다. legacy 디스크립터가
   보이는 상태에서도 typed boundary 경유 호출은 typed Error.
4. **Gate**: 환경 변수 `MASC_KEEPER_BASH_DESCRIPTOR_VARIANT` 가
   `legacy_v0` (default) | `typed_v1` 중 하나. unset 또는 unknown 값은
   `legacy_v0` 으로 fall-back. 단일 emit path, 단일 schema function 으로
   소스 트루스 분기 없음.
5. **Staged rollout** (PR-3 머지 후, 사용자 환경 게이트):
   - **Day 0 (PR-3 머지)**: 환경 default `legacy_v0` 유지. 코드 변경 자체는
     no-op for fleet. 새 `descriptor_variant` 합타입 + 테스트만 land.
   - **Day 1 (verifier-only soak)**: verifier keeper supervisor 만
     `MASC_KEEPER_BASH_DESCRIPTOR_VARIANT=typed_v1` 으로 기동. read-only
     diagnostics keeper 이므로 pipeline/background 가 본래 없고 가장 안전.
   - **Day 1–2 soak metric**:
     `rg "Boundary_invalid" .masc/logs/*.log | wc -l` < 5 / 24h
     (verifier keeper turn 의 typed_v1 적응 실패 임계). 임계 초과 시
     verifier 만 `legacy_v0` 으로 되돌리고 RFC §7 followup 으로 escalate.
   - **Day 3 (fleet flip, 별도 결정)**: soak green 이면 default 를
     `typed_v1` 으로 flip. 별도 1-line PR-3.1 (`resolve_descriptor_variant_from_env`
     의 default → `Typed_v1`). 동시에 PR-2 caller sweep 의 진행 상황 cross-check.
6. **Rollback**: PR-3 자체 rollback 은 *env var 값 한 줄 flip* 이면 충분
   (`MASC_KEEPER_BASH_DESCRIPTOR_VARIANT=legacy_v0` — 또는 unset). 코드
   revert 필요 없음. PR-3.1 (default flip) rollback 도 동일 1-line PR revert.
7. **PR-2 scope 명시 (본 PR 범위 밖)**:
   - `lib/keeper/keeper_shell_bash.ml:1023` `raw_cmd_str` 류 7 caller-side
     reader
   - 31 keeper-side schema reference / fixture
   - 152 test fixture
   - = ~335 사이트. PR-2 가 sweep 후, PR-4 가 `lib/worker_dev_tools.ml`
     1718 줄 lexer (`path_syntax_blocked_message`, `tokenize_path_args` 등)
     를 삭제.
8. dogfooding 위치 변경: 원래 plan 은 PR-3 의 CI 가 typed_v1 로 keeper turn
   을 돌리는 형태였으나, *fleet-wide 즉시 flip* 은 unsafe (외부 LLM 적응
   transition 미보장). PR-3 의 CI dogfooding 은 `verifier` keeper 의 24h
   soak 로 대체 (위 5–6).

### PR-4 — godfile 분해 (worker_dev_tools.ml split)

PR-2 머지 후 `worker_dev_tools.ml` 가 ~800 LOC 까지 줄어든 상태에서 남은 코드를
도메인별로 분리:

- `lib/keeper/dev_exec_allowlist.ml(i)` — PR-1 에서 이미 분리 (allowlist data)
- `lib/keeper/keeper_dev_tools_runtime.ml(i)` — Eio.Process 호출, stdout/stderr 캡쳐
- `lib/keeper/keeper_dev_tools_dispatch.ml(i)` — `guarded_dispatch` 진입점
- `lib/worker_dev_tools.ml` — 단순 re-export (≤30 LOC) 또는 완전 삭제

acceptance: 단일 파일 LOC > 500 인 신규 파일 없음. `software-development.md`
§"파일 크기 임계값" 준수.

## §6 Acceptance

본 RFC 가 Implemented 로 이행하려면 다음이 동시에 성립:

- [ ] `rg "Path syntax blocked" lib/ test/` = **0 hit**.
- [ ] `rg "forbidden_shell_chars" lib/ test/` = 0 hit.
- [ ] `rg "tokenize_path_args" lib/ test/` = 0 hit.
- [ ] `wc -l lib/worker_dev_tools.ml` ≤ 300 또는 파일 자체 삭제.
- [ ] `keeper_bash` tool descriptor JSON schema 가 `{executable, argv, ...}` 구조.
- [ ] CI: 8 representative bash invocation 동등성 test green.
- [ ] 24h log re-audit 에서 `Path syntax blocked` ERROR 0 건 (단, PR-3 머지 후 keeper LLM 적응에 1~2 일 transition 허용).
- [ ] `catch-all _ -> ...` 0 건 in 신규 `bash_input` `match` 경로.

## §7 위험 / Open questions

1. **keeper LLM 적응 transition**. PR-3 머지 직후 keeper persona LLM 이 새
   schema 에 적응하기까지 turn 단위로 시간이 걸린다. 이 transition 동안 *모든*
   bash call 이 boundary parse fail 하면 keeper 가 정지한다. mitigation: PR-3
   머지를 *staged rollout* (verifier keeper 부터, 24h soak 후 fleet 확대) 으로 진행.
   gate = `MASC_KEEPER_BASH_DESCRIPTOR_VARIANT=typed_v1`, default `legacy_v0`.
   soak metric: `rg "Boundary_invalid" .masc/logs/*.log | wc -l` < 5 / 24h
   (verifier scope). 임계 초과 시 env var 한 줄로 즉시 rollback.
2. **외부 MCP 서버**. masc-mcp 외부 클라이언트 (Claude Code, Codex, Gemini)
   가 string cmd 로 호출하는 케이스. RFC-0084 PR-11 (legacy dispatch mli surface
   removal) 후 외부 노출 surface 가 typed 로 통합됐으므로 영향 없음으로 가정,
   PR-3 머지 전 cross-check 의무.
3. **dune build 영향**. `worker_dev_tools.ml` 가 godfile 이라 caller 가 많을
   가능성. `rg "Worker_dev_tools\." lib/ | wc -l` 로 측정 후 PR-1 body 에 기록.
   100+ caller 면 PR-2 sub-split (caller 도메인별).
4. **Pipeline variant 의 expressiveness**. shell `&&` / `;` / process
   substitution `<(...)` 같은 케이스. 본 RFC 는 `&&` / `;` 지원 중단으로 결정
   (separate Exec 로 분할), `<(...)` 는 미지원 (필요 시 별도 RFC).

## §8 Evidence record

- **Source**: `<base-path>/.masc/logs/` 7 file, 2026-05-16 03:46 ~ 2026-05-17 03:46.
- **Method**: `rg --no-filename "^\[20[0-9-]+ [0-9:]+\] \[(WARN|ERROR)\]"` + pattern
  categorization (`watchdog` / `current_task` / `cascade_exhausted` / etc.). raw
  log lines 2,292 → 20 카테고리 + Other.
- **Top 1 ERROR pattern**: `Path syntax blocked` 90 raw + 60 caller mirror + 59
  retry + 44 registry = 253 (24h Top 20 ERROR 의 ~40%).
- **Reproducer**: `cd "$MASC_BASE_PATH/.masc/logs" && rg "Path syntax blocked" *.log | wc -l`
  (single command, deterministic).
- **Confidence**: High (코드 단일 emission point `worker_dev_tools.ml:613` 그
  message 한 줄, 4-layer 증폭 경로도 grep 검증됨).
- **Delta**: 이전 audit 없음. 본 RFC 가 baseline.

## §9 References

- RFC-0042 `keeper_turn_terminal.t.code` closed sum (Draft) — typed boundary 패턴 선례.
- RFC-0084 keeper-tool-dispatch-unification (Implementation Complete) — dispatch
  단일 경로 (`guarded_dispatch`) 의 기반. 본 RFC 는 *그 다음 layer* (tool input
  schema) 를 닫는다.
- RFC-0089 string-classifier-to-typed-variant (Draft) — *내부* 분류기 범위.
  본 RFC 는 §2 scope-out (외부 protocol boundary) 의 자매 RFC.
- `instructions/software-development.md` §"워크어라운드 거부 기준 §2 String
  분류기 보강" / §"파일 크기 임계값 500줄+ 즉시 분할".
- `memory/feedback_hardcoding_and_legacy_zero_tolerance.md` — root-fix PR 가
  같은 머지에서 legacy 동시 삭제 의무.
- `memory/feedback_lint_string_classifier_is_workaround_not_fundamental.md` —
  lint 기반 classifier guard 가 워크어라운드 #2 자기참조 해당. 본 RFC 는
  *코드 자체* 를 제거하므로 해당 회피.

## §10 Implementation status

- [ ] PR-1 typed schema + single caller
- [ ] PR-2 caller 전수 변환 + lexer 삭제
- [x] PR-3 tool descriptor JSON schema + verifier-gated rollout (descriptor flip;
      PR-3.1 default flip pending verifier 24h soak — sees `legacy_v0` until then)
- [ ] PR-4 godfile 분해
