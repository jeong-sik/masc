---
rfc: "0389"
title: "Keeper 별 도구 표면 — 101개를 전원에게 매 턴 보내는 것을 그만둔다"
status: Adopted
created: 2026-08-22
updated: 2026-08-29
author: claude
supersedes: []
superseded_by: null
related: ["0080", "0084", "0182"]
---

# RFC-0389: Keeper 별 도구 표면

## 0. Summary

모든 Keeper 가 매 턴 **똑같은 도구 100~101개, 78~80KB** 를 받는다. 누구도 전부 쓰지 않는데
아무도 덜 받지 않는다. 이 RFC 는 이미 선언돼 있으나 가시성에는 쓰이지 않는
`keeper_tool_group` 을 Keeper TOML 이 고르는 축으로 승격하는 설계와, 그러기 위해 결정해야 할
항목을 정리한다. 도구 표면은 코드가 아니라 `<config-root>` 의 TOML 이 정한다는 저장소 방향
(도구·프롬프트 정의를 바깥으로) 의 첫 단계다.

이 RFC 는 masc#29337 (GLM-5-Turbo 가 tool_use 이름에 인자를 섞어 보내는 건) 을 고친다고
주장하지 않는다. §2 에 그 이유를 적는다.

## 1. 관측

수치는 전부 아래 명령으로 다시 잴 수 있다. 날짜가 붙지 않은 수치는 이 문서에 없다.

### 1.1 서빙 크기 — 라이브 wire capture, 2026-08-21

`<base-path>/wire-capture/2026-08/21*.jsonl` 의 `kind = "request"` 행 4,032건 (keeper 35명).
각 행은 런타임이 실제로 보낸 `tool_count`, `tool_schema_bytes`, `system_prompt`,
`extra_system_context_bytes` 를 담는다.

| 항목 | 값 |
|---|---|
| 도구 개수 | 100 또는 101 (4,032행 중 두 값뿐) |
| 도구 스키마 바이트 | 중앙값 78,916 / 최소 78,312 / 최대 79,512 |
| 시스템 프롬프트 바이트 | 중앙값 1,572 / 최소 1,122 / 최대 2,703 |
| 턴 컨텍스트(`extra_system_context`) 바이트 | 중앙값 23,782 / p90 53,550 / 최대 92,574 |
| 도구 ÷ 시스템 프롬프트 | 50.2배 (중앙값) |
| 도구 ÷ (시스템 프롬프트 + 턴 컨텍스트) | 3.15배 (중앙값) |

Keeper 별로 갈라 봐도 전원이 같은 두 조합(101/79,512 · 100/78,448)만 받는다. 도구 표면은
Keeper 와 무관한 상수다.

```sh
python3 - <<'PY'
import json,glob,statistics as st
rows=[json.loads(l) for f in glob.glob('<base-path>/wire-capture/2026-08/21*.jsonl') for l in open(f)]
req=[r for r in rows if r.get('kind')=='request']
print(len(req), st.median(r['tool_schema_bytes'] for r in req), st.median(len(r['system_prompt']) for r in req))
PY
```

`test_keeper_tool_schema_bytes` 의 천장은 80,000 바이트다. 라이브 최대 79,512 는 그 천장의
99.4% 로, 다음 도구 하나가 ratchet 을 깬다.

### 1.2 실사용 — `tool_calls` 스토어, 2026-08-20 ~ 21

`<base-path>/tool_calls/2026-08/{20,21}.jsonl` 5,958 호출, keeper 75명 (canary 포함).

| 항목 | 값 |
|---|---|
| Keeper 한 명이 실제로 부른 도구 종류 | 최소 1 / 중앙값 7 / 최대 34 |
| 전체에서 한 번이라도 불린 도구 | 71 / 101 |
| 호출의 95% 를 덮는 도구 수 | 23 |
| 상위 5 | `Execute` 1,116 · `keeper_tasks_list` 902 · `masc_board_post_get` 582 · `Read` 518 · `masc_task_history` 477 |

이 스토어는 Keeper 턴의 호출만 기록한다. 외부 MCP 클라이언트 전용 도구(`masc_broadcast`,
`masc_keeper_msg`, `masc_tasks` 등 7종)는 여기 0건이어도 미사용이 아니다 —
`docs/evidence/keeper-tool-surface-cost-2026-08-19.json` 의 `store_scope_caveat` 가 실측으로
보인 함정이다. "안 쓰이니 빼자" 는 이 스토어로 판정할 수 없고, 이 RFC 도 그렇게 판정하지
않는다. 판정은 Keeper 가 선언한다.

### 1.3 구성 — 설명문은 표면의 10~20%

2026-08-19 측정(`docs/evidence/keeper-tool-surface-cost-2026-08-19.json`, `served_surface`):
외부 클라이언트에 서빙되는 44개 기준 `description` 2,969 바이트 대 `inputSchema` 27,136 바이트.
설명문을 줄이는 것으로는 표면의 10% 남짓이고, 비용은 스키마 구조에 있다. 도구 하나를 빼야 그
구조가 같이 빠진다 (도구당 평균 약 780 바이트).

