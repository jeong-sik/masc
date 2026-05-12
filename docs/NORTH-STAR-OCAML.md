# OCaml 북극성 지표 (North Star Guideline)

> masc-mcp + OAS 코드베이스의 OCaml 품질 기준.
> 측정 가능하고, ROI가 높고, 학문적으로 올바른 개선 항목.
> 생성일: 2026-04-21 · §1 스냅샷 갱신: 2026-05-12

---

## 1. 현재 상태 (실측값)

> ⚠️ §1·§5 의 수치는 측정 시점 스냅샷이다. masc-mcp 열은 2026-05-12 에 일부
> 행을 재측정했다 — `find lib -name '*.ml'` 기준으로 코드베이스가 698 → 1033
> `.ml` 파일로 커졌고 `.mli` 커버리지는 같은 기간에 53% → 97% 로 올랐다.
> "(2026-04, 재측정 필요)" 표시된 행은 2026-04-21 측정값 그대로다.

| 축 | masc-mcp | OAS | 평가 |
|----|----------|-----|------|
| `.mli` 커버리지 | 1005/1033 (97%, 2026-05-12) | 216/218 (99%) | Tier 1-A 사실상 완료 |
| `Obj.magic` (실사용) | 0건 (2026-05-12; `cdal/adversarial_eval.ml` 의 1건은 금지패턴 문자열 리터럴) | 0건 | 깨끗함 |
| `Stdlib.Mutex` 생성 | `Stdlib.Mutex.create` 39 호출 / `module Mutex = Stdlib.Mutex` 105 파일 (2026-05-12) — 다수는 의도된 컨벤션 (`prometheus.ml` 등 짧은 critical section, Eio 의존 회피 주석 명시) | 2군데 | 무분별 신규 추가만 경계 |
| `Eio.Mutex` 사용 | 112 파일 (2026-05-12) | 19군데 | 과잉 여부 재평가 필요 |
| 와일드카드 `_` (Top 파일) | (2026-04, 재측정 필요) keeper_status_detail: 35, verification: 28 | runtime_server: 25 | RFC-0071 §3.4 (warning 4 활성화) 이 진행 중 — §2-B/§3 참조 |
| GADT | (2026-04) 2군데+ | 5군데 | 미활용 |
| Effect Handlers | 0건 (2026-05-12; `Effect.perform`/`Effect.Deep`/`Effect.Shallow` 0건 — Eio 내부 사용 제외) | 0건 | **공백** |
| First-class modules | (2026-04) 10군데 | 미측정 | 보통 |
| Functor (Make) | (2026-04) 10+ (masc_log) | 2군데 | 보통 |
| Result 사용 파일 | (2026-04) 50개 | 42개 | 양호 |
| Error() 총 호출 | (2026-04, 재측정 필요) 799건 | 363건 | 과도 |
| Polymorphic variants | (2026-04) test 파일 한정 | 미측정 | 미활용 |

---

## 2. 개선 항목 (ROI 순)

### Tier 1: 즉시 개선 (ROI 극높음)

#### A. `.mli` 커버리지 53% → 90%+ — ✅ 사실상 완료 (2026-05-12 기준 97%, 1005/1033)

> 2026-04-21 당시 53% (370/698). 이후 대규모 `.mli` 추가로 2026-05-12 기준 97%
> (1005/1033). 남은 ~28 파일은 아래 타겟 명령으로 확인. 신규 `.ml` 은 `.mli`
> 동반이 기본 관습.

**문제**: 모듈 경계가 없으면:
- AI 코드 생성 시 private 함수를 외부에서 호출 (컴파일러가 못 잡음)
- 리팩토링 시 영향 범위 파악 불가
- 순환 의존성 은닉

**근거**: OCaml 매뉴얼 2장 "The module system" — `.mli`는 계약(contract)이고 `.ml`은 구현. 계약 없는 구현은 구조적 부채.

**실행**: 남은 파일 — `for f in lib/**/*.ml; do [ ! -f "${f%.ml}.mli" ] && echo "$f"; done`

#### B. 와일드카드 `_` 패턴 — 정밀 분류 후 위험 건만 교체

