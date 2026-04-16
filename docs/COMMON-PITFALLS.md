# Common Pitfalls

Recurring mistakes from commit history analysis. Check this before submitting PRs.

## 1. Stale References After Deletion (12 occurrences)

When you delete or rename a module, these are often left behind:
- Test files referencing the deleted module
- `dune` file listing the deleted module name
- CSS imports in dashboard components
- Other modules that `open` or call the deleted module

**Before deleting any `.ml` file:**
```bash
# Find all references
rg "ModuleName" lib/ test/ bin/ dashboard/src/ --type-add 'dune:*.ml' -l
```

**Before deleting any `.css` file:**
```bash
rg "filename.css" dashboard/src/ -l
```

## 2. Eio Cooperative Scheduling (10 occurrences)

This codebase uses Eio (OCaml 5.x cooperative concurrency). Common mistakes:

- `Stdlib.Mutex` in Eio context → use `Eio.Mutex` (causes EDEADLK)
- Blocking I/O (`Unix.read`, `open_in`) in Eio fibers → use `Eio.Path` or `Fs_compat`
- Missing `Eio.Cancel.Cancelled` guard in exception handlers → re-raise it
- Spin loops (`while true`) → use `Eio.Time.sleep` or `Eio.Condition`

**Exception handler template:**
```ocaml
(try some_operation ()
 with
 | Eio.Cancel.Cancelled _ as e -> raise e  (* always re-raise *)
 | exn -> Log.error "failed: %s" (Printexc.to_string exn))
```

## 3. Dashboard Changes Need Build Verification (38% of recent commits)

Dashboard is a Preact+HTM SPA compiled with Vite. Common issues:
- Nullable fields from API → guard with `?? default` or optional chaining
- Signal updates with same value → cause unnecessary re-renders (use `if (sig.value !== newVal)`)
- CSS custom properties must be defined before use

**Always after dashboard changes:**
```bash
cd dashboard && pnpm run build  # catches TypeScript errors
```

## 4. Test Breakage From Refactoring (6 occurrences)

Tests break when:
- Module is deleted but test still references it
- Function signature changes but test uses old signature
- Eio context required but test doesn't wrap in `Eio_main.run`

**After any refactoring:**
```bash
dune build --root .  # catches compilation errors in tests
```

## 5. Silent Error Patterns — When to Log

`| Error _ ->` 사용 시 side-effect 실패 삼킴에 주의.

**로그 필수 (`warn`) — state를 바꾸려다 실패:**
```ocaml
| Error e -> Log.BoardLog.warn "notification failed: %s" e
```
SSE/notification 발행, 파일 쓰기, 외부 API 호출, audit/economy 기록.

**로그 선택 (`debug`) — 읽다가 실패:**
```ocaml
| Error e -> Log.Reputation.debug "task file unreadable: %s" e
```
디렉토리 스캔 중 개별 파일, config 파싱, runtime context 미가용.

**로그 불필요 (idiomatic OCaml):**
```ocaml
List.filter_map (function Ok t -> Some t | Error _ -> None)
(try int_of_string s with _ -> default)
(try Sys.remove tmp with _ -> ())
```

**PR 체크:** `rg '\| Error _ -> \(\)' lib/` 로 새 `| Error _ -> ()` 확인.

## 6. Version String Drift (2 occurrences)

`dune-project` version and `sdk_version.ml` (or equivalent) must match.
CI checks this — but fix it before pushing.

```bash
# Check
grep '(version' dune-project | head -1
grep 'let version' lib/sdk_version.ml
```

## 7. Prompt Changes Need Checkpoint Reset

Keeper system prompts are cached in checkpoints. After changing prompts:
- Existing keepers continue using the old prompt from checkpoint
- New prompts only apply when `build_turn_prompt` overrides at runtime
- If testing prompt changes, verify the running keeper's actual system prompt
- Core prompt text now lives in `config/prompts/*.md`; Dashboard overrides in `Lab > Tools > Prompt Registry` only change runtime effective text and are persisted to `.masc/prompt_overrides.json`