### 1.4 지금 구조

```ocaml
(* keeper_tool_descriptor.ml *)
let model_visible_schemas () = ...
```

인자가 없다. Keeper 를 구분할 자리가 없으므로 전원이 같은 목록을 받는다.

```ocaml
type keeper_tool_group =
  | Execute_group | Search_files_group | Filesystem_group | Board_group
  | Voice_group | Workspace_group | Surface_group | Memory_group
  | Meta_group | Core_group
```

그룹은 이미 모든 서술자에 붙어 있다 (`keeper_tool_group_of_runtime_handler`). 지금은 진단
JSON 에만 실리고 가시성에는 관여하지 않는다. `keeper_model_names` 는 서술자당 이름을 최대
하나 내고 `Transport_alias` / `Operator_only` 는 빈 목록이라, 별칭 중복 제거로 얻을 바이트는
없다.

### 1.5 이미 있는 선언형 표면 — 이 RFC 가 그 위에 얹힌다

도구 표면의 일부는 이미 코드 밖에서 선언된다.

- `runtime.toml [[skills.sources]]` 아래 `SKILL.md` — 본문의 composition fence를
  `Keeper_tool_composition_catalog`가 파싱한다. 각 effective composition skill이
  `keeper_compose_<name>` 도구로 올라가고, 비동기 합성이 하나라도 있으면 status/cancel
  도구 2개가 더 붙는다. 독립 `tool-compositions.toml` 경로는 삭제됐다.
- `keeper_plan_execute` (`keeper_tool_composition_surface.ml`) — 모델이 즉석에서 DAG 를 짜서
  도구를 합성·병렬 실행하는 도구.

§1.1 의 100/101 은 이 합성 도구들을 포함한 숫자다. `model_visible_schemas ()` 만 세면 서술자
98개고, 카탈로그 도구가 위에 더해진다. 따라서 Keeper 별 표면은 서술자 그룹과 카탈로그 항목을
**같은 선언**에서 골라야 한다. 둘을 따로 관리하면 "그룹은 잘랐는데 합성 도구가 그룹 밖 도구를
부른다" 는 모순이 생긴다.

## 2. 이 RFC 가 주장하지 않는 것

masc#29337 은 GLM-5-Turbo 가 `tool_use` 이름 자리에 인자를 섞어 보내고 한 턴에서 88번
회복하지 못한 건이다. 표면 크기가 그 방아쇠라는 가설을 세우고 라이브로 쟀다
(`docs/evidence/keeper-canary-10t-*-2026-08-20.json`, 캐너리 `canary-10t-cdx-*-20260820`).

| 가설 | 시행 | 재현 |
|---|---|---|
| 도구 개수 (1 / 10 / 25 / 50 / 101개, 최대 90KB) | 25 | 0 |
| 컨텍스트 길이 (35k / 67k / 114k prompt tokens) | 9 | 0 |
| 오염된 호출이 이미 히스토리에 있음 (1회 / 4회, 카탈로그 유/무) | 20 | 0 |

**54회 중 0회.** 표면 크기와 그 사고를 잇는 근거는 없다. 이 RFC 의 근거는 비용(§1.1)이지 그
사고가 아니다. #29337 은 열어 둔다.

## 3. 제안

### 3.1 선언 — Keeper TOML

```toml
# <config-root>/keepers/<name>.toml
[keeper.tools]
groups = ["board", "workspace", "memory"]        # keeper_tool_group 의 wire 이름
skills = ["mission-snapshot"]                    # configured Skill name
```

- `groups` 는 `keeper_tool_group_to_string` 과 1:1 인 닫힌 enum 이다. 모르는 이름은 TOML
  로드 에러다 (`Keeper_types_profile` 의 unknown-key 정책과 같다).
- `skills` 는 effective Skill snapshot의 `name`과 1:1 이다. 없는 이름은 로드 에러다.
- `Core_group` 과 `Meta_group` 은 항상 포함한다. 자기기술 도구(`masc_tool_help`,
  `keeper_tools_list`) 없이 Keeper 가 표면을 되짚을 방법이 없기 때문이다.
- `[keeper.tools]` 테이블이 **없으면 전체 표면** 이다. 지금과 같은 동작이고, 조용한 기본값이
  아니라 resolved profile 에 `tools = "all"` 로 적혀 대시보드와 `keeper_status` 에 보인다.
  선언 없는 Keeper 를 부팅 거부하는 안은 버린다 — 하드 게이트이고, 저장소 방향(기본은 열어
  두고 제약은 실익이 분명할 때만)과 어긋난다.

### 3.2 해석 — 한 함수

```ocaml
val model_visible_schemas
  :  surface:Keeper_tool_surface.t          (* TOML 에서 파싱된 합타입 *)
  -> Masc_domain.tool_schema list
```

`Keeper_tool_surface.t` 는 `All | Declared of { groups : keeper_tool_group list; skills : string list }` 다.
`Declared` 의 합성 항목이 부르는 노드 도구가 `groups` 밖이면 로드 시점에 에러다 (§1.5 의
모순을 선언 시점에 막는다). 런타임 문자열 매칭은 없다.

