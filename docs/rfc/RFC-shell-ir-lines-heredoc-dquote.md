# RFC: 셸 서브셋이 줄과 인용 heredoc과 큰따옴표 보간을 읽는다

상태: 구현됨 (같은 PR). 선행: RFC-shell-ir-simple-param-expansion, RFC-0391.

## 1. 측정

지난 8일의 `keeper_spawn` 레코드에서 `["bash","-c",script]` 모양 511건을
추출해 파서로 재실행했다. 입력은 `MASC_BASE_PATH` 또는 `--base-path`로
명시한 `<base-path>/.masc/tool_calls/2026-{08,09}/*.jsonl`이다.

| 결과 | 이전 | 이후 |
|---|---|---|
| 통과 | 353 (69.1%) | 391 (76.5%) |
| heredoc 거절 | 37 | 0 |
| param_expansion 거절 | 49 | 36 |
| cmd_subst 거절 | 56 | 62* |
| parse_error | 13 | 19* |
| subshell / glob_brace | 3 | 3 |

*증가분은 회귀가 아니라 재분류다: 앞 단계에서 거절되던 스크립트가 더 멀리
가서 다음 구문에 닿았다. 이전에 통과하던 스크립트 중 새로 거절된 것은
0건 (거절 집합 차집합으로 검증).

## 2. 여는 것 세 가지

### 2.1 개행은 구분자다

lexer가 `\n`을 공백처럼 삼켰다. 거절이 아니라 **잘못된 argv** — 두 줄짜리
스크립트의 둘째 줄 단어들이 첫 명령의 인자로 붙었다. NEWLINE 토큰을 만들고
문법이 POSIX linebreak 규칙으로 읽는다: 파이프라인 사이에서는 `;`와 같고,
`|` `&&` `||` `;` 뒤에서는 줄 계속이다. `;;`는 bash처럼 parse error로 남는다.

### 2.2 인용 heredoc은 stdin 리터럴이다

`Redirect_scope.Literal { bytes }`는 이미 있었고 dispatch도 이미 child의
stdin에 먹인다 — 생산자만 없었다. lexer가 `<<'TAG'` / `<<"TAG"`의 본문을
줄 단위로 모아 `HEREDOC_LITERAL`로 내고, 문법이 `Literal`로 만든다.

- 인용 태그만: bash에서 인용 태그 = 본문 무확장. 확장이 필요한 비인용
  `<<TAG`는 그대로 `Heredoc` 거절.
- 연산자는 줄 끝에서만: `<<'T' | wc`처럼 같은 줄에 후속이 있으면 bash의
  지연-본문 규칙과 얽히므로 그대로 거절.
- 종결자 줄의 개행은 소비하지 않고 NEWLINE으로 돌려, 다음 줄이 argv에
  붙지 않고 새 명령이 된다.
- 본문 줄마다 토큰 예산을 물려 50k 상한이 그대로 적용된다.
- 코퍼스 지배 모양: `python3 - <<'EOF' … EOF` 인라인 파이썬 37건.

### 2.3 큰따옴표 안의 단순 확장

`"a $B c"`가 `Concat [Lit "a "; Var B; Lit " c"]`로 조립된다 (전 조각
quoted 메타). 근거는 param-expansion RFC §6과 동일하다: 치환은 argv 원소
수준에서 일어나고 결과를 다시 파싱하지 않으므로, 따옴표 안이라고 인젝션
표면이 넓어지지 않는다 — bash보다 좁다.

인용부 안에서도 배제 어휘는 닫힌 채다: `$(cmd)`는 `Cmd_subst`(이전엔
달러 탓에 `Param_expansion`으로 잘못 이름 붙었다), backtick도 `Cmd_subst`,
`${X:-y}`·`${A[0]}`·`$?` 등 이름이 아닌 달러는 `Param_expansion`, 백슬래시
이스케이프는 parse error 그대로.

## 3. 남는 거절과 다음 단계 (이 RFC 범위 밖)

| 잔여 | 건수 | 갈 곳 |
|---|---|---|
| `eval $(opam env …)` | 16 | 파서가 아니라 dispatch: 샌드박스가 opam 환경을 주입하면 keeper가 eval을 쓸 이유가 없다 |
| `VAR=$(cmd)` / 인라인 `$(cmd)` | ~40 | typed Cmd_subst 노드 — 자식 IR의 stdout이 argv 한 원소가 되고 재파싱하지 않는 설계. 중첩 실행 의미론이라 별도 RFC |
| `$?` / `${PIPESTATUS[…]}` | ~18 | dispatch가 이미 exit code를 구조화해 반환한다 — costume 조언으로 유도 |
| for 루프, `< $FILE`, 중첩 인용 | 소수 | 측정 누적 전까지 보류 |

## 4. 검증

- `test_bash_parser` 신규 14케이스 (개행 4·heredoc 5·dq 5) + dollar 핀
  1건을 개방 동작으로 전환. 전체 초록.
- menhir `bash_subset.conflicts` 0바이트 유지 (개행 문법이 conflict를
  추가하지 않음).
- 코퍼스 511건 재실행: §1의 표, 회귀 0.
