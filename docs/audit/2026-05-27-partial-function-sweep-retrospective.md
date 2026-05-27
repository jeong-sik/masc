# Partial function sweep 회고 (2026-05-27)

**Scope**: `Option.get`, `List.hd`, `List.tl`, `assert false`, `try ... with _ ->` 등 *runtime invariant 가 컴파일러 강제 안 되는* partial-function 사이트를 typed match 또는 narrowed exception 으로 변환한 9 PR 시리즈.

**Outcome**: 9 PR (8 MERGED + 1 OPEN) · 12 사이트 제거 · 1 typed helper 신설 (`extract_input_required`) · 2 docs PR.  Magic Number Time-literal 시리즈 종결 직후 *pivot 영역* 으로 진행, saturation 도달.

본 회고는 Magic Number 회고 (`2026-05-27-magic-number-time-literal-series-retrospective.md`) 와 *별도 PR 형식* 으로 진행했지만 *같은 audit SOP* 활용 — 회고들끼리도 *cross-link 패턴* 자체가 학습.

---

## 1. PR 목록 (시간순)

| # | PR | site | 패턴 |
|---|----|------|------|
| 1 | #19127 | `lib/keeper/agent_tool_memory_runtime.ml` 3 sites | `Option.get` + dead `None` guard ladder → `match (eh, h)` |
| 2 | #19130 | `lib/keeper_invariant/keeper_invariant.ml` 1 site | `List.tl` + `when acc <> []` guard → `match acc` (fall-through 보존 명시) |
| 3 | #19133 | `lib/board_comment_rate_limit.ml` 1 site | `List.hd` + `List.length >= limit` guard → `match List.sort` (exhaustive sentinel) |
| 4 | #19137 | `lib/cdal_runtime/autonomy_exec.ml` 1 site | `List.hd effective` + caller invariant (`validate_config` line 82) → `match effective` (Result Error fallback) |
| 5 | #19140 | `lib/cascade_decl/cascade_declarative_parser.ml` 1 site | `List.hd errs` + helper invariant (`[error path message]`) → `match errs` (1-element 노출) |
| 6 | #19142 | `lib/keeper/keeper_status_bridge.ml` 1 site | `List.hd lines` + outer `if lines = []` guard → local `let first_line = match lines` (minimal lift) |
| 7 | #19149 | `lib/keeper/keeper_unified_turn_execution.ml` 1 site | `if EC.is_input_required_error err then ... match ... | _ -> assert false` → typed companion `extract_input_required` + single `match` |
| 8 | #19151 | `lib/config/env_config_keeper.ml`, `lib/auth_credential_base.ml` 2 sites | `try ... with _ -> None` → `with Failure _ \| Unix_error _ -> None` (RFC-0145) |
| 9 | #19160 | `lib/server/server_routes_http_routes_dashboard_setup.ml` 1 site | `executable_file_exists` 의 `with _ -> false` → `Sys_error \| Unix.Unix_error` (RFC-0145) |

**Hotfix during series**: PR #19163 (Iter 69-73) — `keeper_turn_driver_try_cascade.ml:604` 의 `Agent_sdk.Error.Timeout` constructor namespace prefix 오류 (PR #19145 RFC-0197 watchdog 영향), main HEAD 5+ iter 동안 broken.  Magic Number 회고 §2.5b + Step 8 (PR #19166) 가 그 학습 반영.

---

## 2. 발견된 패턴

### 2.1 Runtime guard ↔ Partial call 분리 안티패턴

가장 흔한 안티패턴.  *runtime predicate* 가 *partial function* 의 invariant 를 *암묵* 보장:

```ocaml
(* before *)
if list_length recent >= limit then
  let oldest = List.hd (List.sort ...) in ...

(* after *)
if list_length recent >= limit then
  (match List.sort ... with
   | [] -> None  (* unreachable, compiler-enforced *)
   | oldest :: _ -> ...)
```

guard 와 partial call 이 *별도 expression* 이라 compiler 가 결합 검증 못 함.  *future refactor* 가 둘 중 하나만 만지면 silent crash.

**해결**: `match` 패턴 안에 guard 흡수.  `[]` arm 이 *unreachable but exhaustive* 로 compiler 강제.

### 2.2 Caller graph invariant — typed safety net

