---
rfc: "0393"
title: "이름 안에 인코딩된 keeper 신원을 제거한다 — 관계는 데이터로, 이름은 하나로"
status: Draft
created: 2026-08-27
updated: 2026-08-27
author: claude
supersedes: []
superseded_by: null
related: ["0392"]
implementation_prs: []
---

# RFC: 이름 안에 인코딩된 keeper 신원을 제거한다

Status: Draft

## Problem

keeper 하나의 신원이 문자열 인코딩 세 겹으로 표현된다.

1. **keeper_name** — `taskmaster`. registry, meta store, queue 의 키.
2. **장식 agent 이름** — `Printf.sprintf "keeper-%s-agent" name` (`lib/core/keeper_name_codec.ml:53`).
   keeper 가 board·chat·timeline 같은 agent 공용 평면에 나타날 때 쓰는 이름.
3. **nickname** — `<agent_type>-<형용사>-<동물>` 모양. `Nickname.extract_agent_type` 으로
   이름을 쪼개 keeper 이름을 되찾는 경로가 `lib/keeper/keeper_identity.ml:35-47` 에 있다.

관계(이 agent 는 어느 keeper 인가)를 저장소가 아니라 **이름 문자열 안에** 넣었기 때문에,
되찾는 쪽은 전부 substring 파싱이다. 파서는 복사되고, 복사본은 어긋난다.

### 실측된 사고 3건

| 사고 | 내용 |
|---|---|
| RFC-0371 B12 | lib/keeper 와 lib/workspace 가 각자 파서 복사본을 들고 있었고, workspace 쪽이 underscore 철자를 조용히 놓쳤다. 수리로 `Keeper_name_codec` 을 만들어 파서를 한 곳에 모았다 (2026-04). |
| auth_token_resolve_error 폭풍 | `keeper-<id>-agent` 가 a-b-c 모양이라 관대한 nickname 분류기가 이를 nickname 으로 오분류했다 (`lib/workspace/nickname.mli:11-16` 주석이 기록). **인코딩 두 겹이 서로 충돌한 사고.** |
| #31042 913-retain (2026-08) | wake payload 의 `keeper_name` 자리에 장식 agent 이름이 들어와 queue 키와 어긋났고, durable schedule 이 913회 연속 retain 됐다. 경계 정규화로 수리. |

파서를 한 곳에 모은 2026-04 수리(1번째 fix) 뒤에도 같은 부류가 2026-08 에 재발(#31042,
2번째 fix)했다. **문자열 층위에서는 파서를 아무리 모아도, 잘못된 철자가 흐르는 것
자체를 막을 수 없다.** 양쪽 다 `string` 이라 컴파일러가 침묵하기 때문이다.

### 파서·조립기가 흩어져 있는 자리

| 파일 | 내용 |
|---|---|
| `lib/core/keeper_name_codec.ml` | 허용 철자 4종 표(`keeper-`/`-agent`, `keeper_`/`_agent`, 혼합 2종), prefix strip, sprintf 조립 |
| `lib/keeper/keeper_identity.ml:31-47` | affix 파싱 + nickname 복원이 얽힌 6분기 판별 |
| `lib/tool_agent.ml:74-89` | 자체 `parse_wrapped_agent_name` 3콤보 + sprintf 조립 |
| `lib/server/server_auth.ml:172-177` | strip 두 번 + sprintf 재조립 |
| `lib/workspace/workspace_task_receipts.ml:37` | bare `-agent` suffix strip — 주석 스스로 "NOT identity" |
| `lib/config/playground_paths.ml:42` | prefix/suffix strip |
| `bin/deployment_preflight_helper.ml:800` | `starts_with ~prefix:"keeper-"` 로 keeper 분류 |

이 표면을 소비하는 파일은 lib 28 + test 59 = **88개**다.

### 이미 데이터는 있다

- keeper meta json 에 `agent_name` 필드가 **typed 데이터로 이미 저장**돼 있다
  (라이브 `keepers/adm-race-cf-001.json` 확인: `agent_name = "keeper-adm-race-cf-001-agent"`).
- `Keeper_meta_store.persisted_keeper_name_for_agent_name`, `Keeper_identity_binding.resolve`
  는 그 필드를 **조회**하는 데이터 기반 역방향이다. #31042 수리가 쓴 경로가 이것이다.

즉 관계를 알 수 있는 정상 경로(저장된 binding)가 이미 있는데, 파서들이 그걸 쓰지 않고
문자열을 뜯는다.

### 4철자 중 3철자는 유령이다

라이브 board 작성자 census (2026-08-27, `~/me/.masc/board_posts.jsonl`):
관측된 철자는 `keeper-X-agent` 단일. underscore 계열 3종은 board·agents store 에서 0건.
codec 의 4철자 표는 존재하지 않는 입력을 방어하고 있다.

## Decision — hard cut

마이그레이션·호환 reader 없이 인코딩을 전부 제거한다. 원칙은 한 문장:
**관계는 데이터로, 이름은 하나로.**

