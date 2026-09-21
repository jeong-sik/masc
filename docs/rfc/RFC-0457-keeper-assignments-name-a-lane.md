---
rfc: "0457"
title: "Keeper 배정은 레인 이름을 받는다 — 레인이 런타임 id 를 흉내 내야 닿는 규칙을 없앤다"
status: Draft
created: 2026-09-16
updated: 2026-09-16
author: claude
supersedes: []
superseded_by: null
related: ["0361", "0414"]
implementation_prs: []
---

# RFC-0457 — Keeper 배정은 레인 이름을 받는다

## 0. 요약

레인은 이름을 가질 수 없다. `[runtime.lanes.<키>]` 의 키가 **런타임 id 와 글자까지 같을 때만** 그 레인에 닿는다.
배정은 런타임 id 만 받도록 검증되기 때문이다.

그래서 레인은 독립된 물건이 아니라 바인딩에 딸린 속성이 됐고, 네 가지가 따라왔다.

- 이름을 못 붙인다. `[runtime.lanes.coding]` 은 파싱도 검증도 통과하지만 아무도 못 탄다.
- 머리가 같은 사다리를 두 벌 못 만든다. 키가 충돌한다.
- 레인을 지우면 배정이 조용히 `[자기, default]` 2칸으로 떨어진다. 오류도 경고도 없다.
- 키가 아무것도 안 가리키는 레인은 조용히 죽는다.

이 RFC 는 **레인에 이름을 준다.** 배정값이 레인 이름을 받게 하고, 레인이 런타임 id 를 흉내 내야 하는 규칙을 없앤다.

여는 순간 딸려 나오는 것이 하나 있다. 지금은 배정값 하나가 **경로와 구체적인 바인딩 id 두 일을 겸하고 있다.**
레인 키가 런타임 id 라서 겸직이 됐을 뿐이다. 이름을 풀면 겸직이 깨지므로, 구체적인 바인딩이 필요한 자리는
경로를 **그 경로가 처음 여는 바인딩**으로 풀어서 받아야 한다. §3.5.

새 상태도, 새 Gate 도, 마이그레이션 코드도 만들지 않는다.

## 1. 지금 무슨 일이 일어나는가

### 1.1 검증과 실행이 서로 다른 것을 본다

배정 참조는 `Runtime_only` 로 만들어진다.

```ocaml
(* lib/runtime/runtime.ml:638-646  assignment_references *)
{ site = Printf.sprintf "[runtime.assignments].%s" keeper_name
; shape = Scalar
; id = runtime_id
; domain = Runtime_only
}
```

`Runtime_only` 는 선언된 런타임 id 만 통과시킨다.

```ocaml
(* lib/runtime/runtime.ml:607-620  validate_runtime_references *)
| Runtime_only -> resolves_as_runtime reference.id
| Lane_then_runtime ->
  Option.is_some (find_declared_lane lanes reference.id) || resolves_as_runtime reference.id
```

그런데 실행은 레인을 먼저 본다.

```ocaml
(* lib/runtime/runtime.ml:2001-2014  resolve_assignment *)
match find_declared_lane state.lanes assigned_id with
| Some lane -> `Lane lane
| None -> (* 런타임 id 로 찾고, 찾으면 [자기, default] 2칸을 즉석에서 만든다 *)
```

같은 파일이 이 어긋남을 스스로 원칙으로 적어두고 있다.

> Route ids resolve with lane precedence ([resolve_assignment] prefers a lane over a same-named runtime),
> so route validation **must judge the same target the consumer will actually get**: lane first, runtime second.
> — `lib/runtime/runtime.ml:391-393`

배정만 이 원칙을 안 지킨다. 검증은 "런타임 id 여야 한다", 실행은 "레인 먼저". 그래서 레인은 **런타임 id 를 흉내 내야만** 닿는다.

### 1.2 코드가 그 결과를 문서로 적어놨다

```
A lane is reachable only when its id shadows one of the configured routes;
a merely declared lane is dormant until a routed root names it.
— lib/runtime/runtime.ml:1137-1139
```

씨앗 설정은 아예 **죽은 레인을 예시로 싣고** 그렇다고 밝힌다.

```toml
# NOTE: this example lane is INACTIVE. A lane id must shadow a runtime id
# (`<provider>.<model>`) to be reachable; "default" is not a runtime id, so
# this group is never expanded. Kept only as a shape example — do not copy it as-is.
[runtime.lanes.default]
# — config/runtime.toml:1101-1109

