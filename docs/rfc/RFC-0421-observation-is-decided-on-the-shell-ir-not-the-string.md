---
rfc: "0421"
title: "관측 여부는 문자열이 아니라 셸 IR 로 정한다 — 파서가 이미 푼 것을 분류기가 다시 못 읽는 일을 끝낸다"
status: Draft
created: 2026-09-05
updated: 2026-09-05
author: vincent
supersedes: ["0404"]
superseded_by: null
related: ["0271"]
---

## 1. 문제

keeper 의 `tool_execute` 는 게이트에서 셋 중 하나가 된다. 관측 전용이면 바로 실행,
아니면 judge 모델(또는 사람) 판정, 그리고 `always_allow` 규칙. 관측 전용 판별은
`Keeper_gate_readonly` 가 한다. 명령 표(`ls`, `cat`, `grep`, `git log` …)는 닫혀 있고,
읽기 여부는 argv 로 본다.

RFC-0404 는 keeper 가 argv 대신 한 줄 `script` 를 쓰는 경우를 열었다. 조건은 "셸이
개입할 문자가 하나도 없다" 였다. quote, 파이프, `&&`, `;`, 개행, `$`, `*`, 탭 중
하나라도 있으면 통째로 judge. RFC 는 이 손실을 "관측 조회는 quote 를 거의 안 쓰므로
감수한다" 고 적었다.

### 1.1 실측 (2026-09-04 ~ 09-05, `~/me/.masc/tool_calls/2026-09/`)

| | 건수 |
|---|---|
| Execute 호출 | 3,930 |
| judge 로 간 것 | 809 (20.6%), 전부 `judge_requested` |
| judge 대기 합계 | 76.4 시간 (pending→resolved p50 18초, p90 191초) |
| 판정 | approve 884 · reject 4 (push, squash merge, `branch -D`, checkout+pull) |
| microvm 에서 judge 로 간 것 | 697 |
| remote_ssh(rondo) 에서 judge 로 간 것 | 112 — 설계상 전부 judge |

microvm 697건을 모양으로 나누면:

| 모양 | 건수 | 예 |
|---|---|---|
| 모든 단계가 읽기인데 형식 때문에 judge | **171** | `cd repos/masc && git log --oneline -3` · `git show origin/main:f \| sed -n '7160,7185p'` · `bash -c "ls -la repos"` · `ls x 2>/dev/null \| head` · `gh pr view 33033 \| head -40` |
| 표 기준으로 쓰기 | 약 340 | `git fetch` 46 · `git checkout` 42 · `mkdir` 75 · `dune` 106 · `export` 62 · `git config` 27 |
| 파일 리다이렉트 | 약 150 | `… > file` |
| 치환·제어문 | 약 110 | `$(…)` · `for` · `if` |

171건은 judge 로 간 tool_execute 의 21%, microvm 것의 25% 다. keeper 가 그 답을 기다린
시간은 건당 중앙값 18초, 꼬리는 3분이다. 사용자가 "ls, find, rg, grep 이 왜 judge 를
타나" 라고 물은 것이 이 171건이다.

### 1.2 왜 이렇게 됐나

dispatcher 는 이미 스크립트를 파싱한다. `lib/exec/parser/bash_subset.mly` (Menhir)
가 `Masc_exec.Shell_ir` 로 내린다. `Simple { bin; args; env; redirects }`,
`Pipeline`, `Sequence { head; tail = (connector * t) list }`. 인자는 quote 가 풀린
`Lit`, 값이 런타임에 정해지는 `Var`, 글로브 표시가 붙은 `arg_meta.glob`. 못 다루는
구성(치환, 서브셸, heredoc, 제어문)은 `Too_complex` 로 이름 붙여 거절한다. 실행
경로는 이 IR 로 정해진다.

관측 분류기만 이 IR 을 보지 않았다. 문자열에 금지 문자가 있는지 봤다. 파서가 이미
"이 quote 는 인자 하나다", "이 파이프는 두 단계다" 라고 말해 준 것을 분류기는 다시
읽지 못했다.

## 2. 판단

- 관측 여부는 **셸이 실제로 실행할 것**을 보고 정한다. 그것을 말해 주는 것은 IR
  이고, 문자열이 아니다. dispatcher 와 분류기가 같은 파서를 보면 둘의 답이 갈리지
  않는다.