### 3.3 가시성 — 표면은 턴 시작에 고정

표면은 턴 시작에 한 번 계산해 그 턴의 모든 provider 요청에 같은 배열로 나간다. 턴 중간에
붙였다 떼지 않는다 (캐시·재현성).

## 4. 결정해야 할 항목

1. **그룹 밖 도구를 부르면.** 지금은 `Tool not found` 가 나간다 (#29338 에서 목록을 뺐다).
   그룹 밖 호출은 "없는 도구" 와 다른 사실이므로 typed 실패 `Tool_outside_surface` 로
   구분하고, 문구는 Keeper 가 자기 TOML 을 고칠 수 있게 선언 위치를 가리킨다.
2. **발견 경로.** `keeper_tools_list` 는 전체를 보여주되 각 항목에 `in_surface: bool` 을
   싣는다. 자기 그룹만 보이면 Keeper 가 "필요한데 없는 도구" 를 알 수 없다.
3. **대시보드.** Keeper 상세에 resolved surface(그룹·합성·도구 수·바이트)를 싣는다.
   §1.1 의 wire capture 필드가 이미 있으므로 Keeper 별 `tool_schema_bytes` 시계열은 추가
   생산자 없이 그릴 수 있다.

## 5. 검증 — 구현 PR 이 만족해야 할 것

- `test_keeper_tool_schema_bytes` 를 `All` 과 그룹 조합 3개 이상에 대해 재며, 조합별 바이트를
  같이 고정한다. 전체 ratchet(80,000) 은 유지한다.
- wire capture 로 본 Keeper 별 `tool_schema_bytes` 가 선언과 일치한다는 라이브 증거 1일치
  (`<base-path>/wire-capture/…` 의 request 행, keeper 별 중앙값 표).
- 모르는 그룹 이름 / 카탈로그에 없는 합성 이름 / 그룹 밖 노드를 부르는 합성 — 셋 다 TOML
  로드 에러라는 테스트.
- 그룹 밖 도구를 부른 턴이 `Tool_outside_surface` 로 끝나고 `Tool not found` 와 구별된다는
  테스트.
- `keeper_tool_group_of_runtime_handler` 가 모든 서술자에 대해 exhaustive 임을 컴파일 타임에
  강제한다 (지금도 그렇지만, 가시성 축이 되면 누락의 대가가 달라진다).

## 6. 하지 않을 것

- 설명 문구 줄이기. §1.3 대로 표면의 10~20% 이고, 문구는 모델이 도구를 고르는 근거다.
  크기를 이유로 깎으면 선택 품질과 맞바꾸게 된다.
- `tool_calls` 스토어의 호출 수로 도구를 자동 제외하기. §1.2 의 스토어 범위 때문에 외부
  클라이언트 전용 도구가 전부 미사용으로 오분류된다. 표면은 선언으로만 줄어든다.
- 도구를 동적으로 붙였다 떼기 (§3.3).

## 7. 적용 기록 — 2026-08-29 라이브 선언

§3 의 기계(합타입·TOML 파서·`model_visible_schemas ~surface`·대시보드 투영)는 이 날짜
이전에 이미 main 에 있었다. 빠져 있던 것은 선언이었다 — 라이브 Keeper 9기 전원이
`[keeper.tools]` 테이블 없이 돌아 전원 `All` 이었다.

2026-08-29 에 라이브 `<config-root>/keepers/*.toml` 9기 전부에
`groups = ["execute","search_files","fs","board","workspace","surface","memory","meta","core"]`
(voice 제외 — 함대 8월 호출 0~7회) 를 선언했다. 관측:

- **재기동 불필요.** 선언형 keeper 발견 루프가 수정된 TOML 을 다음 주기에 집었고,
  polisher 카나리의 turn surface 가 139개/130,991B → 133개/128,298B 로 떨어졌다
  (wire-capture request 행, 08:26 UTC). 이후 함대 전체 127개/124,631B 로 수렴.
- **테이블 위치 함정.** `[keeper.tools]` 를 `[keeper]` 의 bare key 들(특히
  `instructions`) 앞에 두면 TOML 규칙상 그 키들이 tools 테이블로 붙어
  `unknown keeper TOML keys: keeper.tools.instructions` 로 로드가 거부된다.
  파서는 설계대로 fail-closed 였고 keeper 는 이전 meta 로 계속 동작했다.
  테이블은 파일 끝에 둔다 (config/keepers/ 프리셋 4기에 같은 형태로 반영).
- **바이트의 본체는 이 축 밖에 있었다.** 같은 날 실측에서 표면 133KB 중 48KB 가
  부착 서비스(github 44종) 도구였고, 이는 identity 카탈로그
  (`<base-path>/identity/catalogs/<keeper>/<provider>.json`) 가 정하며 이 RFC 의
  그룹 선언이 관여하지 않는다. 부착 스코핑은 별도 축이다.