## 8. Feature Flag Registry Duplicates (ADR-003)

Feature flags는 `lib/config/feature_flag_registry.ml`에 중앙 등록되어야 한다. 최근 발견된 문제:

**Common Pattern: Concurrent Merge로 인한 중복 등록**
```bash
# PR #3793: MASC_KEEPER_WORK_AS_HEARTBEAT가 3번 등록됨 (lines 95, 130, 140)
# 두 feature branch가 독립적으로 같은 플래그를 추가 → merge conflict 없이 통과
```

**Before adding any new feature flag:**
```bash
# 1. Check if env_name already exists in registry
rg "env_name = \"MASC_YOUR_FLAG\"" lib/config/feature_flag_registry.ml

# 2. Check if similar flags exist (naming convention)
rg "MASC_KEEPER_.*HEARTBEAT" lib/config/feature_flag_registry.ml

# 3. Verify default matches between registry and config module
grep -A 5 "MASC_YOUR_FLAG" lib/config/feature_flag_registry.ml
rg "get_bool.*MASC_YOUR_FLAG" lib/config/
```

**Rules:**
- `env_name` 필드는 전역 고유해야 함 (no duplicates)
- Registry default와 config module default가 일치해야 함
- 새 flag는 `Experimental` lifecycle로 시작
- CI는 `check-feature-flag-consistency.sh`로 일관성 검증

**Checklist for Registry Changes:**
- [ ] env_name이 unique한가?
- [ ] config module의 default가 registry와 일치하는가?
- [ ] lifecycle 상태가 올바른가?
- [ ] since version이 정확한가?

상세: `docs/ADR-003-FEATURE-FLAG-REGISTRY-MANAGEMENT.md`

## 9. Config Module Anti-Patterns

Config 모듈에서 자주 발생하는 실수:

**❌ DON'T: Raw Sys.getenv 사용**
```ocaml
let my_value = Sys.getenv_opt "MASC_MY_FLAG" |> Option.value ~default:"false"
```
문제: Registry 미등록, type safety 없음, 테스트 isolation 불가

**✅ DO: 중앙화된 getter 사용**
```ocaml
(* 1. Feature_flag_registry.ml에 등록 *)
{ env_name = "MASC_MY_FLAG"; default_value = false; ... }

(* 2. env_config_*.ml에 typed getter *)
let get_my_flag () = Env_config_core.get_bool "MASC_MY_FLAG" false
```

**❌ DON'T: 모듈 초기화 시점에 config 읽기**
```ocaml
let my_config = get_my_flag ()  (* module-level binding *)

let process () = if my_config then ...  (* stale value *)
```
문제: test 격리 불가, runtime override 불가

**✅ DO: 사용 시점에 config 읽기**
```ocaml
let process () =
  let my_config = get_my_flag () in  (* call-site binding *)
  if my_config then ...
```

**Result Pattern 선호:**
```ocaml
(* _result suffix는 (value, error message) result 반환 *)
let get_required_path_result () =
  Env_config_core.get_string_result "MASC_REQUIRED_PATH"

(* suffix 없는 함수는 예외 발생 (편의용) *)
let get_required_path () =
  match get_required_path_result () with
  | Ok path -> path
  | Error msg -> raise (Config_error msg)
```

## 10. Test Environment Isolation

Test는 production config와 격리되어야 한다.

**현재 test/dune:**
```lisp
(env
  (MASC_STORAGE_TYPE filesystem)
  (MASC_POSTGRES_URL "")
  (DATABASE_URL "")
  (SUPABASE_DB_URL "")
  (GRAPHQL_API_KEY "")
  (ZAI_API_KEY ""))
```

