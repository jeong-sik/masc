---
rfc: "tools-as-shell-commands"
title: "도구를 셸 first-class 커맨드로 — 순차 결합의 provider 왕복을 없앤다"
status: Draft
created: 2026-09-01
updated: 2026-09-01
author: claude
supersedes: []
superseded_by: null
related: ["0391", "execute-boundary-is-the-sandbox", "skills-as-tools", "attached-service-tool-scoping"]
implementation_prs: []
---

# RFC: 도구를 셸 first-class 커맨드로 (tools-as-shell-commands)

## 0. Summary

Keeper가 셸 한 줄에서 masc 도구를 부를 수 있게 한다.

```
masc board post get p-123; masc tasks list --status claimed; masc memory search "lane"
```

도구 A의 결과를 도구 B에 쓰는 순차 결합이 provider 왕복 없이, 이미 Keeper가 아는 형태(셸)로
표현된다. 실행은 Shell IR의 connector(`;`, `&&`, `||`)와 기존 게이트가 그대로 통제한다.

## 1. 배경 및 문제

### 1.1 순차 결합의 병목은 provider 왕복이다 (실측)

2026-08-25~09-01 라이브 로그(`~/me/.masc/tool_calls/`, 97,450 호출 / 9,179 턴):

- 한 assistant 메시지에 복수 `tool_use`를 묶은 호출(batch_size≥2)은 **11.8%** 뿐이다.
  나머지 88%는 한 번에 하나씩 발행한다. 도구 A 결과를 보고 다음 요청에서 B를 부르는
  왕복이 순차 결합의 전부다.
- 평균 10.6 호출/턴, 61+ 호출 턴이 210개. 왕복 1회마다 provider 지연·토큰이 청구된다.

### 1.2 업계가 같은 결론에 도달했다

- Anthropic programmatic tool calling: 코드 실행 안에서 도구를 직접 호출. 평균 토큰
  **43,588→27,297 (37% 감소)**, 도구 20회 호출 시 **추론 패스 19+개 제거**. 중간 결과는
  컨텍스트를 통과하지 않는다. (Anthropic Engineering, "Introducing advanced tool use")
- CodeAct (Wang et al., ICML 2024): JSON tool-call 대비 최대 **+20% success rate**.
- LLMCompiler (ICML 2024): 모델은 계획을 쓰고 병렬/순차 스케줄은 하네스가 결정할 때
  latency 최대 3.7x 단축. 범용 "조립 문법"을 모델에게 노출한 것과 대조된다.

### 1.3 masc의 반대 교훈