- **D1. keeper 는 어디서나 keeper_name 으로 등장한다.** 장식 이름 조립
  (`sprintf "keeper-%s-agent"`)을 제거한다. board 작성자, chat 발화자, timeline actor,
  agent 목록 전부 `taskmaster` 그대로.
- **D2. 파서를 전부 삭제한다.** `Keeper_name_codec` 모듈 자체,
  `keeper_identity` 의 `canonical_keeper_name_from_agent_name` ·
  `is_keeper_agent_alias` · `is_keeper_principal_agent_name` 과 nickname 복원 분기,
  `tool_agent` 의 wrapped 파서, `server_auth` · `workspace_task_receipts` ·
  `playground_paths` 의 strip, preflight 의 `starts_with "keeper-"` 분류.
  substring · prefix · suffix · 조건부 매직스트링을 하나도 남기지 않는다.
- **D3. "이 actor 는 keeper 인가"는 이름 모양이 아니라 binding 조회로 판정한다.**
  live registry → persisted meta. 이미 있는 함수들이며, 새 기전을 만들지 않는다.
- **D4. agent 등록 경계에서 이름 충돌을 거부한다.** 외부 agent 가 기존 keeper 이름으로
  join 하면 에러. 신원 유일성은 durable truth 이므로(귀속이 영구 오염된다) 이 gate 는
  Autonomy 원칙의 예외 조건을 충족한다.
- **D5. nickname 은 비-keeper agent 표시용으로만 남는다.** `extract_agent_type` 으로
  keeper 를 복원하는 사용처를 삭제한다. keeper-backed 세션이 nickname 으로 join 하는
  경로가 있다면, join 시점에 binding 을 기록한다 — 나중에 파싱하지 않는다.
- **D6. meta 의 `agent_name` 필드를 삭제한다.** D1 이후 이 필드는 항상 `name` 과 같은
  값이 되므로 중복이다. strict decoder 특성상 필드 제거는 배포 이벤트다 — 구현 PR 과
  배포를 동기화한다.
- **D7. 과거 기록은 재해석하지 않는다 (fresh-state contract).** board · ledger · receipts
  에 남은 `keeper-sangsu-agent` 873건 등은 그냥 과거의 작성자 문자열이다. 어떤 reader 도
  이를 keeper 로 되짚지 않으며, converter 를 만들지 않는다. 새 기록부터 keeper_name.

### 하지 않는 것

- 장식 철자를 이해하는 fallback · 호환 reader · 전환기 (금지 — 이 RFC 의 존재 이유)
- 이름 모양 기반 keeper 분류를 어딘가 한 곳이라도 존치
- 과거 데이터 rewrite

## 구현

단일 PR, compiler-driven. 함수와 모듈을 먼저 삭제하면 컴파일 에러가 호출자 88파일을
전수 노출한다. 각 사이트는 셋 중 하나로 수렴한다:

1. binding 조회로 대체 (`Keeper_registry` / `Keeper_meta_store` / `Keeper_identity_binding`)
2. 이름을 변환 없이 그대로 사용
3. 인코딩 전제 코드였다면 코드째 삭제

같은 변환을 사이트별로 나눠 여러 PR 로 흘리지 않는다(N-of-M 금지). 삭제가 전 사이트를
한 번에 강제하는 것이 이 방식의 요점이다.

## 검증

- 삭제 심볼 0참조 — 컴파일이 증명한다.
- 종단 테스트 3종: (a) keeper join → board 작성자가 keeper_name (b) keeper_name 으로
  wake 가 owner queue 에 도달 (c) 기존 keeper 이름으로 외부 agent join 시 거부.
- 전체 스위트 + merged tree `@check`.
- 배포 후 라이브 확인: 새 board post 의 작성자 필드, keeper wake 스케줄 1건 왕복.

## Out of scope

- provider 별 외부 신원 (RFC-0392)
- nickname 생성기 자체 — 비-keeper agent 용으로 존속
- agent 평면의 인증 체계 개편 — 토큰이 장식 이름에 결박된 부분은 재발급으로 해소하며,
  구현 중 확인해 PR 본문에 기록한다

## Open questions

- `keeper_chat` · receipts 등 다른 store 의 키가 장식 이름인 곳의 목록 — 구현 중
  컴파일 에러와 store 경로 조사로 확정한다. fresh-state 원칙은 동일하게 적용.
- 러닝 keeper 의 재조인 — 배포가 non-autoboot keeper 를 내리는 기존 특성에 흡수되는지
  구현 시 확인한다.

## 근거 기록

- 확인 명령: 소비 파일 census `rg -l "canonical_keeper_name_from_agent_name|…" lib bin test`
  (88), 라이브 철자 census `rg -o "keeper[-_]…[-_]agent" ~/me/.masc/board_posts.jsonl`
  (dash 철자만 관측), meta 필드 `jq keys keepers/adm-race-cf-001.json` (`agent_name` 존재).
- 확인일: 2026-08-27. Confidence: High (전부 이 저장소와 라이브 store 에서 직접 측정).
