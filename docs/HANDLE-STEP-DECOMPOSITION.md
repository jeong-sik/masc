# handle_step 분해 설계 (tool_team_session_step.ml)

## 현재 상태

`lib/tool_team_session_step.ml` — 906줄, 단일 함수 `handle_step`.

Phase 1 분할로 이미 추출된 모듈:
- `tool_team_session_step_types.ml` — 타입 + `step_deps` record (141줄)
- `tool_team_session_step_exec.ml` — spawn/delegate 실행 헬퍼
- `tool_team_session_step.mli` — public interface (`handle_step` 1개)

## 문제

`handle_step`이 906줄 단일 함수. 3단계 깊이의 중첩 match + 2개 recursive helper 포함.

## 코드 구조 (현재)

```
handle_step(deps, ctx, args)
├── validate session_id (line 8-9)
├── ensure_session_access (line 11-12)
├── parse spawn_specs (line 15-18)
├── annotate_control_hierarchy (line 19-24)
├── parse turn_kind (line 26-42)
├── parse actor (line 37-49)
├── setup env bindings (line 57-66)
├── prepare_spawns: `let rec loop` (line 68-102) — 35줄
├── spawn_result_json — planning + execution (line 104-540) — 436줄
│   ├── register_planned_workers (line 117-124)
│   ├── planning_error path (line 126-160)
│   ├── proc_mgr unavailable path (line 162-200)
│   ├── `let rec ensure_all` — runtime readiness (line 204-254) — 50줄
│   ├── execute_spawn per worker (line 257-390) — 133줄
│   ├── auto_note after spawn (line 391-400)
│   └── spawn summary JSON (line 401-540)
├── record_session_turn (line 543-547)
└── build final response JSON (line 548-906) — 358줄
```

## 분해 계획

### PR 1: spawn 파이프라인 추출 (~470줄)

새 함수 `execute_spawn_pipeline` 추출.

```ocaml
let execute_spawn_pipeline deps ctx env session_id prepared_spawns =
  (* line 109-540: plan -> ensure -> execute -> summarize *)
  ...
```

- 입력: `deps`, `ctx`, `env`, `session_id`, `prepared_spawns` (list)
- 출력: `Yojson.Safe.t option` (spawn 결과 JSON 또는 None)
- `ensure_all` recursive helper를 이 함수 내부로 이동
- `execute_spawn` per-worker 클로저도 포함

handle_step의 line 104-540이 1줄 호출로 축소.

### PR 2: 응답 빌더 추출 (~350줄)

새 함수 `build_step_response` 추출.

```ocaml
let build_step_response deps ~session_id ~actor ~turn_kind_opt
    ~spawn_result_json ~delegate_result ~turn_result ~base_message ... =
  (* line 548-906: 조건별 JSON 조합 *)
  ...
```

- 순수 함수 (side-effect 없음, JSON 조립만)
- 테스트 작성이 쉬움

handle_step이 ~130줄로 축소 (입력 파싱 + 파이프라인 호출 + 응답 빌드).

### PR 3 (선택): prepare_spawns loop 이동

`let rec loop` (line 68-102)를 `tool_team_session_step_exec.ml`로 이동.
이미 step_exec에 spawn 관련 헬퍼가 모여있으므로 자연스러운 위치.

## 의존성 분석

| 클로저 변수 | 출처 | 파라미터화 방법 |
|------------|------|---------------|
| `deps` | handle_step param | 그대로 전달 |
| `ctx` | handle_step param | 그대로 전달 |
| `env` | line 57에서 구성 | `step_env` 구조체로 전달 |
| `session_id` | line 10 | 파라미터 |
| `append_spawn_event` | env에서 파생 | env 통해 접근 |
| `release_prepared_runtime` | step_exec 모듈 함수 | 직접 호출 가능 |

`step_env` 타입이 이미 `tool_team_session_step_exec.ml`에 정의돼 있어서
클로저 캡처를 파라미터 전달로 변환하는 것이 깔끔함.

## 검증 계획

- `dune build` 성공
- `make test` — 기존 team_session 테스트 통과
- `rg 'handle_step' test/` — 기존 테스트 커버리지 확인
- 외부 리뷰 (GLM 또는 llama-server)

## 예상 규모

| PR | 파일 수 | 변경 규모 | 난이도 |
|----|--------|----------|--------|
| PR 1 | 1 | ~40 ins / ~10 del | Medium |
| PR 2 | 1 | ~30 ins / ~10 del | Easy |
| PR 3 | 2 | ~40 ins / ~35 del | Easy |

PR 1 + PR 2를 하나의 PR로 합쳐도 무방 (같은 파일, 의존 관계).

## 리스크

- **Fiber scope**: spawn이 `Eio.Fiber.fork ~sw:ctx.sw` 사용. `ctx`를 그대로 전달하면 안전.
- **step_deps 확장 불필요**: 새 함수가 deps를 그대로 받으므로 필드 추가 없음.
- **match 중첩 해소**: `prepared_spawns_result` -> `planning_error` -> `proc_mgr` 3단 중첩을
  early return 패턴으로 풀면 가독성 확보.

## 세션 예상

단일 세션 (1-2시간). PR 1이 핵심, PR 2는 기계적 추출.