```ocaml
(* before *)
let spawn_child config effective =
  let exec = List.hd effective in  (* caller 가 non-empty 보장 *)

(* after *)
let spawn_child config effective =
  match effective with
  | [] -> Error (invalid_config "effective" "spawn_child reached with empty argv (validate_config bypass)")
  | exec :: _ -> ...
```

caller graph 가 *지금* invariant 보장하지만 *향후 refactor 가 우회* 가능.  `[]` branch 가 typed safety net — 현재 unreachable 이지만 future refactor 시 *crash 대신 Result Error*.

PR #19137 (autonomy_exec) 가 모범 — caller graph 분석 후 typed lift.

### 2.3 Helper invariant 코드 노출

```ocaml
(* helper *)
let error path message = [ { path; message } ]   (* always 1-element list *)

(* before — caller *)
let e = List.hd errs in ...

(* after — caller *)
match errs with
| [] -> "<empty error list>"           (* unreachable per helper contract *)
| e :: _ -> ...
```

helper 의 *1-element list* invariant 가 *코드로 noted but not type-enforced*.  typed match 가 helper contract 와 caller 사이 *compiler 검증 link*.

PR #19140 (cascade_declarative_parser) 가 모범.

### 2.4 Typed companion 패턴 — predicate + projection 결합

```ocaml
(* before *)
if EC.is_input_required_error err then
  let ir =
    match err with
    | Agent_sdk.Error.Agent (InputRequired ir) -> ir
    | _ -> assert false   (* same constructor as predicate *)
  in ...

(* after *)
match EC.extract_input_required err with   (* predicate + projection *)
| Some ir -> ...
| None -> ...
```

predicate (`is_X : bool`) 와 projection (`match | _ -> assert false`) 이 *같은 constructor* 검사인데 분리 → `assert false` partial.  **Typed companion** `extract_X : ... -> X option` 가 둘을 single match 로 결합.

PR #19149 가 모범 — `is_input_required_error` 보존 (predicate-only when-guard 호환) + 새 `extract_input_required` 추가 = *점진적 마이그레이션* 가능.

**sw-dev "Parse, don't validate"** 의 OCaml 적용: predicate (`validate`) 는 정보 손실, projection (`parse`) 는 typed payload 반환.

### 2.5 Wildcard catch narrowing (RFC-0145)

```ocaml
(* before *)
try Some (Unix.stat file).st_mtime with _ -> None

(* after *)
try Some (Unix.stat file).st_mtime with
| Unix.Unix_error _ -> None
```

`with _ ->` 가 *Out_of_memory*, *Stack_overflow*, *async cancellation* 까지 삼킴.  narrow 후 *typed exception* 만 catch, 나머지는 propagate.

**판단 기준**:
- *intentional finally* (`release_quietly`, cleanup) — narrow 부적절 (manifest §"finally 예외 내부 처리")
- *expected error catch* (`int_of_string` Failure, `Unix.stat` Unix_error) — narrow 가능 + 인라인 RFC-0145 주석

PR #19151, #19160 가 RFC-0145 시리즈 (2 PR, 3 사이트).

---

## 3. Audit SOP

본 시리즈가 적용한 6-step audit (Magic Number 회고 §2.1 의 *partial-function 변형*):

1. **Grep audit**: `rg -n 'Option\.get\b|List\.hd\b|List\.tl\b|assert false|with _ ->' lib/ --type ml -g '!test/'` 후보 raw list.
2. **주석/정당화 필터**: `rg -v '\(\*|\/\*'` + `release_quietly` 같은 *명시 정당화* 사이트 skip.
3. **Invariant source 식별**: partial call 이 의존하는 runtime guard 어디에서 왔는지 (caller graph / helper contract / outer if / when guard).
4. **Lift 방식 결정**: typed match / typed companion / typed safety net (Result Error) / narrow.
5. **변경 분량 평가**: 단일 사이트 surgical PR vs 시리즈 PR.  큰 refactor (예: `keeper_status_bridge.ml:232` 외부 if-guard 전체 lift) 는 *minimal lift* 로 surgical 처리, 큰 lift 는 별도 RFC.
6. **인라인 주석 명시**: invariant source (line N, helper, outer guard) 를 *코드 자체에 인용* — reader 가 backtrack 안 해도 안전성 확인.

### Step 7 신규 — finally clause 감지

본 시리즈 진행 중 추가: `try ... with _ -> ()` 가 *finally 의도* 일 때 narrow 부적절.  체크 방법: 같은 try block 가 *primary exception 보존* 인지 확인 (re-raise 직전 cleanup, `Switch.on_release`, `release_quietly` 등).

