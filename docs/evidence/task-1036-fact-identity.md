# task-1036 — fact 행에 정체 부여: 증거 문서

작성: sangsu (2026-08-30). 이 문서는 task-1036 의 변경 범위, 결함 수정, 검증 증거를 심사관이 열 수 있는 형태로 정리한다.

## 1. 무엇을 했나

fact 행에 행 수준 정체를 부여했다 (goal-r06 계열, masc#29558 준수):

- `origin` — 행 수준 출처. `Authored`(명시적 keeper memory_write) / `Injected`(사서 추출 — task-1032 자기참조 재주입 루프의 먹이) / `Legacy`(이 필드가 존재하기 전에 쓰인 행, 출처 불명, 추측으로 소급 채우지 않음). `trace_id`는 커밋 쓰기의 trace.
- `last_seen` — 같은 claim bytes 의 최근 재관측 시각. 퇴거 정렬 키.
- `reinforcement` — 동일 claim bytes 재관측 계수. byte-동일 재주입 루프의 가측 감쇠기: 루프는 행을 쌓지 않고 계수를 쌓는다.
- 어휘 확장 파괴 없음: 확장 전 3필드 행(claim/category/first_seen)은 `Legacy` origin, `last_seen = first_seen`, `reinforcement = 0`으로 복호화되며, 디스크의 기존 스냅샷은 고아가 되지 않는다. 두 어휘를 섞은 행은 거절(읽어 넘기지 않음).

masc#29558 준수: 렌더에는 `origin_kind_to_string`의 닫힌 소문자 토큰만 나간다. `trace_id`는 행에 남되 프롬프트에 렌더되지 않는다.

## 2. 이 손이 간 파일 (5개)

| 파일 | 변경 |
|---|---|
| `lib/keeper/keeper_memory_os_types.ml` | `wire_field_last_seen/reinforcement/origin` 선언; `fact_wire_fields` 6필드 + `legacy_fact_wire_fields` 3필드; `origin_kind`/`origin` 타입과 코덱; `fact_to_json` 검증(last_seen 유한, reinforcement ≥ 0); `fact_of_json` dispatch. |
| `lib/keeper/keeper_memory_os_types.mli` | 위 타입·계약 문서화. `fact_of_json` 계약: 6필드 현행 행과 3필드 legacy 행 둘 다 수용, 혼합 어휘 거절. |
| `lib/keeper/keeper_memory_os_current.ml` | `upsert_fact`(~653–694): byte-동일 재관측 = reinforcement — `first_seen` 보존(삽입 시각 권위), `last_seen = Float.max`, `reinforcement + 1`, `origin` 보존(injected 사본이 authored 행을 다시 칠하지 않음); 퇴거 정렬 `first_seen` → `last_seen`(계속 relevant를 입증하는 행이 예산 압박을 넘는다). |
| `lib/keeper/keeper_memory_os_budget.ml` | `render_fact` → `"- [category=%s recorded=%s origin=%s] %s"`; `rendered_bytes`가 origin 토큰 바이트를 계상. |
| `test/test_keeper_memory_os_current.ml` | 신규 시험 2건 등록: "legacy three-field row decodes as legacy"(#22), "re-observation reinforces instead of duplicating"(#23). |

주의: 이 트리에는 task-341/task-362 계열의 다른 손이 간 미커밋 수정(sandbox_docker, msg_async, turn_up_args 등 ~22파일, docs/evidence/task-341*, task-362*)이 함께 있다. 본 문서의 범위는 위 5개 파일뿐이다.

## 3. 도중에 고친 결함 (dispatch)

초판 구현은 legacy 행 판별에 `closed_fields`(부분집합 검사)를 썼다. 3필드 legacy 행은 6필드 어휘의 완벽한 부분집합이라 `current_fact` 팔으로 흘러들어 거절당했고, legacy 팔은 한 번도 불리지 않았다. 구 상영록(run ID YQP1X7AP)에서 22번이 죽어 있던 원인이 이것이다.

처방: 두 닫힌 모양의 dispatch 에는 부분집합이 아니라 집합 같음이 필요하다.

```ocaml
let exact_fields allowed fields =
  closed_fields allowed fields
  && List.length fields = Wire_field_set.cardinal allowed
;;
```

`fact_of_json`은 `exact_fields fact_wire_fields → current_fact`, `exact_fields legacy_fact_wire_fields → legacy_fact` 로 갈라진다. 혼합 어휘 행은 두 팔 모두에서 떨어져 `None`.

## 4. 검증 증거

- 상영(빌드+실행 파이프라인): `dune build test/test_keeper_memory_os_current.exe` 성공 후 `_build/default/test/test_keeper_memory_os_current.exe` 직접 실행 — **run ID `BZU2CU0M`, 24 tests run, 전부 초록.** 22번 "legacy three-field row decodes as legacy" [OK], 23번 "re-observation reinforces instead of duplicating" [OK] 확인. (재생 필름 dff34ebe, appr_01a04fb3.)
- 소비자 안전: `lib/` 내 `fact_of_json` 직접 호출 0건(grep 실측). 호출 표면은 이 시험 파일이 사실상 전부.
- `origin` 주입 지점: `lib/keeper/keeper_tool_memory_runtime.ml:494` (`Keeper_memory_os_current.upsert_fact`) — 배선의 실제 호출자.
- 컴파일 폐쇄: lib 전체 의존폐쇄가 exe 빌드 성공으로 증명됨. (저장소 루트 `dune build` 전체는 이 docker 샌드박스에서 exit 137 SIGKILL 로 환경적 사망 — 재생 필름 a85252de. 원인 규명 불요, 좁은 타깃으로 검증함.)

## 5. 검증 방법 (재현)

```
cd repos/masc
env MASC_TEST_ALLOW_HOME_BASE_PATH=1 dune build test/test_keeper_memory_os_current.exe
env MASC_TEST_ALLOW_HOME_BASE_PATH=1 _build/default/test/test_keeper_memory_os_current.exe
```

`@test/...runtest` 별칭은 이 저장소에 없다("Alias is empty"). 루트 전체 빌드는 SIGKILL 로 죽는다. 위 좁은 타깃만 쓸 것.