> ⚠️ 아래 Cat 1/2/3 수치와 `keeper_unified_turn.ml:NNN` 라인 번호는 2026-04
> 측정 기준이다 (해당 파일은 현재 3037 줄). 그 후:
> - `keeper_unified_turn.ml` 의 `_ -> Post_commit_failure` / `_ -> "text_turn"`
>   fallback 은 현재 코드에 부재 — `turn_mode_of_result` 는 `Keeper_unified_metrics`
>   로 이동, `work_kind` 는 dashboard/timeline projection 에서만 계산 (RFC-0070/0072
>   turn_phase typed dispatch, #14918 등). §3-A/§3-B 의 "수정안" 은 적용된 것으로 판단.
> - RFC-0071 §3.4 가 warning 4 (fragile pattern matching) 활성화를 모듈 단위로
>   진행 중 (`feat(...): enable warning 4 + close N fragile sites`). 미해소 Cat 3
>   잔량은 그 트랙의 진행 상황으로 재측정할 것.
> - `dashboard_utils.ml` 의 `_ -> HL_unknown` (string→enum) 류는 여전히 합리적.

**실측** (masc-mcp `lib/` 전체, 2026-04):
- Cat 1 (JSON decode): 1,405건 — `Yojson` 파싱의 `| _ -> None/Error`. **합리적** (open-world JSON)
- Cat 2 (HTTP/status): 436건 — HTTP 응답 코드 매칭. **부분 합리적**
- Cat 3 (variant fallback): 912건 — `variant -> variant` 매핑의 `_ -> default` 가 위험군

**판단 기준**:
- `string -> enum` 변환의 `_ -> Unknown` variant: 합리적 (open world)
- `variant -> variant` 매핑의 `_ -> default`: **위험** (closed world, 컴파일러 경고 상실)
- `unit -> unit` 무시: 맥락 확인 필요

**실행**: Cat 3 중 `variant -> variant` 매핑만 우선 교체. 예상 ~100건.

#### C. Stdlib.Mutex 정리
**문제**: Eio 컨텍스트 내부에서 `Stdlib.Mutex` 사용 시:
- Eio fiber가 yield하면서 다른 fiber가 같은 스케줄러에서 대기 → 성능 저하
- 잠재적 dead-lock (feedback: `ocaml5-mutex-selection`)

**현재 올바른 사용** (cross-domain/non-Eio):
- `prometheus.ml`: HTTP stats endpoint, Eio 밖에서 호출 가능 (OK)
- `a2a_tools.ml`: UUID RNG, non-yielding (OK)
- `process_eio.ml`: Unix.getcwd, non-yielding C call (OK)

**의심스러운 사용** (검토 필요):
- `server_dashboard_http_runtime_info.ml`: 7개 mutex lock/unlock, Eio fiber 안에서
- `worktree_live_context.ml`: Eio 환경에서 git 작업
- `auto_responder.ml`: 응답 시간 기록

**실행**: `Stdlib.Mutex.lock` -> `Eio.Mutex.use_ro`/`Eio.Mutex.protect` 전환. 단, non-yielding critical section이면 현행 유지 (주석으로 근거 명시).

---

### Tier 2: 중기 개선 (ROI 높음)

#### D. Effect Handlers 도입
**문제**: OCaml 5.x의 핵심 기능인 algebraic effects를 두 코드베이스 모두 0건 사용.

**적용 후보**:
1. **로깅/telemetry**: 현재 전역 mutable state + mutex. Effect로 투명하게 전환 가능
2. **설정/config 읽기**: 현재 `ctx.config`를 모든 함수에 명시적 전달. Reader effect로 제거
3. **에이전트 컨텍스트**: `ctx.agent_name` 등을 effect로 관리
4. **인가/권한 체크**: 현재 명시적 callback. Effect로 선언적 전환

**근거**: OCaml 5.0 changelog — "Effect handlers let you implement: cooperative threading, async I/O, loggers, dependency injection, without monad transformers."

**위험**: Effect는 성숙도가 진행 중. `Effect.Deep.try_with`는 신중히 사용.

**실행**: 작은 pilot에서 시작 — 로깅 effect 하나만 도입 후 관찰.

#### E. GADT 확대 적용
**현재**: masc-mcp 2건 (`typed_state.ml`), OAS 5건.

**적용 후보**:
1. **툴 스키마**: `string * string` 튜플 대신 타입 수준에서 입력/출력 타입 강제
2. **이벤트 타입**: keeper 이벤트를 GADT로 typed state machine 구현
3. **검증 프로토콜**: `AwaitingVerification` 상태를 타입 수준에서 표현 (불가능한 상태를 표현 불가능하게)

**근거**: "Make illegal states unrepresentable" — GADT의 핵심 가치. TLA+ 검증의 타입 수준 버전.

#### F. Labelled Tuples (OCaml 5.4)
**문제**: 현재 `type t = string * int * bool` 형태의 unnamed tuple이 다수.

**OCaml 5.4 기능**: `type t = ~name:string * ~age:int * ~active:bool`
- tuple 필드에 이름 부여
- 패턴 매칭 시 `~name:n` 형태로 명시적 바인딩
- 기존 tuple과 호환

**실행**: dune-project에 `(lang dune 3.22)` + `(ocaml 5.4)` 이미 설정됨. 새 타입 정의부터 labelled tuple 사용.

---

### Tier 3: 장기 개선 (ROI 보통)

#### G. Immutable Arrays (`'a iarray`)
OCaml 5.4 추가. `Array` 대신 불변 배열로 성능+안전성.

#### H. `[@atomic]` Record Fields
OCaml 5.4의 `Atomic.Loc` 기반. 현재 `Atomic.make`/`Atomic.get`/`Atomic.set` 패턴을 record field 수준에서 통합.

#### I. `Result.Syntax` (let* + let+)
OCaml 5.4 공식 바인딩. 현재 커스텀 `let*!` 패턴을 표준으로 통일.

#### J. Polymorphic Variants
현재 거의 사용 안 함. closed variant가 대부분인데, 확장 가능한 variant가 필요한 곳(이벤트 타입, 툴 타입)에 검토.

#### K. `Stdlib.Pqueue` (우선순위 큐)
OCaml 5.4 추가. 현재 keeper 우선순위 관리를 `List.sort`로 구현한 곳에 적용.

---

## 3. 구체적 코드 수정안 (Tier 1 상세)

> ⚠️ 3A / 3B 는 적용된 것으로 보인다 (2026-05-12 확인): `keeper_unified_turn.ml` 에
> `_ -> "text_turn"` / `_ -> Post_commit_failure` fallback 부재, `turn_mode_of_result`
> 는 `Keeper_unified_metrics` 모듈, `work_kind` 는 dashboard/timeline projection 에서만
> 계산 (RFC-0070/0072 turn_phase typed dispatch). 인용된 line 번호 (220 / 750-761 / 1519)
> 는 2026-04 기준이며 현재 파일은 3037 줄 — **라인 번호 신뢰 금지, 심볼명으로 찾을 것**.
> 아래 내용은 당시 분석 기록으로 남긴다. 3C / 3D 는 미확인.

### 3A. String-typed enum → variant 타입 (keeper_unified_metrics.ml) — ✅ 적용된 것으로 판단

**현재** (line 750-761):
```ocaml
type turn_mode =
  | Tool_use
  | Noop
  | Skip_text
  | Text_response

let turn_mode_of_result (result : Keeper_agent_run.run_result) : turn_mode =
  (* ...returns Tool_use | Noop | Skip_text | Text_response *)

let work_kind_of_turn_mode = function
  | Tool_use -> "tool_use"
  | Noop -> "noop"
  | Skip_text -> "text_turn"
  | Text_response -> "text_turn"
```

**문제**: `selected_mode`와 `work_kind`가 string이면 새 모드 추가 시 컴파일러가 완전성 검사를 못 한다.
`_ -> "text_turn"` 같은 fallback은 unknown 입력을 text 계열로 은밀히 분류한다.

**수정 결과**:
- core/durable surface는 `turn_mode`만 저장
- `work_kind`는 dashboard/timeline projection에서만 계산
- future variant 추가 시 exhaustive match가 깨져서 컴파일 단계에서 바로 드러남

### 3B. post_commit_failure_kind_of_error — 재분류 — ✅ `_ -> Post_commit_failure` 부재 (2026-05-12 확인)

**(2026-04 당시) 현재**:
```ocaml
let post_commit_failure_kind_of_error (err : Oas.Error.sdk_error) =
  match err with
  | Oas.Error.Api (Timeout _) -> Keeper_registry.Post_commit_timeout
  | _ -> Keeper_registry.Post_commit_failure
```

**분석**: `Oas.Error.sdk_error`의 변형은 Api/Agent/Internal/Config/MaxTurnsExceeded/TokenBudgetExceeded/ExitConditionMet/UnrecognizedStopReason.
Timeout vs 나머지 구분이 실제로 유의미하므로, 이 wildcard는 **합리적**으로 판단.
다만 명시적 분류로 변경하면 문서화 가치 증가:

```ocaml
let post_commit_failure_kind_of_error = function
  | Oas.Error.Api (Timeout _) -> Post_commit_timeout
  | Oas.Error.Api _ | Oas.Error.Agent _ | Oas.Error.Internal _
  | Oas.Error.Config _ | Oas.Error.InvalidConfig _
  | Oas.Error.MaxTurnsExceeded | Oas.Error.TokenBudgetExceeded
  | Oas.Error.ExitConditionMet | Oas.Error.UnrecognizedStopReason ->
      Post_commit_failure
```

**ROI**: 낮음. OAS가 변형을 추가할 때만 이점. 문서화 목적이면 OK, 아니면 현행 유지.

### 3C. server_dashboard_http_runtime_info.ml — Mutex 전환

**현재**: Eio fiber 안에서 `Stdlib.Mutex.lock/unlock` 7회 호출.

**수정안**:
```ocaml
(* Before *)
Stdlib.Mutex.lock cache_mu;
let result = compute_expensiveThing () in
Stdlib.Mutex.unlock cache_mu;
result

(* After *)
Eio.Mutex.use_rw ~protect:true cache_mu (fun () ->
  compute_expensive_thing ()
)
```

**주의**: `use_rw` 내부에서 Eio fiber가 yield 가능. critical section이 non-yielding C call만 포함하면
현행 유지 + 근거 주석 추가.

**ROI**: 높음. 7군데 lock/unlock이 Eio fiber context에서 동작하므로 잠재적 dead-lock 위험 제거.

### 3D. `match handoff_json with ... | _ -> ()` (line 1519)

**현재**:
```ocaml
match handoff_json with
| Some ((`Assoc _ as handoff)) ->
    (* ... broadcast handoff SSE ... *)