# Assignment targets must be runtime ids (<provider>.<model>); a lane id here
# is rejected at load.
# — config/runtime.toml:1124-1127
```

동작하지 않는 예시를 "따라 하지 말라"는 주석과 함께 배포하고 있다는 건, 모양이 쓰는 사람 머릿속과 안 맞는다는 뜻이다.

### 1.3 라이브에서 실제로 새고 있다

2026-09-16 `config/runtime.toml` 기준.

| 선언된 레인 | 이 키를 가리키는 배정 | 결과 |
|---|---|---|
| `glm-coding.glm-5.3-flash` | analyst, sangsu, jazz-developer, goo-yang-bong, msx-retro-mania | 걷는다 |
| `ollama_cloud.ollama-cloud-glm-5-3-flash` | **없음** | **죽었다** |
| `ollama_cloud.ollama-cloud-deepseek-v4-1-flash` | lane-smith, pr-updater | 걷는다 |

죽은 레인의 주석은 "polisher, code-reviewer" 라고 적혀 있는데, 라이브 배정은
`polisher = "ollama.local-granite-42-8b"`, `code-reviewer = "claude_code.claude-sonnet-5"` 다.
주석과 동작이 어긋나 있고, 어긋나도 아무것도 알려주지 않는다.

그리고 `claude_code.claude-sonnet-5` 로 배정된 Keeper 5개(edgar.a.poe, code-reviewer, rondo, geek-scout, critic)는
레인이 없어서 **2칸**이다. 같은 날 05:11:07Z~09:23:43Z 에 claude_code 가 하드 쿼터로 막혔을 때
(`hard quota exhausted` 130건) 갈 곳은 `glm-coding.glm-5.3-flash` 하나뿐이었다.
사다리를 주고 싶어도 이름을 못 붙여서 못 준다.

## 2. 결정

**배정값은 레인 이름이거나 런타임 id 다.** 검증은 실행과 같은 순서로 판정한다 — 레인 먼저, 런타임 다음.

이 결정의 성질:

- **넓히기다.** 지금 유효한 설정은 전부 그대로 유효하다. 레인 키가 런타임 id 인 오늘의 모양은 새 규칙의 특수한 경우다.
- **하드 컷이 아니다.** 그래서 호환 reader 도, converter 도, 마이그레이션 코드도 없다. 지울 과거 필드가 없다.
- **Gate 를 안 만든다.** 이미 있는 로드 검증(`Reference_unresolved`)이 판정하는 이름공간만 넓어진다.

따라오는 성질 하나가 중요하다. 레인에 런타임 id 가 아닌 이름을 붙이면,
그 레인을 지웠을 때 배정이 가리킬 것이 없어져 **로드가 실패한다**. 조용히 런타임 하나만 걷게 되는 길이 구조적으로 사라진다.
레인 키를 런타임 id 로 계속 쓰면 그 보호는 없다 — 이름을 붙이는 쪽이 이득을 갖는다.

## 3. 바꾸는 것

### 3.1 `lib/runtime/runtime.ml`

- `assignment_references` 의 `domain` 을 `Runtime_only` → `Lane_then_runtime`.
- `reference_domain` 주석에서 "requires a declared runtime id for keeper assignments" 를 지우고,
  `Runtime_only` 는 media_failover 전용임을 적는다.
  (media_failover 가 런타임 전용인 것은 의도다 — `keeper_dispatch_runtime_ids` 주석 참조. 그대로 둔다.)
- `keeper_dispatch_runtime_ids` 주석의
  "A lane is reachable only when its id shadows one of the configured routes" 를 지운다. 거짓이 된다.

### 3.2 문서 주석

- `lib/runtime/runtime_schema.ml:366` — `[runtime.assignments]` 설명을 "keeper name → 레인 이름 또는 런타임 id".
- `lib/runtime/runtime_lane.mli` — 레인 `id` 가 자유로운 이름이고 후보만 런타임 id 임을 적는다.

### 3.3 씨앗 설정 `config/runtime.toml`

- `[runtime.lanes.default]` 예시를 살아있는 모양으로 바꾼다. `[runtime].default` 와 헷갈리는 이름이라
  다른 이름을 쓰고, "INACTIVE / do not copy" 주석을 지운다.
- 배정 설명의 "Assignment targets must be runtime ids; a lane id here is rejected at load" 를 새 계약으로 고친다.

### 3.5 경로와 바인딩을 가른다

배정값은 **경로**다. 레인 이름일 수도 있고 런타임 id 일 수도 있다. 턴이 실제로 여는 바인딩은
그 경로가 풀리는 레인의 **첫 후보**다. 이 규칙은 이미 코드에 있다.

> A lane's entry resolution belongs to its first candidate, because its ID is a routing label and
> can shadow a runtime binding.
> — `lib/keeper/keeper_unified_turn_pre_dispatch.ml` `build_runtime_execution`

그 규칙을 `Runtime.entry_runtime_id_of_route` 로 한 자리에 두고, **구체적인 바인딩이 필요한 곳**이 쓴다.
`get_runtime_by_id` 는 레인을 모르기 때문에 레인 이름에 `None` 을 돌려준다.

| 자리 | 지금 | 왜 |
|---|---|---|
| `keeper_effective_tool_surface.ml` `resolve_runtime` | 경로 → 첫 후보 → 바인딩 | posture 는 바인딩의 것이다. 레인 이름으로는 `runtime_not_concrete` 로 떨어졌다 |
| `keeper_unified_turn.ml` 브리핑 바이트 상한 | 경로 → 첫 후보 → 선언된 상한 | 상한을 선언하는 건 바인딩이다 |

경로가 그대로 내려가야 하는 길은 건드리지 않는다. 드라이버는 `run_named ~runtime_id` 로 **경로**를 받아
`resolve_assignment` 로 사다리를 편다(`keeper_turn_driver.ml:1447`), 그리고 `build_runtime_execution` 이
만드는 실행 레코드의 `runtime_id` 도 경로다. 표시·라벨 소비자도 경로를 그대로 보여준다 — 운영자가 적은 것이
그것이기 때문이다.

오늘 설정은 레인 이름 = 첫 후보라 두 값이 같다. 그래서 이 절도 넓히기다.

### 3.4 테스트 `test/test_runtime_per_keeper_routing.ml`

- 배정이 런타임 id 가 아닌 이름의 레인을 가리키면 그 후보를 순서대로 건넨다.
- 머리가 같은 레인 둘을 서로 다른 이름으로 선언하고, 두 Keeper 가 각자 다른 사다리를 걷는다.
- 배정이 가리키는 레인을 지우면 `Reference_unresolved` 로 로드가 실패한다.
- 레인 키가 런타임 id 인 오늘의 모양이 그대로 동작한다(넓히기임을 고정).

## 4. 안 바꾸는 것

- `media_failover` 는 런타임 전용으로 남긴다.
- exact-output 레인(`[runtime.exact_output_lanes]`)은 다른 이름공간이다. 손대지 않는다.
- 실패 회전이 카탈로그 전체를 걷는 동작(`keeper_error_classify.ml:491-521`)은 이 RFC 범위가 아니다. §6 참조.
- 라이브 `runtime.toml` 은 이 PR 이 건드리지 않는다. 배포 뒤 운영자가 고르는 일이다.

## 5. 검증

- CI 경계에서 확인한다. PR CI 는 편집한 `test/test_*.ml` 을 실제로 돌린다.
- `test/test_keeper_turn_driver_failover.ml` 에 `entry_runtime_id_of_route` 를 고정한다: 레인 이름 → 첫 후보,
  런타임 id → 자기 자신, 없는 이름 → `None`, 그리고 `get_runtime_by_id "resilient"` 가 `None` 이라는 것
  (이 함수가 존재하는 이유).
- 넓히기임을 증명하는 것은 §3.4 의 마지막 항목이다 — 오늘의 모양이 계속 통과해야 한다.
- 배포 뒤 라이브 확인: `/api/v1/runtime/resolved` 에서 각 Keeper 가 받는 후보 목록이
  바꾸기 전과 같은지 본다(라이브 설정을 안 고쳤으니 같아야 한다).

## 6. 남는 구멍과 후속

1. **죽은 레인은 여전히 조용하다.** 이름이 생겨도, 아무도 안 가리키는 레인은 그냥 안 걷힌다.
   Gate 로 막지 않는다(선언 순서를 강제하게 된다). 대신 `/resolved` 에 참조되지 않은 레인을 투영하는 것이
   맞는 자리다. 별도 작업.
2. **후보가 전부 카탈로그에서 사라진 레인을 배정이 가리키면** `unavailable_assignments` 에 안 잡힌다
   (`runtime.ml:1362-1368` 이 레인 이름을 제외한다). 이 구멍은 지금도 있고 이 변경이 만들지 않는다.
   `dropped_lanes` 로는 보인다. 별도 작업.
3. **카탈로그 전체 회전.** 실패 사유가 `Capacity_backpressure` / `Server_error` / `Auth_error` /
   `Runtime_exhausted` / `Runtime_candidates_filtered` / `Resumable_cli_session` 이면 회전이
   카탈로그를 선언 순서대로 걷는다. 그래서 "안 쓰는 바인딩" 이 없다 — 전부 살아있는 폴백 목적지다.
   "Provider/Model 은 많이 선언해두고 레인으로 고른다" 가 성립하려면 이걸 레인 후보로 좁혀야 한다.
   #23373 사고 대응으로 들어온 코드라 별도 RFC 로 다룬다.