**자주 발생하는 문제:**
- Test가 parent shell env를 상속받아 실제 DB에 연결 시도
- CI 환경에서만 실패하는 테스트 (env 차이)
- Test 간 격리 실패 (공유 mutable state)

**After adding config-dependent tests:**
```bash
# 1. test/dune에 필요한 env 명시
dune build --root . test/  # fails if missing env

# 2. Test 내부에서 override 필요 시 명시적으로
let test_with_custom_config () =
  Unix.putenv "MASC_TEST_FLAG" "true";
  (* test code *)
  Unix.putenv "MASC_TEST_FLAG" "false"
```

**Eio Context 필요한 Test:**
```ocaml
let test_with_eio () =
  Eio_main.run @@ fun env ->
  (* env.clock, env.fs 등 사용 *)
  Alcotest.(check bool) "test" true result
```

문제: `Eio_main.run` 없이 Eio 함수 호출 → runtime panic

## 11. Dashboard Build Dependency

Dashboard는 OCaml build와 독립적으로 빌드되어야 한다.

**Common Mistake:**
```bash
dune build --root .  # ✅ OCaml 빌드 성공
# dashboard는 빌드되지 않음!
./start-masc-mcp.sh --http  # dashboard가 404 또는 stale
```

**Correct Flow:**
```bash
# 1. OCaml 빌드
dune build --root .

# 2. Dashboard 빌드 (별도)
cd dashboard && pnpm run build

# 또는 자동 빌드 script 사용
./start-masc-mcp.sh --http  # pnpm 있으면 자동 빌드
```

**CI에서:**
```bash
scripts/build-dashboard-if-needed.sh
# checks if dashboard/dist/ exists and is up-to-date
```

**Dashboard 변경 후 반드시:**
```bash
cd dashboard && pnpm run build
# TypeScript 컴파일 에러, type 불일치 등을 사전에 감지
```

**Dev Server와 Production Build 차이 주의:**
```bash
# Dev server (Vite dev mode, HMR, proxy)
cd dashboard && MASC_DASHBOARD_PROXY_TARGET="http://127.0.0.1:8935" pnpm run dev

# Vite port를 5173이 아닌 값으로 바꾸면 서버 쪽 allowlist도 같이 맞춘다.
MASC_HTTP_DEV_MUTATION_ORIGINS="http://localhost:4173" ./start-masc-mcp.sh

# Production build (static assets in dist/)
cd dashboard && pnpm run build
```

## 12. Health Snapshot Ratcheting

Codebase health는 특정 anti-pattern 사용 횟수로 추적된다.

**Current Baseline (baseline/health-snapshot.json):**
```json
{
  "lib_failwith": 26,        // lib/에서 failwith 사용
  "lib_list_hd": 2,          // lib/에서 List.hd 사용
  "lib_list_tl": 2,          // lib/에서 List.tl 사용
  "lib_option_get": 0,       // lib/에서 Option.get 사용
  "test_failwith": 247,      // test/에서 failwith 사용
  "test_list_hd": 162        // test/에서 List.hd 사용
}
```

**Ratcheting Rule:**
- 현재 카운트를 초과하면 CI 실패
- 카운트 감소는 허용 (개선 환영)
- 신규 anti-pattern 발견 시 baseline 업데이트

**Before using partial functions:**
```ocaml
(* ❌ List.hd raises on empty list *)
let first = List.hd my_list

(* ✅ Pattern match is safe *)
let first = match my_list with
  | [] -> None
  | x :: _ -> Some x

(* ❌ Option.get raises on None *)
let value = Option.get my_option

(* ✅ Option.value with default *)
let value = Option.value ~default:fallback my_option
```

**PR이 health regression을 일으킨 경우:**
```bash
# CI fails with: "lib_failwith count increased from 26 to 27"
# 두 가지 선택:
# 1. failwith를 Result/Option pattern으로 refactor (선호)
# 2. 정당한 사유가 있다면 baseline 업데이트 (reviewer 승인 필요)
```

