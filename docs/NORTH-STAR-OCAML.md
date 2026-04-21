# OCaml 북극성 지표 (North Star Guideline)

> masc-mcp + OAS 코드베이스의 OCaml 품질 기준.
> 측정 가능하고, ROI가 높고, 학문적으로 올바른 개선 항목.
> 생성일: 2026-04-21

---

## 1. 현재 상태 (실측값)

| 축 | masc-mcp | OAS | 평가 |
|----|----------|-----|------|
| `.mli` 커버리지 | 370/698 (53%) | 216/218 (99%) | masc-mcp 심각 |
| `Obj.magic` | 0건 | 3건 (cdal/) | OAS 정밀 |
| `Stdlib.Mutex` 생성 | 13군데 | 2군데 | masc-mcp 과도 |
| `Eio.Mutex` 사용 | 88군데 | 19군데 | masc-mcp 과잉 |
| 와일드카드 `_` (Top 파일) | keeper_status_detail: 35, verification: 28 | runtime_server: 25 | 둘 다 과도 |
| GADT | 2군데 | 5군데 | 미활용 |
| Effect Handlers | 0건 | 0건 | **공백** |
| First-class modules | 10군데 | 미측정 | 보통 |
| Functor (Make) | 10+ (masc_log) | 2군데 | 보통 |
| Result 사용 파일 | 50개 | 42개 | 양호 |
| Error() 총 호출 | 799건 | 363건 | masc-mcp 과도 |
| Polymorphic variants | test 파일 한정 | 미측정 | 미활용 |

---

## 2. 개선 항목 (ROI 순)

### Tier 1: 즉시 개선 (ROI 극높음)

#### A. `.mli` 커버리지 53% → 90%+
**문제**: masc-mcp 328개 `.ml` 파일에 `.mli` 없음. 모듈 경계가 없으면:
- AI 코드 생성 시 private 함수를 외부에서 호출 (컴파일러가 못 잡음)
- 리팩토링 시 영향 범위 파악 불가
- 순환 의존성 은닉

**근거**: OCaml 매뉴얼 2장 "The module system" — `.mli`는 계약(contract)이고 `.ml`은 구현. 계약 없는 구현은 구조적 부채.

**실행**: 우선순위 — `lib/types/`, `lib/coord/`, `lib/keeper/` 순.
타겟: `for f in lib/**/*.ml; do [ ! -f "${f%.ml}.mli" ] && echo "$f"; done`

#### B. 와일드카드 `_` 패턴 799건 → exhaustive match
**문제**: `| _ ->`가 unknown 입력을 조용히 삼킴. AI 코드 생성의 대표적 안티패턴 (feedback 기록: "Unknown → Permissive Default").

**실측 핫스팟** (masc-mcp):
- `keeper_status_detail.ml`: 35건
- `verification.ml`: 28건
- `operator_control_snapshot.ml`: 27건
- `tool_local_runtime_verify.ml`: 26건
- `keeper_unified_turn.ml`: 26건

**근거**: Alexis King "Parse, Don't Validate" — exhaustive match가 컴파일러에게 invariant 증명을 위임. `_`는 증명을 포기하는 것.

**실행**: variant에 새 constructor 추가 후 `_` 브랜치가 컴파일 에러 나도록 `| _ ->`를 명시적 case로 교체. 파일당 최대 5분.

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

## 3. 금지 패턴 (Anti-patterns)

| 패턴 | 이유 | 대안 |
|------|------|------|
| `Obj.magic` | 타입 시스템 우회 | 올바른 타입 설계 |
| `\| _ -> default_value` | unknown 허용 | exhaustive match |
| Eio 안에서 `Stdlib.Mutex` | dead-lock 위험 | `Eio.Mutex` |
| `Stdlib.Lazy.force` (Eio) | cross-domain 불안정 | `Eio.Lazy.from_fun` |
| mutable record field 과다 | 상태 추적 어려움 | `Atomic` 또는 immutable + snapshot |
| `Hashtbl` + `Mutex` | 직접 구현 | `Eio.Mutex` + immutable map |

---

## 4. 측정 지표 (정량)

| 지표 | 현재 | 목표 (3개월) | 측정 방법 |
|------|------|-------------|----------|
| `.mli` 커버리지 | 53% | 85% | `find lib -name '*.mli' \| wc -l` |
| 와일드카드 `_` 수 | ~799 | <200 | `grep -c '\| _ ->' lib/**/*.ml` |
| `Stdlib.Mutex` (Eio 안) | 13 | <5 | `grep -rl 'Stdlib\.Mutex' lib/` |
| `Obj.magic` | 3 | 0 | `grep -rl 'Obj\.magic' lib/` |
| Effect handler 사용 | 0 | 1-2 pilot | `grep -rl 'Effect\.' lib/` |
| GADT 타입 | 7 | 12+ | `grep -c 'type _ .*=' lib/**/*.ml` |
| Labelled tuple (5.4) | 0 | 신규 타입에 적용 | `grep '~.*:' lib/**/*.ml` |

---

## 5. 참고 자료

- OCaml 5.4 Changelog: https://ocaml.org/releases/5.4.0
- OCaml Manual 5.4: https://ocaml.org/manual/5.4/
- Alexis King "Parse, Don't Validate": https://lexi-lambda.github.io/blog/2019/11/05/parse-don-t-validate/
- Eio Mutex 선택 가이드: ~/me/memory/feedback_ocaml5-mutex-selection.md
- AI 코드 안티패턴: ~/me/instructions/software-development.md
