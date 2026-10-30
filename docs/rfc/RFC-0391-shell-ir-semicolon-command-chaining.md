---
rfc: "0391"
title: "Shell IR 세미콜론(;) 순차 실행 커맨드 체이닝 지원"
status: Draft
created: 2026-08-25
updated: 2026-08-25
author: gemini
supersedes: []
superseded_by: null
related: ["execute-subset-dispositions", "0091"]
implementation_prs: []
---

# RFC-0391: Shell IR 세미콜론(;) 순차 실행 커맨드 체이닝 지원

## 1. 배경 및 문제

MASC는 임의의 셸 스크립트를 `/bin/bash`에 무검증으로 넘기지 않고, **정적 경로 탈출 방지(Path Jail), Gate 사전 승인, 결정론적 실행 증적(Telemetry/Replay)**을 위해 `Shell IR` AST 및 `Shell_command_gate` 검증 파이프라인을 운영한다.

그러나 LLM 에이전트(Keeper)가 다단계 명령어 또는 구분자 출력을 결합한 일상적인 복합 명령을 수행할 때(예: `echo "=== header ==="; gh pr list ...; echo "=== footer ==="`), 기존 파서는 세미콜론(`;`)을 `Too_complex Command_separator`로 분류하여 fail-closed 거부하였다.

- **실측 데이터 근거** (`.masc/logs/system_log_*.jsonl`의 `shell_costume` 기록 1,794건을 명령 원문까지 다시 세었다, 2026-08-25):

  | | 건수 | 비율 |
  |---|---|---|
  | 셸을 뒤집어쓴 호출 전체 | 1,794 | |
  | `command_separator` | 1,145 | 64% |
  | ├ 이 RFC가 푸는 것 — `;`만 | **1,108** | **62%** |
  | └ 이 RFC가 못 푸는 것 — `for`/`while`/`if`/`case`를 낀 것 | 37 | 2% |

  - 두 번째 줄과 세 번째 줄을 갈라 적은 이유가 있다. 태그는 **무엇인지가 아니라 처음 걸린 것**을 말한다. `for f in a b; do echo $f; done`은 `;`에서 먼저 걸리므로 `control_flow`가 아니라 `command_separator`로 세어진다 (출처 RFC `execute-subset-dispositions` §6이 이 편향을 미리 적어 두었다). `;`를 통과시키면 이 37건은 풀리는 게 아니라 `parse_error`로 옮겨 간다. `test_shell_costume`이 그 이동을 고정한다.
    - 2026-08-30 갱신: 태그가 렉서가 실제로 거절한 자리를 말하도록 바뀌었다. 그래서 이 37건은 `parse_error`가 아니라 스크립트가 정말 담고 있는 것으로 옮겨 간다 — `for f in a b; do echo $f; done` 은 `$f` 때문에 `param_expansion` 이다. `for`/`while`/`if` 는 여전히 낱말로 읽히므로 `control_flow` 로 세어지지는 않는다. 위 표의 비율은 측정 당시 값 그대로 둔다.
  - 기존에는 `&&`나 `||`만 조건부 `Sequence`로 허용되고, 무조건 순차 실행인 `;`가 결여되어 모델이 불필요하게 `sh -c` 우회를 시도하거나 호출 실패를 겪음.

---

## 2. 핵심 설계 및 결정

### 2.1 AST 커넥터 확장 (`Shell_ir`)
`Shell_ir.connector`에 무조건 순차 실행 커넥터인 `Seq`를 추가한다.

```ocaml
(* lib/exec/shell_ir.mli *)
type connector =
  | And_if  (** run the next command only if the one before it exited zero *)
  | Or_if   (** run the next command only if the one before it did not *)
  | Seq     (** run the next command regardless of exit status (semicolon ;) *)
```

### 2.2 Menhir LR(1) 문법 및 렉서 확장 (`bash_subset.mly`, `bash_lexer.mll`)
1. **렉서**: printable word 경계에서 `';'`를 `SEMICOLON` 토큰으로 추출. (따옴표 내부의 `';'`는 리터럴로 유지)
2. **문법**: LR(1) shift/reduce 충돌 없이 `cmd1; cmd2; cmd3` 및 말미 세미콜론(`cmd1;`)을 모두 수용하도록 `command_rest` 재귀 생성 규칙을 적용.

```menhir
/* lib/exec/parser/bash_subset.mly */
command:
  | head = pipeline rest = command_rest EOF
    { (head, rest) }

command_rest:
  | /* empty */ { [] }
  | SEMICOLON { [] }
  | SEMICOLON head = pipeline rest = command_rest {
      (Masc_exec.Shell_ir.Seq, head) :: rest
    }
  | AND_IF head = pipeline rest = command_rest {
      (Masc_exec.Shell_ir.And_if, head) :: rest
    }
  | OR_IF head = pipeline rest = command_rest {
      (Masc_exec.Shell_ir.Or_if, head) :: rest
    }
```

### 2.3 디스패처 실행 시맨틱 (`Exec_dispatch`)
- `took_the_branch`에서 `Shell_ir.Seq`인 경우 이전 프로세스의 종료 상태(0 또는 non-zero)와 무관하게 항상 분기를 타서 다음 프로세스를 실행한다.
- 각 단계의 `stdout`과 `stderr`는 실행 순서대로 누적 합산된다.

```ocaml
(* lib/exec/exec_dispatch.ml *)
let took_the_branch connector (status : Unix.process_status) =
  match connector, status with
  | Shell_ir.And_if, Unix.WEXITED 0 -> true
  | Shell_ir.And_if, (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) -> false
  | Shell_ir.Or_if, Unix.WEXITED 0 -> false
  | Shell_ir.Or_if, (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) -> true
  | Shell_ir.Seq, _ -> true
```

---

## 3. 검증 및 실측 벤치마크

### 3.1 회귀 및 정합성 검증
- `test/test_keeper_tool_execute_typed_input.exe`: 95개 테스트 전체 통과 (Pass)
- `test/test_execute_tool_toml_parity.exe`: 스키마 설명 동기화 및 바이트 패리티 통과 (Pass)
- `lib/exec/test/test_bash_parser.exe`: 파서 단위 테스트 통과 (Pass)

### 3.2 성능 실측 (Benchmark)
[`lib/exec/test/test_shell_ir_chaining_benchmark.ml`](../../lib/exec/test/test_shell_ir_chaining_benchmark.ml) 기반 실측 결과:

| 지표 | 조건 | 측정값 |
|---|---|---|
| **파서 처리량 (Throughput)** | 3단계 체이닝 10,000회 반복 | **17.54 ms** (회당 **1.75 µs**) |
| **엔드투엔드 디스패치 지연** | 2-프로세스 실제 스폰/실행 5회 | 평균 **25.63 ms** / 회 |

---

## 4. 기대 효과

1. **에이전트 UX 및 툴 호출 성공률 향상**: 모델이 익숙한 세미콜론 구분 출력을 `Execute.script`에서 거부 없이 즉시 실행 가능.
2. **`sh -c` 우회(Costume) 감소**: 날것의 셸 프로세스 탈출을 줄이고, 모든 개별 명령어가 Shell IR 단위의 정적 경로 감시와 Gate 정책 테두리 내에서 추적됨.
