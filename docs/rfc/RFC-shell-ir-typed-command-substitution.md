# RFC: typed 커맨드 치환 — `$(cmd)`를 자식 IR로 읽고, 그 stdout을 argv 한 원소로 쓴다

상태: 제안 (구현 전). 선행: RFC-shell-ir-lines-heredoc-dquote,
RFC-shell-ir-simple-param-expansion, RFC-0391.

## 1. 측정

RFC-shell-ir-lines-heredoc-dquote §1의 코퍼스(실전 `bash -c` 511건) 재실행 뒤
남은 거절 120건 중 `cmd_subst`가 62건으로 최대다. 하위 모양:

| 모양 | 건수 | 이 RFC |
|---|---|---|
| `VAR=$(cmd)` 대입값 | 29 | 연다 |
| 인라인 `… $(cmd) …` | 11 | 연다 |
| `eval $(opam env --switch=…)` | 16 | 열지 않는다 — §2.4 |
| backtick | ~0 | 열지 않는다 |

열리는 것은 약 40건(7.8%). 통과율 76.5% → 약 84%.

`eval $(opam env)` 16건은 파서 문제가 아니다. 샌드박스 이미지가 이미 switch
환경을 굽는다 (`Dockerfile.keeper-sandbox` L183-205: `ENV OPAMROOT
OPAM_SWITCH_PREFIX …`, 주석에 "`eval $(opam env)` never runs"). keeper가
호스트 스크립트 습관으로 붙이는 것이라, 거절 메시지가 "switch env는 이미
export되어 있다"고 말해주면 된다. dispatch 변경 없음.

## 2. 설계

### 2.1 IR — 닫힌 합타입에 노드 하나

```ocaml
type arg =
  | Lit of string * arg_meta
  | Concat of arg list
  | Var of string * arg_meta
  | Subst of t                 (* 새 노드: 자식 IR *)
and simple = { … args : arg list; env : (string * arg) list; … }
and t = Simple of simple | Pipeline of t list | Sequence of …
```

자식은 완전한 `Shell_ir.t`다 — 파이프·시퀀스·중첩 치환이 전부 같은 문법을
쓴다. `arg`의 소비자(`resolve_arg`, `pp_arg`, `bash.ml`의
`arg_as_assignment`, keeper 쪽 arg 순회)는 exhaustive match라 컴파일러가
전부 열거해 준다. `_ ->`로 삼키지 않는다.

### 2.2 파서 — 소스의 정적 재파싱, 출력의 재파싱이 아니다

lexer가 `$(`를 만나면 괄호 균형(따옴표 인지)으로 내부 텍스트를 잘라
`Bash.parse_string`을 재귀 호출하고, 결과 IR을 `Subst ir` 조각으로
`word_tail`/`dq_pieces`에 합류시킨다. 내부의 배제 구문은 같은 규칙으로
거절되고 그 사유가 그대로 올라온다. 이 재파싱의 대상은 **사용자가 쓴 소스**
뿐이다 — 실행 결과를 다시 파싱하는 일은 없다.

backtick은 계속 `Cmd_subst` 거절: 중첩·이스케이프 규칙이 다르고 코퍼스에
거의 없다.

### 2.3 실행 — 치환은 dispatch가 한다

`resolve_arg : arg -> string`은 순수 함수라 자식을 실행할 수 없다.
치환 평가는 `dispatch_simple` 앞단으로 옮긴다:

1. `Subst ir`를 좌→우로 만나며 부모와 **같은 sandbox target**을 물려
   `dispatch ir`를 실행한다. env 대입값 안의 `Subst`도 같은 순서에 든다.
2. 자식 stdout에서 꼬리 개행을 떼고(bash 규칙) 그 문자열을 `Lit`로 바꾼
   resolved simple을 만든다. 자식 stderr는 부모 stderr에 이어 붙이고, 자식
   exit status는 값에 영향을 주지 않는다(bash 동일).
3. 치환 결과는 **argv 원소 하나**다. 단어 분할도 glob도 없다 — bash보다
   좁고, param-expansion RFC §6과 같은 논거로 인젝션 표면이 늘지 않는다.
4. 자식은 부모의 `?timeout_sec` 남은 시간 안에서 돈다(전파 필요).

### 2.4 배제 — 유지와 추가

- **`eval`, `source`, `.` 를 bin 자리에서 이름으로 거절**한다. 새 사유
  `` `Shell_builtin of string ``. `Exec_program.of_string`은 지금 빈
  문자열만 거른다 — `$(`가 lexer에서 막혀 있어서 `eval`이 bin 자리에 도달한
  적이 없을 뿐이다. 실행 표면이 `sh -c <rendered>`(tool_calls 레코드의
  `context.cmd`가 증언)라 eval은 실제로 재파싱을 일으킨다. 이 거절은 `$(`
  개방 **이전에** 들어가야 한다.
- 치환 결과가 경로 인자에 들어가면 param-expansion RFC §3.2 규칙 그대로
  resolve 시점에 같은 jail 검증기를 다시 통과시킨다.
- 자식 stdout 크기 상한은 두지 않는다 — ARG_MAX가 자연 상한이고, cap은
  워크어라운드 시그니처다. 깊이 상한도 두지 않는다 — 50k 토큰 예산이 소스
  크기를 이미 묶고, 자식은 소스에 쓰인 만큼만 있다.

### 2.5 Gate — 부모만 보고 승인하면 자식이 우회한다

external-effect 판정이 IR 전체를 순회해야 한다. `Subst` 안의 자식 IR도
같은 판정을 받고, 하나라도 승인 대상이면 부모 호출 전체가 승인을 기다린다.
현재 순회 지점(`keeper_tool_execute_runtime`의 gate 경로)이 `arg`를 여는지
확인해 `Subst` arm을 추가한다.

## 3. 단계

- **PR-A (파서)**: `Subst` 노드 + lexer 균형 절단 + 재귀 파싱 +
  `Shell_builtin` 거절 + 파서 테스트 + 코퍼스 재실행(회귀 0 증명).
  이 단계에서 `Subst`가 든 IR은 dispatch가 `Too_complex`로 돌려보낸다(임시
  arm이 아니라 "아직 실행 못 한다"는 typed 거절).
- **PR-B (실행)**: dispatch 치환 평가 + gate 순회 + 실행 테스트 — 자식
  stdout이 argv가 되는 라운드트립, stderr 전파, 실패한 자식, timeout 전파.
- eval/opam: 코드 없음. `Shell_builtin` 거절 메시지에 "switch env는 이미
  export되어 있으니 eval을 빼라"는 한 줄.

## 4. 반론과 답

- **"셸이 출력을 다시 파싱하는 그 위험 아닌가"** — 하지 않는다. 출력은
  문자열 원소 하나가 되고 끝이다. 위험한 것은 bash의 단어 분할·재해석이며,
  이 IR엔 그 단계가 없다.
- **"중첩 실행이 무한히 깊어질 수 있다"** — 자식은 소스에 쓰인 만큼만
  존재하고 소스는 토큰 예산으로 묶여 있다. 실행 시간은 부모 timeout 안이다.
- **"`$?`는 왜 안 여나"** — 이전 명령의 exit code는 IR에 상태가 없다. dispatch가
  이미 exit code를 구조화해 돌려주므로, `echo RC=$?`는 costume 조언으로
  "결과 페이로드의 status를 보라"고 안내한다(측정 ~18건).
