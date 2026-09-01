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

2026-08-25~09-01 라이브 로그(`<base-path>/.masc/tool_calls/`, 97,450 호출 / 9,179 턴):

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
(* lib/exec/sandbox_target.mli 에 runner가 있는 것과 같은 자리.
   stderr 스트리밍과 stdin redirect가 기존 runner와 같은 모양으로 필요하다. *)
type tool_runner =
  on_stdout_chunk:(string -> unit) option ->
  on_stderr_chunk:(string -> unit) option ->
  stdin_content:string option ->
  argv:string list ->          (* ["board"; "post"; "get"; "p-123"] *)
  env:string array ->
  cwd:string option ->
  Unix.process_status * string * string
```

주입 지점은 `Sandbox_target.t`의 **네 번째 variant**(가칭 `Tool`)다. 기존 세
variant(Host/Docker/Ssh) 중 Host는 runner가 없는 구조라서 "Docker/Ssh와 같은 자리"만으로는
주 트래패릭을 덮지 못한다 — 실측상 Execute의 **85.2%가 local(Host) 프로필**이다
(08-20~09-01, 27,967건 중 23,853건). variant가 되면 세 프로필 모두 같은 지점을 지난다.

`env`/`cwd`는 도구 호출 계약에 의미가 없다(도구 인자는 JSON이다). `FOO=bar masc …`
형태의 env prefix는 **거절**한다 — 무시하지 않는다. `masc … < file`의 stdin
redirect도 마찬가지로 거절한다(도구 호출이 표준 입력을 소비하지 않으므로).

### 2.2 변환 지점은 한 곳 — 예약 커맨드 `masc`

렉서/파서는 그대로다. 파서는 `masc board post get p-123`을
`Simple { bin = "masc", args = [...] }`로 만든다(지금도 그렇다).

**변환은 keeper layer의 한 지점에서만** 일어난다: Simple의 `bin`이 예약 커맨드
`masc`와 일치하면 tool_runner로 위임하고, 아니면 기존 sandbox 실행으로 간다.

이것이 문자열 분류기가 아닌 이유:

1. **닫힌 집합이다.** 예약 커맨드는 `masc` 하나이고 판정은 **bare 문자열 동등만**이다.
   `./masc`, `/usr/local/bin/masc` 같은 경로 붙은 형태는 예약이 아니라 기존 sandbox
   실행으로 남는다(`Exec_program.t`가 opaque 문자열이므로 각각 다른 bin이다).
   실측상 첫 토큰이 `masc`인 Execute 호출은 0건이므로 기존 사용을 깨뜨리지 않는다.
   셸 builtin(`if`, `while`)과 같은 문법적 사실이며, 대상 도구 이름은 코드에
   하드코딩되지 않고 그 턴의 tool registry에서 온다.
2. **한 곳에서만 판정한다.** 여러 분기에 흩뿌리는 휴리스틱이 아니라 Execute 실행
   경로의 단일한 앞문이다. `script`/`argv` 경계(#32087)가
   `Shell_costume`의 closed list로 임의 문자열→임의 프로그램을 막았던 것과 같은
   구조다.
3. **등록되지 않은 도구 이름은 에러다.** `masc unknown-tool ...`은 조용한 noop가
   아니라 설명된 실패가 된다(2.5).

### 2.3 권한 — 셸 노출이 곧 권한이 아니다

- 호출 가능한 도구 = **그 턴의 tool surface**. defer_loading/widen(#31818, #32062)과
  정합한다 — 표면에 없는 도구는 셸로도 못 쓴다. 등록을 요청하려면 기존
  `keeper_tool_search` 경로를 쓴다.
- **승인이 필요한 도구는 셸 경로에서 즉시 거절한다.** 승인 대기는 사람을 기다리는
  상태인데 tool_runner 반환 타입이 즉시값이므로, 셸 체인 안에서 기다리면
  `timeout_sec`을 태우고 체인 전체를 붙잡는다. 즉시 거절 + "이 도구는 직접 호출해야
  승인을 받을 수 있다"는 안내가 설명된 실패다. PR-1의 읽기 3종은 승인 없는 도구로만
  골랐다.
- `policy.leaves_masc` 축은 기존 도구 실행과 동일하게 적용된다. 셸을 통했다고
  우회되지 않는다.
- Path Jail: `validate_paths`는 IR 전체를 검사한다. `masc` 커맨드의 args에 파일
  경로를 받는 도구가 오면 **기존 검사를 그대로** 지난다. `masc` 자체은 예외가
  아니다.

### 2.3.1 발견 가능성 — keeper가 `masc`의 존재를 아는 경로

이 RFC 스스로의 관측("모델은 이름과 설명이 붙은 능력을 고른다")이 여기에도 적용된다.
노출 채널이 없으면 아무도 안 쓴다. 그래서 발견 가능성은 계약이다:

- **Execute 도구의 설명 문서**에 예약 커맨드 `masc`의 문법과 현재 턴 표면에서 쓸 수
  있는 도구 이름의 출처를 명시한다. 도구 설명은 이미 모델에게 매 요청 청구되는
  유일한 표면이다 — 여기에 없으면 없는 기능이다.
- 런타임 프롬프트(keeper.md)에는 넣지 않는다. 프롬프트는 실험 영역이고 발견
  계약은 도구 설명이 소유한다.

### 2.3.2 argv costume으로 감싼 표기

`sh -c "masc board list"`(argv costume)는 tool 변환을 거치지 않고 샌드박스에서
exit 127이 난다(이미지에 `masc` 바이너리가 의도적으로 없다 — Dockerfile.keeper-sandbox).
costume의 기존 재작성 조언(replace_advice) 경로가 이 표기를 직접 표기로 안내하도록
메시지를 하나 추가한다. 조용한 127이 아니라 설명된 안내다.

### 2.4 실행 — connector 규칙이 그대로 통제

`Sequence`의 평가는 `Exec_dispatch.took_the_branch`가 지배한다. tool 호출의
exit status 사상:

- 도구 실행 성공(`disposition = ok`) → exit 0
- 실패 → non-zero. `masc board comment vote … && masc tasks list`에서 앞이 실패하면
  뒤는 실행되지 않는다. 셸의 `&&`가 이미 하는 일이다.
- 미실행 도구는 **침묵이 아니라 설명된 결과**로 남는다(Anthropic parallel tool use
  문서의 `is_error` 패턴과 같은 계약).
- exit code는 2치(ok→0, 실패→non-zero)로만 둔다. 세분 코딩을 만들지 않는다 —
  stderr 문구는 사람/모델이 읽는 표시이며 **이후 어떤 코드도 문자열로 소비하지
  않는다**(그런 소비가 필요해지면 typed 결과로 올린다).

stdout: 도구 결과 JSON이 그대로 stdout으로 간다.

**파이프라인 규칙(명시적)**: PR-1에서 `masc`은 어떤 파이프라인에도 올 수 없다(거절).
PR-2에서 `masc X | jq …`를 허용할 때의 실행은 **native chain(stage별 `dispatch_simple`)
방식**이다 — Docker/Ssh의 `pipeline_runner`(전체 stage를 한 sandbox 배치로 묶는
경로, `sandbox_pipeline_specs`)에는 tool stage를 argv로 표현할 수 없으므로 그 경로와는
분리된다. 그 대가로 소비자(`jq`)는 자기 sandbox 배치대로 실행되고 `same_sandbox_target`
물리 동등성 검사의 대상에서 제외된다 — 이 제한을 인지하고 연다.

**출력 절단**: 체인 결과 전체는 Execute의 기존 출력 상한과 절단 규칙을 그대로
따른다(뒤쪽이 잘릴 수 있다). 중요한 중간 결과는 파일로 리다이렉트하는 기존 권장이
여기에도 적용된다.

**timeout·취소**: `timeout_sec`은 체인 전체에 적용된다(셸 체인과 동일하게 도구별
분배를 하지 않는다). 취소는 기존 `dispatch_simple`의 계약을 상속한다 —
`Eio.Cancel.Cancelled`는 재raise되며 도구 실행기까지 전파된다. 그 외 예외는
`WEXITED 1`로 번역된다.

### 2.5 오류 계약

- `masc <이름 없는 도구>` → exit non-zero + stderr에 "no such tool on this turn's
  surface" + 현재 표면의 근처 이름 후보. 조용한 드롭 금지.
- tool_runner가 던진 예외는 기존 `Exec_dispatch`의 구조화된 실패 결과로 번역된다
  (Sandbox_target.mli가 규정하는 예외 계약과 동일).

## 3. PoC 판정 기준

두 단계로 나눠 재는데, PR-1과 PR-2가 증명하는 것이 다르다.

**PR-1(읽기 3종) — 증명하는 것은 채택과 회귀 없음이다:**

- keeper가 자발적으로 `masc` 커맨드를 쓰는가(발견 가능성 §2.3.1의 실증 — 0회면
  노출 계약이 실패한 것이다).
- 같은 기간 disposition=failed·Gate 거절의 회귀가 없는가.
- provider 요청 수·토큰·지연은 기록하지만 통과선으로 쓰지 않는다 — 읽기 3종은
  composition 대비 우위를 증명할 수 없는 축이다(work-intake의 노드와 같은 작업도
  아니다).

**PR-2(파이프라인) — 셸이 유일한 표현인 자리를 잰다:**

- 통과선: **조건부 조립**, 즉 앞 도구의 결과로 뒤 도구의 인자를 골라야 하는
  작업(파이프라인·변수)을 셸이 composition(정적 노드 집합)이 못 하는 방식으로
  수행하는가. composition은 노드 입력이 literal·template이므로 이 자리를 못 채운다.
  이 축에서 셸 1턴 vs 개별 tool_use N턴을 비교한다.

실패 시 롤백은 tool_runner 주입을 끄는 것으로 충분하다(변환 지점이 한 곳이므로).

## 4. 기대 효과

1. 순차 결합의 **provider 왕복 절감** — 각 왕복의 지연·토큰(스키마 재청구 포함)이
   사라진다. Anthropic 37% 사례는 중간 결과를 컨텍스트에 올리지 않을 때의 수치다 —
   그 이득은 파이프라인(PR-2)이 열리는 시점부터이고, PR-1의 이득은 왕복 횟수
   그 자체다. 두 이득을 섞어 세지 않는다.
2. composition 카탈로그(작전 2)의 실행 매체가 된다 — SKILL.md가 셸 라인으로
   composition을 표현할 수 있으면 "이름 붙은 합성"과 "셸 조립"이 하나로 합쳐진다.
3. (PR-2+) 중간 결과가 컨텍스트를 오염시키지 않는다.

## 5. 단계 분할 (20k token 작업 단위)

1. **PR-1**: `Sandbox_target` 네 번째 variant + `tool_runner` 주입점 + `masc` 변환
   단일 지점(bare 동등) + exit status 사상 + 오류 계약 + **Execute 도구 설명의 발견
   계약(§2.3.1)** + costume 안내 메시지(§2.3.2). 대상 도구는 승인 불필요 읽기
   3종(`masc board post get`, `masc board list`, `masc time now`)으로 좁힌다.
   파이프라인 안 `masc`는 거절. PoC 측정(§3 PR-1 축: 채택 + 회귀 없음).
2. **PR-2**: native chain 파이프라인(§2.4 규칙), 도구 폭 확장(tasks/memory), stdout
   JSON 계약 고정, 조건부 조립 PoC(§3 PR-2 축).
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