## 13. Concurrent Merge Semantic Validation

Git merge는 textual conflict만 감지한다. Semantic duplication은 CI가 잡아야 한다.

**예시: Feature Flag Duplication (PR #3793)**
```
Branch A: adds WORK_AS_HEARTBEAT at line 95
Branch B: adds WORK_AS_HEARTBEAT at line 130
Merge: both exist (no textual conflict) ← Git OK, CI should fail
```

**After editing registry-like files:**
```bash
# Feature flag registry
scripts/check-feature-flag-consistency.sh

# Dune files (module list in libraries)
dune build --root .  # fails on missing modules

# Dashboard routes
cd dashboard && pnpm run build  # TypeScript type check
```

**Files requiring semantic validation:**
- `lib/config/feature_flag_registry.ml` - env_name uniqueness
- `lib/tool_catalog.ml` - public tool list
- `dune` files - module list completeness
- Dashboard TypeScript - type consistency

**Best Practice: Small, Frequent Merges**
- Long-lived feature branches → 높은 semantic conflict 확률
- Frequent rebase/merge → textual conflict는 많지만 semantic은 적음
- Registry 수정은 작은 PR로 분리

---

## Related Architecture Decision Records (ADRs)

이 문서의 pitfall들은 다음 ADR에서 더 깊이 다룬다:

| Pitfall Section | Related ADR | Key Takeaway |
|----------------|-------------|--------------|
| #8 Feature Flag Registry Duplicates | [ADR-003: Feature Flag Registry Management](ADR-003-FEATURE-FLAG-REGISTRY-MANAGEMENT.md) | Registry는 SSOT, env_name은 전역 고유, concurrent merge는 semantic validation 필요 |
| Context/Mitosis pattern | [ADR-001: Mitosis vs Compaction](ADR-001-MITOSIS-VS-COMPACTION.md) | Historical: mitosis runtime removed in v2.170+. Context transfer now uses Relay/Handoff system |
| Dashboard Control Surface | [ADR-002: Dashboard Operator Control Surface](ADR-002-DASHBOARD-OPERATOR-CONTROL-SURFACE.md) | `masc_operator_*` quartet가 canonical, generic tool executor는 admin-only |

**Why ADRs?**
- **Common Pitfalls**: 실무에서 자주 발생하는 실수와 즉시 적용 가능한 회피책
- **ADRs**: 설계 결정의 맥락, trade-off, 장기적 결과를 명확히 문서화
- ADR은 "왜 이렇게 해야 하는가"를 설명, Pitfalls는 "무엇을 하지 말아야 하는가"를 설명

**Reading Order:**
1. 먼저 이 문서(Common Pitfalls)를 읽고 실무 체크리스트 확인
2. 설계 맥락이 궁금하면 관련 ADR 참조
3. PR review 시 양쪽 모두 참조하여 일관성 확인

---

## Maintenance Notes

이 문서는 git commit history 분석과 실제 발생한 문제에 기반한다.

**업데이트 trigger:**
- 같은 실수가 3회 이상 반복될 때 (신규 pitfall 추가)
- 기존 pitfall의 회피책이 더 나은 방법으로 개선될 때
- ADR이 새로 작성되어 관련 맥락을 제공할 때

**PR 체크리스트 with this doc:**
- [ ] 새 모듈 삭제했는가? → Section #1 체크
- [ ] Eio context에서 작업하는가? → Section #2 체크
- [ ] Dashboard 변경했는가? → Section #3, #11 체크
- [ ] 테스트 추가/변경했는가? → Section #4, #10 체크
- [ ] Feature flag 추가했는가? → Section #8 체크
- [ ] Config 추가/변경했는가? → Section #9 체크
- [ ] Partial function 사용했는가? → Section #12 체크
- [ ] Registry-like file 수정했는가? → Section #13 체크

**마지막 업데이트**: 2026-03-30 (ADR-003 추가, Section #8-#13 신규)
