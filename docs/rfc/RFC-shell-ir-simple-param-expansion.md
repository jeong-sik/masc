---
rfc: "shell-ir-simple-param-expansion"
title: "Shell IR가 단순 파라미터 확장($VAR)을 닫는다 — env 세팅 패턴이 마지막 걸림돌이다"
status: Draft
created: 2026-09-01
updated: 2026-09-01
author: claude
supersedes: []
superseded_by: null
related: ["0391", "execute-boundary-is-the-sandbox"]
implementation_prs: []
---

# RFC: Shell IR가 단순 파라미터 확장을 닫는다 (shell-ir-simple-param-expansion)

## 0. Summary

`DUNE_CACHE=enabled DUNE_CACHE_ROOT=$PWD dune build` 같은 환경변수 세팅이 아직
거절된다. 표현력(`Shell_ir.Var`)과 실행(시점 치환)은 이미 존재하고, 막힌 문은
렉서의 한 규칙이다. 단순 형태(`$NAME`, `${NAME}`)만 열고 나머지 달러 문법은
기존대로 거절을 유지한다.

## 1. 배경 (실측)

- #32087(script=셸 확정) 배포 후 첫날(09-01) shell costume 125건 중
  `param_expansion` **34건** — 잔여 거절의 두 번째 이유. 패턴은
  `DUNE_CACHE=… DUNE_CACHE_ROOT=$PWD … dune build`(lane-smith의 dune 빌드)처럼
  **env assignment 값 안의 `$VAR`** 이다.
- 7일 전체로는 param_expansion 48건. 대부분 같은 모양.

## 2. 이미 다 있는 것 — 문은 하나뿐이다

- AST: `Shell_ir.arg`에 `Var of string * arg_meta`가 존재한다(mli 문서: `[$HOME]`,
  `[${VAR}]`).
- 실행: `Exec_dispatch.resolve_arg`가 `Sys.getenv_opt`로 치환하고,
  `resolve_env`가 env binding 값을 같은 경로로 푼다.
- env prefix: `bash.ml`의 `parse_env_assignment`/`split_env_prefix`가 leading
  `NAME=...` WORD를 이미 쪼갠다.

유일한 차단점은 `bash_lexer.mll`의 한 규칙: `| '$' { excluded `Param_expansion }`.
`$`를 만난 WORD가 값이든 인자든 통째로 거절된다.

## 3. 설계

### 3.1 여는 것 — 단순 형태 두 가지만

- `$NAME`과 `${NAME}` → `Var` 노드. 다른 달러 문법은 그대로 둔다:
  - `${NAME:-default}` — 기본값 시맨틱은 아직 `Var`에 없으니 그대로 거절.
  - `$((`, `$(`, backtick, `$"` — 기존 excluded(`Arith_expansion`, `Cmd_subst` 등)
    유지. 인젝션 표면이 커지는 형태는 이 RFC에서 열지 않는다.

### 3.2 결정 항목 — Path Jail와 치환의 순서

`resolve_arg`는 실행 직전 치환이다. `$VAR`가 경로 인자에 들어오면:

- **채택안**: 치환된 값이 경로 검증 대상이면 **치환 뒤** 같은 jail 규칙을 적용한다.
  jail 검증이 리터럴 전용이라면, resolve 지점에서 같은 검증기를 다시 통과시킨다.
  검증기가 두 벌이 되면 안 된다 — 같은 함수을 두 시점에 쓴다.
- Var가 이미 어느 경로로 들어오고 있었다면 그 경로의 관례를 따른다(구현 시
  `Var` 생산자를 전수 확인해 소비자와 함께 밝힌다).

### 3.3 관측

거절 태그는 닫힌 어휘를 유지한다. 단순 확장이 representable로 흡수되면
`param_expansion` 잔여는 `${VAR:-…}` 형태만 남아야 하고, 그 감소를 costume census가
그대로 보여준다(RFC-0391의 `command_separator` 소멸과 같은 검증 방식).

## 4. PoC 판정 기준

- lane-smith의 실제 dune 빌드 라인(`DUNE_CACHE=… $PWD …`)이 거절 없이
  representable이 되는가.
- 배포 후 일주일간 `param_expansion` costume이 `${VAR:-…}` 잔여만 남는가.
- Path Jail: `$VAR`가 경로 인자에 있을 때 jail 밖 값으로 치환되면 거절되는지를
  mutation으로 증명(문자 그대로 넣었을 때와 같게 거절).

## 5. 단계

단일 PR: 렉서 규칙 + jail 재검증 지점 + mutation 검증 2종(경로 탈출 치환 거절,
`${:-}` 여전 거절). RFC-0391과 같은 규모.

## 6. 반론과 답

- **"변수 치환이 인젝션이다"** — `$VAR` 치환 결과는 셸이 다시 파싱하지 않는다.
  bash와 달리 이 IR은 치환을 argv 원소 수준에서 하고(`resolve_arg`가 문자열을
  조립), 단어 재분할·glob은 `arg_meta.glob`이 지배한다. 치환값이 glob 문자를
  포함하면 glob 메타가 이미 그걸 통제한다.
- **"왜 `${:-}`까지 안 열까"** — 필요가 측정되지 않았다. 잔여가 쌓이면 그때
  열고, 그때 기본값 시맨틱을 `Var`에 typed로 추가한다.

## 7. 근거

- 내부: `.tmp/toolstudy/masc-gap.md` §1 (param_expansion 34/125)
- 코드: `lib/exec/parser/bash_lexer.mll`('$' excluded), `lib/exec/exec_dispatch.ml`
  (resolve_arg/resolve_env), `lib/exec/parser/bash.ml`(env prefix)
- 백로그: issue #32369 작전 4