---

## 4. Force multiplier 패턴 (Magic Number 회고 §2.2 와 같음)

PR #19149 의 `extract_input_required` 신설 → 향후 `is_input_required_error` caller 도 typed migration 가능.  **Typed helper 신설** 이 단일 PR 보다 leverage 큼.

향후 SSOT 작업의 sequencing 모델 재확인:

```
Phase A: typed helper / SSOT entry 추가 (단일 PR, <30 LOC)
       ↓
Phase B: use site 변환 (parallel 가능)
```

---

## 5. 정량 요약

| 항목 | 값 |
|------|----|
| 시리즈 기간 | 2026-05-27 (1 day, iter 60 ~ iter 73) |
| PR MERGED | 8 |
| PR OPEN (Draft) | 1 (#19160 narrow 후속) |
| Sites removed | 12 |
| Typed helpers 신설 | 1 (`extract_input_required`) |
| Concomitant docs PR | 2 (#19166 회고 §2.5b + Step 8, #19169 RFC-0200 draft) |
| Concomitant hotfix | 1 (#19163, Iter 69-73 main HEAD broken 5+ iter) |
| In-flight PR retire | 0 (시리즈 시작 시 #18793/#1787/#18816 이미 종결) |

---

## 6. 남은 사이트 (out-of-scope)

### 6.1 의도된 finally clause (RFC-0145 narrow 부적절)

| 파일 | 사이트 | 정당화 |
|------|--------|--------|
| `lib/cascade/cascade_tier_admission.ml:102` | `release_quietly` | manifest §"finally 예외 내부 처리" 명시 인용 |
| `lib/cascade/cascade_tier_wait_scheduler.ml:222, 298` | re-raise 직전 cleanup | primary exception 보존 |

### 6.2 의도된 partial — `_exn` convention

- `lib/cascade_name/cascade_name.ml:17` — `Cascade_name.of_string_exn` 의 `failwith`.  같은 모듈에 `of_string : result` + `of_string_or ~fallback` 공존 → caller 가 typed alternative 선택 가능.  `_exn` 접미사가 *명시 contract*.

### 6.3 Test scaffold (assert-like)

- `lib/cdal_runtime/autonomy_exec.ml:507, 511` — inline test 안 assertion-like `failwith`.  변환 가치 없음.

### 6.4 큰 refactor 필요

- `lib/keeper/keeper_status_bridge.ml:168` 외부 `if lines = []` guard 전체 lift (`match lines | [] -> None | first :: rest -> ...`).  ~100 lines else block indentation churn → 별도 PR 또는 RFC.
- `lib/server/server_ide_lsp_proxy.ml:596` — `route_admission` typed variant 에 `proc_mgr` payload 추가.  test 가 fake `Eio_unix.Process.mgr_ty` 인스턴스 만들어야 → typed test infra RFC 필요.

---

## 7. 향후 시리즈를 위한 체크리스트 (Magic Number 회고 §4 보강)

- [ ] Grep audit: `Option\.get\b|List\.hd\b|List\.tl\b|assert false|with _ ->`
- [ ] 주석/finally clause 필터링
- [ ] Invariant source 식별 (guard / caller graph / helper / outer if)
- [ ] Typed companion 가치 평가 (predicate + projection 결합 가능 시 helper 신설)
- [ ] 인라인 주석에 invariant source 명시
- [ ] **Step 7 (Magic Number 회고)**: sub-library dune dep audit — typed helper 가 sub-library 안에 있으면 dependents dune dep 확인
- [ ] **Step 8 (Magic Number 회고)**: core 영역 (`lib/keeper`, `lib/cdal`, `lib/server`, `lib/cascade`, `lib/coord`) 변경 시 push 전 `dune build lib/` 수동 검증

---

## 8. Related

- `docs/audit/2026-05-27-magic-number-time-literal-series-retrospective.md` — *형제* 회고 (Magic Number Time-literal sweep)
- `docs/rfc/RFC-0200-time-constants-leaf-library.md` (#19169) — Magic Number 회고 §3.1 follow-up
- CLAUDE.md sw-dev `"Parse, don't validate"` (Alexis King)
- RFC-0145 — exception narrowing 패턴
- CLAUDE.md `사고는 명시적` — runtime invariant 를 type 으로 노출

🤖 Generated as part of `/loop` iter 74 — post-saturation retrospective of partial-function sweep.