범용 조립 문법(`keeper_plan_execute`, assembler/plan-DAG)은 3일 2,675턴 **0회 호출**로
삭제됐다 (#31617). 살아남은 건 이름 붙은 합성 `keeper_compose_<name>`뿐이다. 관측:
**모델은 문법이 아니라 이름과 설명이 붙은 능력을 고른다.** 셸은 Keeper가 이미 아는
매체다 — 새 문법을 만들지 않는다.

## 2. 핵심 설계

### 2.1 계층 — Sandbox_target 패턴을 따른다

`lib/exec`는 제품 독립을 유지한다(`sandbox_target.mli`의 기존 원칙). 도구 실행은
Docker/Ssh runner와 같은 방식으로 **keeper layer가 클로저로 주입**한다.

```ocaml
(* lib/exec/sandbox_target.mli 에 runner가 있는 것과 같은 자리 *)
type tool_runner =
  on_stdout_chunk:(string -> unit) option ->
  argv:string list ->          (* ["board"; "post"; "get"; "p-123"] *)
  env:string array ->
  cwd:string option ->
  Unix.process_status * string * string
```

`Shell_ir.simple`의 실행 결정은 이미 `sandbox : Sandbox_target.t`가 데이터로 들고
있다. tool 호출은 이 자리의 확장이지 새 경로가 아니다.

### 2.2 변환 지점은 한 곳 — 예약 커맨드 `masc`

렉서/파서는 그대로다. 파서는 `masc board post get p-123`을
`Simple { bin = "masc", args = [...] }`로 만든다(지금도 그렇다).

**변환은 keeper layer의 한 지점에서만** 일어난다: Simple의 `bin`이 예약 커맨드
`masc`와 일치하면 tool_runner로 위임하고, 아니면 기존 sandbox 실행으로 간다.

이것이 문자열 분류기가 아닌 이유:

1. **닫힌 집합이다.** 예약 커맨드는 `masc` 하나. 셸 builtin(`if`, `while`)과 같은
   문법적 사실이며, 대상 도구 이름은 코드에 하드코딩되지 않고 그 턴의 tool
   registry에서 온다.
2. **한 곳에서만 판정한다.** 여러 분기에 흩뿌리는 휴리스틱이 아니라 Execute 실행
   경로의 단일 문(desingle gate front-door)이다. `script`/`argv` 경계(#32087)가
   `Shell_costume`의 closed list로 임의 문자열→임의 프로그램을 막았던 것과 같은
   구조다.
3. **등록되지 않은 도구 이름은 에러다.** `masc unknown-tool ...`은 조용한 noop가
   아니라 설명된 실패가 된다(2.5).

### 2.3 권한 — 셸 노출이 곧 권한이 아니다

- 호출 가능한 도구 = **그 턴의 tool surface**. defer_loading/widen(#31818, #32062)과
  정합한다 — 표면에 없는 도구는 셸로도 못 쓴다. 등록을 요청하려면 기존
  `keeper_tool_search` 경로를 쓴다.
- 승인 정책·`policy.leaves_masc` 축은 기존 도구 실행과 동일하게 적용된다. 셸을
  통했다고 우회되지 않는다.
- Path Jail은 `masc` 커맨드에는 적용 대상이 없다(파일을 열지 않는다). 파일을 여는
  도구(board의 artifact 등)는 도구 실행기의 기존 경로 검증을 그대로 지난다.

### 2.4 실행 — connector 규칙이 그대로 통제

`Sequence`의 평가는 `Exec_dispatch.took_the_branch`가 지배한다. tool 호출의
exit status 사상:

- 도구 실행 성공(`disposition = ok`) → exit 0
- 실패 → non-zero. `masc board comment vote … && masc tasks list`에서 앞이 실패하면
  뒤는 실행되지 않는다. 셸의 `&&`가 이미 하는 일이다.
- 미실행 도구는 **침묵이 아니라 설명된 결과**로 남는다(Anthropic parallel tool use
  문서의 `is_error` 패턴과 같은 계약).

stdout: 도구 결과 JSON이 그대로 stdout으로 간다. `masc board list | jq '.[0]'` 같은
파이프라인 연결은 2단계(§5)에서 허용하고, 1단계에서 `masc`은 파이프라인의
source(head) 위치로 제한한다 — 파이프라인의 소비자 쪽에서 셸 명령과 섞이는
경계부터 열겠다는 뜻이다.

### 2.5 오류 계약

- `masc <이름 없는 도구>` → exit non-zero + stderr에 "no such tool on this turn's
  surface" + 현재 표면의 근처 이름 후보. 조용한 드롭 금지.
- tool_runner가 던진 예외는 기존 `Exec_dispatch`의 구조화된 실패 결과로 번역된다
  (Sandbox_target.mli가 규정하는 예외 계약과 동일).

## 3. PoC 판정 기준

Keeper 1명(rondo 권장 — board 폴링 다용)에서 관찰 폴링 3종을 셸 한 줄로 대체:

- **측정 축**: (a) 같은 정보 수집에 든 provider 요청 수, (b) tool-schema를 뺀
  입출력 토큰, (c) 벽시계 지연.
- **통과선**: `keeper_compose_work-intake`(3노드 composition, 7일 281호출) 대비
  동등 이상. composition은 이미 이 문제의 한 답이므로, 셸 경로가 적어도 지지 않으면
  기각한다.
- 실패 시.Rollback은 tool_runner 주입을 끄는 것으로 충분하다(변환 지점이 한 곳이므로).

## 4. 기대 효과

1. 순차 결합의 provider 왕복 제거 — 관찰 폴링(작전 3의 전제)과 곱해진다.
2. composition 카탈로그(작전 2)의 실행 매체가 된다 — SKILL.md가 셸 라인으로
   composition을 표현할 수 있으면 "이름 붙은 합성"과 "셸 조립"이 하나로 합쳐진다.
3. 중간 결과가 컨텍스트를 오염시키지 않는다(37% 절감 사례와 같은 메커니즘).

## 5. 단계 분할 (20k token 작업 단위)

1. **PR-1**: `tool_runner` 주입점 + `masc` 변환 단일 지점 + exit status 사상 +
   오류 계약. 대상 도구는 읽기 3종(`masc board post get`, `masc board list`,
   `masc time now`)으로 좁힌다. PoC 측정.
2. **PR-2**: 파이프라인 source 허용, 도구 폭 확장(tasks/memory), stdout JSON
   계약 고정.
3. **PR-3**: composition 정의 언어의 셸 라인 표현(작전 2와 접점).

## 6. 반론과 답

- **"범용 문법이 0호출이었는데 왜 셸은 다른가?"** — 범용 문법은 새 DSL이었다. 셸은
  Keeper가 매 턴 이미 쓰는 매체다(Execute 13,375호출, 최상위 도구). 학습 비용이
  없는 방향으로만 문을 연다.
- **"문자열 매칭 아니냐?"** — §2.2. 닫힌 집합, 단일 판정 지점, registry 기반.
  `Shell_costume` closed list가 이미 세운 구조를 따른다.
- **"도구 결과가 셸 출력에 섞이면 가시성이 깎이지 않냐?"** — tool_calls 기록은
  도구 실행기에서 그대로 남는다(경유로 호출해도 도구 실행은 같은 실행기를 지난다).
  셸 라인 전체는 기존 Execute 호출 기록으로 남는다.

## 7. 근거 데이터

- 내부 실측: `.tmp/toolstudy/masc-gap.md` (2026-08-25~09-01, tool_calls 97,450건)
- 외부: `.tmp/toolstudy/survey-products.md` §1(b), `survey-research.md` §1·§3
- 백로그: issue #32369