- 명령 표는 그대로다. 파서는 표에 넣을 명령을 정하지 않는다. 단계마다 나온
  `(bin, args)` 를 지금의 `classify_argv` 에 그대로 태운다.
- 파서가 "런타임에 정해진다" 고 표시한 것은 전부 judge 로 남긴다. 글로브(`*`,
  `[`, `{}`), 변수, 치환, 서브셸, heredoc. 이 자리들은 argv 가 게스트 상태에 따라
  달라지므로 표로 판정할 수 없다.
- 판정 범위(disposable guest 만, remote_ssh 는 judge)와 표 정의("파일시스템 효과
  0")는 바꾸지 않는다. `git fetch`/`clone`/`checkout`, `mkdir`, `dune build` 는
  이 RFC 뒤에도 judge 다. 그것은 별개의 정책 결정이다(§6).
- 새 상수·임계값은 없다. 지금 있는 표와 가드, 지금 있는 파서만 쓴다.

## 3. 설계

### 3.1 단계 분류

```
classify_simple { bin; args; env; redirects } =
  env = []
  && 모든 redirect 가 관측         (fd 결합 2>&1, stdin 읽기 <f, /dev/null 로 버리기)
  && 모든 arg 가 리터럴            (Lit 이고 glob 아님; Concat 은 부분이 전부 그럴 때)
  && (bin = "cd" || classify_argv (bin :: args))
```

`cd` 는 셸 자신의 단계다. 그 줄을 실행하는 셸의 디렉터리만 바꾸고 다른 것은 바꾸지
않으므로, `cd X && git log` 는 `git -C X log` 와 같은 관측이다.

리다이렉트는 `Redirect_scope` 로 본다. `Fd_to_fd`(`2>&1`)와 `File { mode = Read }`
(`< f`)는 관측이고, `Write`/`Append` 는 대상이 `/dev/null`(`Path_scope.is_discard_sink`)
일 때만 관측이다. 그 외 파일 쓰기는 효과다.

### 3.2 IR 분류

`Simple` 은 3.1. `Pipeline` 은 모든 단계가 통과해야 한다. `Sequence` 는 head 와 tail
전부가 통과해야 한다. 연결자(`&&`, `||`, `;`, 개행)는 어느 경로로든 그 명령을
실행할 수 있으므로 효과 판단에 아무 정보도 주지 않는다.

### 3.3 입구

`script` 필드는 `Shell_command_gate.decide_raw` 로 파싱한다(로그를 남기지 않는
입구. 실행하지 않은 dispatch 흔적을 남기지 않기 위해서다). `Allow { ast }` 만
분류하고 `Reject`, `Cannot_parse`, `Too_complex` 는 judge. `argv` 가 `sh -c "…"`
코스튬(`Shell_costume.of_argv`, `-c`·`-lc`·`-ec` 포함)이면 그 안의 스크립트를 같은
길로 보낸다. dispatcher 가 그 스크립트를 실행하기 때문이다. 코스튬이 아닌 argv 는
지금처럼 `classify_argv`.

`script_argv_equivalent` 와 `shell_primitive_chars`(RFC-0404 의 문자 판별)는 지운다.
남기면 "문자열이 안전한가" 를 묻는 두 번째 답이 생긴다.

### 3.4 RFC-0404 가 막은 탭 반례

`sed -e<TAB>-i s/a/b/ f`. 0404 의 공백 split 은 `-e<TAB>-i` 를 토큰 하나로 봤고,
셸은 `-e` `-i` 둘로 나눠 in-place 쓰기가 됐다. 그래서 탭을 통째로 금지했다. 파서는
탭을 셸과 같이 단어 경계로 읽으므로 `-i` 가 그대로 `sed_flag_is_in_place` 에 걸린다.
탭 금지는 필요 없어지고, `ls<TAB>-la` 는 관측이다. 0404 가 든 IFS 논거는 리터럴
단어에는 적용되지 않는다. 셸의 어휘 분할(공백·탭·개행)은 IFS 와 무관하고, IFS 는
전개 결과에만 작용하는데 전개(`Var`)는 이 RFC 가 통째로 judge 에 남긴다.

## 4. 판정 기준

1. 이틀치 기록(§1.1)의 judge 요청을 새 분류기에 다시 흘리면 microvm 171건이
   통과하고, 그 171건에 쓰기 명령·파일 리다이렉트·`git fetch/checkout/clone`·
   `gh pr merge/create/comment` 가 하나도 없다. 2026-09-05 실측: 171/697, 위험 토큰
   검색 0건(`dune`·`python3` 는 `test/dune`, `python3 %{dep:…}` 같은 경로·인자 단어).
2. `test_keeper_gate_readonly` 가 §3 의 경계를 하나씩 고정한다. 통과: quote, 파이프,
   `cd &&`, `;`, 개행, `||`, `2>&1`, `2>/dev/null`, `< f`, 탭 단어 경계, 코스튬.
   judge: 글로브 셋, 변수, 치환, 백틱, 서브셸, env 접두, `> f`, `>> f`, 파이프 안
   `tee`, `cd && git fetch`, `export`, 표 밖 명령, 스크립트 안의 `bash -c`, 탭으로
   드러나는 `sed -i`/`rg --pre`/`sort -o`/`uniq` 두 번째 피연산자, 빈 줄.
3. remote_ssh 는 같은 스크립트여도 judge 다(기존 테스트 유지).
4. 배포 뒤 이틀, judge 로 간 tool_execute 중 "모든 단계가 표 안" 인 것이 0 에
   가깝고, judge 건수가 하루 400 안팎에서 300 안팎으로 내려간다. 측정은
   `~/me/.masc/tool_calls/` 의 `disposition=deferred` 행으로 한다.

## 5. 위험과 반론

- **파서와 게스트 셸이 다르게 읽는 줄.** 파서가 `Allow` 를 준 것만 분류하고 나머지는
  judge 다. `Allow` 는 dispatcher 가 그 IR 로 실행 경로를 정한다는 뜻이라, 그 IR 이
  틀렸다면 실행도 이미 틀린 곳이다. 이 RFC 가 새 신뢰를 만들지 않는다.
- **`cd` 를 표에 넣는 것.** `cd` 는 프로그램이 아니라 셸 내장이고, 다음 단계의 cwd
  만 바꾼다. 읽기 명령은 어느 디렉터리에서도 읽기다. 게스트 밖 경로는 게스트에
  없다.
- **`< f` 와 `2>/dev/null` 을 허용하는 것.** stdin 읽기는 `cat f` 와 같은 읽기이고,
  `/dev/null` 은 정확 일치로만 본다. 다른 어떤 경로로의 쓰기도 judge 다.
- **`gh api` 가 통과하는 범위가 넓어지는 것.** 넓어지지 않는다. `gh_argv_is_read` 는
  그대로고, 지금까지 quote 때문에 못 들어오던 `--jq '…'` 인자가 인자로 읽히는
  것뿐이다. `-X`, `-f`, `--input` 은 여전히 judge.
- **171건 중 사람이 봤어야 할 것이 있었나.** 2026-09-04~05 tool_execute reject 4건은
  push, squash merge, `branch -D`, checkout+pull 이었고, 넷 다 이 RFC 뒤에도 judge
  다.

## 6. 이 RFC 가 정하지 않는 것

- 게스트 안 `git fetch/clone/checkout`, `mkdir`, `dune build` 를 관측으로 볼지.
  `/masc-work` 가 호스트 playground 마운트라 "게스트 안이니 무해" 가 성립하지 않는다.
  microvm judge 의 절반이 여기 있다. 별도 RFC.
- remote_ssh(rondo)를 disposable 로 볼 조건. 112건/이틀. 별도 RFC.
- judge 모델 자체의 지연(p50 18초). RFC-0404 §4 그대로.

## 7. 구현 순서

한 PR. RFC 커밋 뒤 구현 커밋.

1. `Keeper_gate_readonly`: §3 의 분류, 문자 판별 삭제, `.mli` 갱신
   (`classify_script` 노출).
2. `test_keeper_gate_readonly`: §4-2 의 경계.
3. PR 코멘트에 §4-1 의 재생 결과.

## 출처

- RFC-0404 (`docs/rfc/RFC-0404-observation-scripts-pass-the-readonly-argv-table.md`) §2, §5.
- `lib/exec/parser/bash_subset.mly`, `lib/exec/shell_ir.ml`, `lib/exec/redirect_scope.ml`,
  `lib/exec/command_gate/shell_command_gate.mli`.
- `~/me/.masc/tool_calls/2026-09/04.jsonl`, `05.jsonl` (2026-09-05 21:00 KST 기준),
  `~/me/.masc/audit-approvals/2026-09/04.jsonl`, `05.jsonl`.