| _ -> ()
```

**분석**: `handoff_json : Yojson.Safe.t option`. `None` → broadcast 불필요, `Some (`List _)` 등 → 무시.
JSON 구조가 `Assoc`이 아니면 무시하는 것이 올바른 동작. **합리적**. 수정 불필요.

---

## 4. 금지 패턴 (Anti-patterns)

| 패턴 | 이유 | 대안 |
|------|------|------|
| `Obj.magic` | 타입 시스템 우회 | 올바른 타입 설계 |
| `\| _ -> default_value` | unknown 허용 | exhaustive match |
| Eio 안에서 `Stdlib.Mutex` | dead-lock 위험 | `Eio.Mutex` |
| `Stdlib.Lazy.force` (Eio) | cross-domain 불안정 | `Eio.Lazy.from_fun` |
| mutable record field 과다 | 상태 추적 어려움 | `Atomic` 또는 immutable + snapshot |
| `Hashtbl` + `Mutex` | 직접 구현 | `Eio.Mutex` + immutable map |

---

## 5. 측정 지표 (정량)

> "기준" 열: `(2026-04)` 표시 없으면 2026-05-12 재측정값. 목표 열은 2026-04-21
> 작성 시점 기준 (3개월) — `.mli` 는 이미 초과 달성.

| 지표 | 기준 | 목표 (3개월) | 측정 방법 |
|------|------|-------------|----------|
| `.mli` 커버리지 | 97% (1005/1033, 2026-05-12) ✅ | 85% | `find lib -name '*.mli' \| wc -l` ÷ `find lib -name '*.ml' \| wc -l` |
| 와일드카드 `_` (variant→variant) | (2026-04) ~100 | <20 | RFC-0071 §3.4 warning 4 활성화 트랙으로 추적 |
| `Stdlib.Mutex` (Eio fiber 안에서 yielding) | 재측정 필요 (2026-05-12: `create` 39 / alias 105 — 대부분 의도된 non-yielding) | <5 (yielding 한정) | 수동 검토 — 단순 카운트는 의도된 컨벤션과 위험 사용을 구분 못 함 |
| `Obj.magic` (실사용) | 0 (2026-05-12) | 0 | `rg 'Obj\.magic' lib/` 후 문자열 리터럴 제외 |
| Effect handler 사용 | 0 (2026-05-12) | 1-2 pilot | `rg 'Effect\.(perform\|Deep\|Shallow)' lib/` |
| GADT 타입 | (2026-04) ~2+ | 12+ | 수동 (`type _ t = ... : ... -> _ t` 구문) |
| Labelled tuple (5.4) | (2026-04) 0 | 신규 타입에 적용 | 수동 |

---

## 6. 참고 자료

- OCaml 5.4 Changelog: https://ocaml.org/releases/5.4.0
- OCaml Manual 5.4: https://ocaml.org/manual/5.4/
- Alexis King "Parse, Don't Validate": https://lexi-lambda.github.io/blog/2019/11/05/parse-don-t-validate/
- Eio Mutex 선택 가이드: ~/me/memory/feedback_ocaml5-mutex-selection.md
- AI 코드 안티패턴: ~/me/instructions/software-development.md
- Flambda 2 (ICFP 2023): 추상화 비용 감소 — functor/고차함수 신뢰, 작은 closure 유지, `[@inline]` 힌트 활용
- Retrofitting Effect Handlers (arXiv 2411.19397): OCaml 5.x effect 설계 논문
- Tail Modulo Cons (POPL 2025): OCaml 5.4의 자동 tail-recursion 변환. 리스트 빌딩 함수의 수동 최적화 불필요
- OCaml Memory Model — Local DRF (PLDI 2018, Dolan et al.): data race의 공간적/시간적 제한. `Gc.ramp_up` + `[@atomic]` 근거
- Flambda 2 (ICFP 2023,.chaudhuri et al.): inline 중심 최적화. functor/고차함수 추상화 비용 감소

---

## 7. 학문적 근거에 의한 코딩 가이드라인

### Flambda 2 인사이트 (ICFP 2023 + OCaml Workshop 2023)

**핵심**: Flambda 2는 추상화 비용을 획기적으로 감소시킴. "깔끔한 코드 vs 빠른 코드" 딜레마가 완화.

| 원칙 | 실천 |
|------|------|
| 작은 함수에 `[@inline]` 힌트 | hot-path의 small function에 적용 |
| Local exception으로 early exit | `raise_notrace` + local exn → direct jump |
| Closure capture 최소화 | 많은 free variable보다 명시적 parameter |
| Functor/고차함수 신뢰 | 과도한 수동 inline 대신 깔끔한 추상화 |
| Variant→variant 직접 match | 중간 할당 최적화됨 (3B의 수정안과 일치) |

### Effect Handlers 실천 가이드 (arXiv 2411.19397 기준)

**안전한 도입 경로**:
1. `Effect.Deep.try_with`로 감싸진 scope에서만 사용
2. effect는 shallow handler로 정의 (성능상 유리)
3. fiber cancellation과의 상호작용 주의 — `Eio.Cancel.Cancelled`는 effect handler 바깥에서 처리
4. pilot: 로깅 effect → `Perform Log.message "..."` → handler에서 `Eio.traceln` 분기

### Tail Modulo Cons (TMC) 인사이트 (POPL 2025)

**핵심**: OCaml 5.4의 TMC는 컴파일러가 재귀적 리스트 빌딩 함수(`map`, `filter`, `rev_append`)를
자동으로 tail-recursion으로 변환. 개발자가 수동 accumulator를 도입할 필요 없음.

**실천**:
1. **TMC-awareness**: `rev_append`/`map` 패턴에 수동 accumulator 최적화 금지. 컴파일러가 처리.
2. **`[@tail_mod_cons]` annotation**: 명시적 TMC 요청 시 사용. 단 대부분은 자동 적용.
3. **과도한 최적화 제거**: 기존 수동 tail-recursion 코드를 간결한 재귀로 되돌릴 수 있음 (가독성↑)
4. **주의**: TMC는 `let rec` + cons(`::`) 또는 `List.rev_append` 패턴에만 동작. 다른 패턴은 기존 방식 유지.

**근거**: "Tail Modulo Cons for Everyone" (Guillemette et al., POPL 2025) — OCaml 5.4에 통합된
컴파일러 패스. 리스트 처리 코드의 stack overflow 위험을 컴파일러가 자동 제거.

### OCaml Memory Model — Local DRF (PLDI 2018)

**핵심**: OCaml 5.x 멀티도메인 메모리 모델은 "Local DRF" (Data-Race-Free locally).
data race가 없으면 sequential consistency 보장. data race가 있어도 효과가 공간적/시간적으로 제한됨.

**실천 (masc-mcp + OAS에 직접 적용)**:
1. **`Atomic` 사용 규칙**: cross-domain 공유 변수는 반드시 `Atomic.t`로 감싸거나 `Stdlib.Mutex`로 보호.
   현재 코드의 `Atomic.make`/`Atomic.get`/`Atomic.set` 패턴은 올바름.
2. **`Eio.Mutex`는 same-domain용**: cross-domain 공유에는 `Stdlib.Mutex` 필요 (feedback memory 참조).
3. **Non-atomic ref의 domain 격리**: `ref`가 단일 domain에서만 접근되면 안전. multi-domain 접근 시 `Atomic` 필수.
4. **`Gc.ramp_up ()` 호출**: 서버 시작 시 `Gc.ramp_up ()`를 호출하여 GC가 모든 domain의 allocation budget을
   사전 할당. domain 간 GC 병목 감소. **masc-mcp `masc_mcp.ml`의 서버 초기화에 추가 권장 (1줄).**

**근거**: "Retrofitting Parallelism onto OCaml" (Dolan et al., PLDI 2018) —
OCaml 5.x의 메모리 모델 설계 논문. semantic race의 효과를 공간적으로 1개 값, 시간적으로 1회로 제한.

### OCaml 5.4 실전 기능 우선순위 (학문적 근거)

**즉시 적용 (1-2줄 수정)**:

| 기능 | 위치 | 수정량 | 근거 |
|------|------|--------|------|
| `Gc.ramp_up ()` | `masc_mcp.ml` 서버 초기화 | 1줄 | PLDI 2018: multi-domain GC 사전 할당 |
| `[@atomic]` record field | cross-domain 상태 record | 필드당 1 attribute | Local DRF: 명시적 atomic 보장 |

**`[@atomic]` 우선 적용 대상** (cross-domain 공유 record):

```ocaml
(* Before *)
type keeper_stats = {
  mutable total_turns : int;
  mutable total_errors : int;
  mutable last_active : float;
}

(* After — OCaml 5.4 *)
type keeper_stats = {
  [@atomic] total_turns : int;
  [@atomic] total_errors : int;
  [@atomic] last_active : float;
}
```

**적용 순서**: `keeper_stats` → `room_state` → `agent_state`. 현재 `Atomic.make`/`Atomic.get`/`Atomic.set`
패턴을 `[@atomic]` record field로 점진 전환. 단, OCaml 5.4 컴파일 필요.

**`Iarray` (불변 배열) 적용 대상**:

```ocaml
(* Before — config array that never mutates *)
let tool_presets = [| "minimal"; "social"; "messaging"; "coding"; "research"; "delivery"; "full" |]

(* After — OCaml 5.4 *)
let tool_presets : string Iarray.t = Iarray.of_array [| "minimal"; "social"; "messaging"; "coding"; "research"; "delivery"; "full" |]
```

적용: config 상수, tool preset, priority level 등 초기화 후 변경 없는 배열. `Array.copy` 방어 코드 제거 가능.
