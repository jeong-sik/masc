---
rfc: "0411"
title: Skill 카탈로그가 참조 대신 이름을 싣는다
status: Draft
created: 2026-09-04
updated: 2026-09-07
author: Claude Opus 5
supersedes: []
superseded_by: null
related: ["0042", "skills-as-tools"]
---

## 0. 한 줄 요약

`keeper_skill` 도구 서술의 `Available:` 블록은 스킬마다 정확 참조 전체(64hex
`content_revision` 포함)를 싣는다. masc 자신이 재는 발견 비용이 매 턴
3,383바이트이고 그중 55%가 참조다. 회수는 0.0072회/턴.
이 문서는 그 블록에서 참조를 덜어내고 이름으로 부르게 하는 것, 그리고 그때
필요한 이름 충돌 규칙을 정한다.

## 1. 실측

라이브 base-path `/Users/dancer/me`, 2026-09-04.

### 1.1 비용 — masc 자신이 재고 있다

`GET /api/v1/skills` 의 `surfaces[].profile.context` 가 스킬마다 이미
`discovery_bytes` / `tool_schema_bytes` / `body_bytes` 를 낸다. 손으로 재구성할
필요가 없다.

| 스킬 | discovery_B | schema_B | body_B | 노드 | 배치 |
|---|---:|---:|---:|---:|---:|
| verify-before-claiming-done | 565 | 0 | 2,334 | | |
| root-cause-first | 491 | 0 | 2,857 | | |
| tui-pty-scenario | 444 | 0 | 2,200 | | |
| turn-opening | 380 | 0 | 982 | | |
| ci-red-attribution | 355 | 0 | 2,180 | | |
| ocaml-coding | 331 | 0 | 8,359 | | |
| skill-authoring | 264 | 0 | 1,337 | | |
| mission-snapshot | 196 | 196 | 1,094 | 4 | 2 |
| work-intake | 186 | 186 | 888 | 3 | 2 |
| background-snapshot | 171 | 171 | 643 | 2 | 1 |
| **합** | **3,383** | **553** | **22,874** | | |

매 턴 **3,383바이트**가 발견 비용이고, 조합 스킬 3개가 도구 스키마로 **553바이트**를
더 쓴다. 본문 22,874바이트는 부를 때만 온다 — 점진 공개는 동작하고 있다
(`ci-red-attribution` 은 발견 355B 로 본문 2,180B 를 가린다, 16%).

비용의 정체는 `keeper_tool_composition_surface.ml:72`
`instruction_skill_description` 이 만드는 `Available:` 블록이다.

```ocaml
skill_tool_schema.description ^ "\n\nAvailable:\n" ^ listed
```

`listed` 의 각 줄은 `Skill_reference.to_yojson ... |> Yojson.Safe.to_string` 로
시작한다. 즉 `source_id` / `package_id` / `name` / 64hex `content_revision` 이
전부 들어간다. 라이브 카탈로그로 계산하면 그 참조 JSON 만 **스킬당 185바이트**,
10개면 1,854바이트다. 발견 비용 3,383 중 **55%** 가 참조다.

185B/스킬은 `#31324` 이 적은 값과 정확히 같다.

### 1.2 회수

`.masc/tool_calls/2026-09/03.jsonl`, `tool` 필드 집계.

| 지표 | 값 |
|---|---:|
| 도구 호출 | 8,236 |
| 턴 | 1,796 |
| 스킬 계열 호출 | 13 |
| 턴당 | **0.0072** |

내역: `keeper_compose_work-intake` 8 (전부 실패), `keeper_compose_mission-snapshot`
2, `keeper_compose_background-snapshot` 1, `keeper_skill` 2.

### 1.3 마찰의 증거

polisher 의 메모리 행:

> keeper_skill rejected the ci-red-attribution read for omitting
> content_revision and succeeded when the same call was reissued with it, so
> always include content_revision in keeper_skill calls.

키퍼가 계약을 배우는 데 실패 한 번을 썼고, 그 교훈을 메모리에 적어 매 턴
싣고 있다. 계약이 학습 비용을 만들고 있다.

### 1.4 사흘 뒤 재측정 (2026-09-07)

같은 API, 같은 base-path.

| | 2026-09-04 | 2026-09-07 |
|---|---:|---:|
| 스킬 | 10 | 14 |
| 발견 바이트 합 | 3,383 | **4,691** |
| 본문 바이트 합 | 22,874 | 45,662 |
| 도구 스키마 바이트 | 553 | 855 |

사흘에 **+39%**. 이 비용은 카탈로그 크기에 비례하므로, 스킬을 늘릴수록 늘어난다.
스킬을 더 쓰게 하려는 노력과 이 비용은 같은 방향으로 움직인다.

### 1.5 채택 — 참조 요구가 아래쪽에서 무엇을 막았나

§1.2 는 회수(호출/턴)를 쟀다. 그 아래에 한 층이 더 있다.

원장 `.masc/traces/*/skill-activations.json` 전수, 08-29 ~ 09-07:

| | 건수 |
|---|---:|
| 활성 전체 | 559 |
| `Session_composition` + `Session_instruction` | 559 |
| **`Task_composition` + `Task_instruction`** | **0** |

태스크 아카이브 `.masc/tasks-archive.json` 292건 중 **`skills` 를 단 것은 0건**이다.
그중 126건은 `skills` 파라미터가 이미 있는 `masc_add_task` 로 만들어졌다.

`.masc/skills` 14개 중 **한 번도 돌지 않은 것이 5개** — `systematic-debugging`,
`verify-before-claiming-done`, `frontend-design`, `plan-intake`, `msx-play`.

설명이 나빠서가 아니다. `systematic-debugging` 의 설명은 *"Use when encountering any
bug, test failure, or unexpected behavior, before proposing fixes"* 로 "무엇 + 언제" 를
갖췄다. 키퍼별 게이트도 아니다 — 라이브 키퍼 19개 중 `skill_names` 를 가진 것이 없고,
`keeper_effective_tool_surface.mli:40` 이 *"[None] means all"* 이라고 말한다.

남는 설명은 하나다. **스킬을 태스크에 달려면 sha 를 손으로 적어야 한다.** §2 의 계약이
호출부에만 있는 것이 아니라 태스크 생성에도 그대로 걸려 있다 (`masc_add_task` 의 `skills`
파라미터: *"pins source, package, canonical Skill name, and exact SKILL.md content
revision"*).

§1.3 은 키퍼가 계약을 배우는 데 실패 한 번을 쓴 사례였다. §1.5 는 **아무도 배우지 않은
쪽**이다 — 292번 태스크를 만들면서 한 번도.

## 2. 왜 참조가 서술에 있는가

`config/tools/keeper_skill.toml` 은 `identity`(source_id/package_id/name)와
`content_revision` 을 모두 required 로 선언한다. 호출자가 그 값을 어딘가에서
얻어야 하므로 서술이 알려준다.

이 설계의 이점은 분명하다 — 호출이 어떤 본문을 읽었는지가 호출 자체에 박힌다.
재현이 호출부에서 닫힌다.

## 3. 그런데 재현은 이미 다른 곳에 있다

- 스냅샷 revision: `Skill_catalog_snapshot.snapshot_revision`. 그 턴의 카탈로그
  전체가 어느 상태였는지 고정한다.
- 활성화 원장: `Keeper_skill_activation_ledger` 가 어떤 참조가 실제로 서빙됐는지
  기록한다.

즉 "무엇이 쓰였는가"는 호출부가 말하지 않아도 남는다. 호출부가 미리 알아야
하느냐는 별개 문제다.

skillfold 가 같은 구분을 한다 — exact revision 은 lockfile 에 핀하고 호출부는
이름만 쓴다. Anthropic Agent Skills 의 discovery 단계도 name + description 만
싣는다.

### 3.1 masc 자신의 Active RFC 가 이미 그렇게 적었다 (2026-09-07 추가)

`RFC-skills-as-tools` (Active, 2026-08-25) §0:

> 지시 스킬 본문은 매 턴 싣지 않고, **이름과 설명만 담은 고정 `keeper_skill` 도구**를
> 통해 필요할 때 읽는다.

"이름과 설명만" 과 "고정" 이 둘 다 적혀 있다. 즉 이 RFC 의 §4 는 새 설계가 아니라
**Active RFC 가 명시한 모양으로 돌아가는 것**이다. 구현이 두 방향으로 흘렀다 —
서술에 참조가 들어가 커졌고(§1.1, §1.4), 커지자 고정이 아니게 되었다(§8.1).

Anthropic 공식 문서의 Level 1 도 같은 모양이고, 시스템 프롬프트에 실리는 줄은 문자
그대로 `name - description` 이다.

> `pdf-processing - Extract text and tables from PDF files, fill forms, merge
> documents. Use when working with PDF files or when the user mentions PDFs, forms,
> or document extraction.`

부르는 것도 이름이다 (`bash: cat pdf-processing/SKILL.md`). 공식 모델에는 호출부가
revision 을 아는 단계가 없다.

## 4. 제안

### 4.1 서술

`Available:` 블록의 각 줄을 참조 JSON 대신 이름으로 시작한다.

```
Available:
ci-red-attribution: PR 이 빨간데 내 변경 탓인지 ...
work-intake: See the clock, your open tasks, ...
```

스킬당 185바이트가 줄어 발견 비용이 3,383 → 약 1,529바이트가 된다. 55% 감소.

### 4.2 호출

`keeper_skill` 의 `content_revision` 을 required 에서 optional 로 내린다.
빠지면 서버가 **그 턴의 스냅샷이 고정한 revision** 으로 해석한다. 새 revision 을
고르는 것이 아니라, 이미 그 턴에 고정된 것을 쓴다. `identity` 는 유지한다.

전달된 `content_revision` 이 스냅샷과 다르면 지금처럼 거부한다 — 명시한 값을
조용히 바꾸지 않는다.

### 4.3 이름 충돌

소스가 4개이므로 이름은 유일하지 않을 수 있다. 규칙을 정한다.

1. task 가 고른 스킬이 전역보다 앞선다 (`project_turn` 이 이미
   `task @ skills global` 순서로 후보를 만든다).
2. 전역 안에서 겹치면 소스 선언 순서가 앞선 쪽.
3. 그래도 겹치면 **이름만으로는 부를 수 없다**. 서술이 그 줄에만 참조를 적고,
   호출은 `content_revision` 을 요구한다.

3번이 중요하다. 모호한 것을 조용히 하나로 고르지 않는다. 모호할 때만 옛
계약으로 돌아간다.

## 5. 무엇을 바꾸지 않는가

- 원장이 기록하는 내용. 어떤 참조가 서빙됐는지는 그대로 남는다.
- 스냅샷 revision 고정. 턴 안에서 카탈로그가 움직이지 않는다.
- ~~task 선택 경로(`masc_add_task` 의 `skills`). 이 RFC 는 건드리지 않는다.~~
  **2026-09-07 정정:** 같은 계약이 그쪽에도 걸려 있다. `masc_add_task` 의 `skills` 도
  `content_revision` 을 요구하고, 그 결과가 §1.5 의 0/292 다. 이 RFC 가 호출부만
  고치고 태스크 생성을 남겨두면 §6 의 두 목표 지표는 0에 머무른다. 범위에 넣는다.
- 조합 도구(`keeper_compose_<skill>`). 그쪽은 이름이 도구 이름이라 이미
  참조를 안 싣는다.

## 6. 검증

조치 전후를 같은 방법으로 잰다.

| 지표 | 방법 | 기준선 |
|---|---|---|
| 발견 바이트 | `/api/v1/skills` 의 `surfaces[].profile.context.discovery_bytes` 합 | 4,691 B (09-07, 14개) |
| 스킬 계열 호출/턴 | `tool_calls/*.jsonl` 의 `tool` 필드 | 0.0072 (09-03) |
| 참조 누락 거부 | system log 의 keeper_skill 거부 | polisher 사례 1건 |
| 태스크 부착 | `.masc/tasks*.json` 의 `skills` 가 빈 배열이 아닌 태스크 수 | 0 / 292 |
| task 스코프 활성 | 원장의 `Task_instruction` + `Task_composition` | 0 / 559 |
| `keeper_skill` 비중 | 원장 활성 중 `invocation.kind = instruction` 비율 | 25% (지연 후) |

기준선을 두 벌 적는 이유는 §1.4 다 — 발견 바이트는 카탈로그가 커지면 같이 커지므로,
날짜와 스킬 수를 함께 적지 않은 값은 비교에 쓸 수 없다.

아래 두 줄이 이 RFC 의 실제 목표다. 발견 바이트만 줄고 이 둘이 0에 머무르면, 참조
요구는 원인이 아니었다는 뜻이 된다.

호출/턴이 오르지 않으면 이 RFC 는 비용만 줄인 것이다. 그것도 결과이므로 그렇게
기록한다 — 마찰이 원인이 아니었다는 뜻이 된다.

## 7. 선행 조건

`#32953` 이 먼저다. 지금 스킬 호출의 62%가 `keeper_compose_work-intake` 이고
8/8 실패한다. 실패 원인은 `#32966` 이 배포돼야 읽을 수 있다. 고장난 도구를 둔
채 마찰을 줄이면, 줄어든 마찰로 더 자주 실패하게 된다.

## 8. 대안과 그 이유

- **목록 도구(`skills_list()`)로 미루기.** Hermes 와 Anthropic Tool Search 의
  방식이고 3,383B 를 전부 없앤다. 다만 지금 회수가 0.0072회/턴인데 왕복을 하나
  더 세우면 더 줄 수 있다. §4 를 먼저 하고 회수를 본 뒤에 판단한다.
  **→ §8.1 참조. 이 판단은 이 문서가 쓰이기 하루 전에 이미 내려져 있었다.**
- **프롬프트에 카탈로그 블록 추가.** 도구 서술이 이미 같은 일을 한다. 두 번
  싣는 것이고 `#32935`·`#32939` 의 컨텍스트 압력과 부딪힌다.
- **아무것도 안 하기.** 매 턴 3,383B 는 키퍼 11명이 계속 낸다. 회수가 낮은
  것과 별개로, 비용의 절반이 호출부가 알 필요 없는 값이라는 점은 남는다.

### 8.1 그 대안은 이미 실행돼 있었다 (2026-09-07 추가)

`#32726` 이 **2026-09-03**, 이 문서가 쓰이기 하루 전에 `keeper_skill` 에
`defer_loading = true` 를 넣었다. 근거는 크기다.

> 이 도구는 3,695 B 를 매 요청에 싣고 176 턴(1.6%)에서만 필요했다 — 3.5x 이다.

지연은 도구 스키마를 미루고, **그 스키마 안에 목록이 있다**
(`tool_schemas_skill.mli`: *"the list of instruction skills it can read is whatever the
catalog found"*). 즉 §8 이 "회수를 보고 판단하자" 던 왕복 하나가 이미 서 있다.

같은 TOML 주석이 조회 도구는 지연하면 안 된다고 스스로 논증한다.

> 조회 도구는 … 지연하면 찾는 일 자체가 한 홉 멀어진다. 그 비용은 바이트로 잡히지
> 않는다. **이 도구는 조회가 아니다.**

마지막 문장이 쟁점이다. `keeper_skill` 은 본문을 읽는 도구지만 그 스키마가 곧
카탈로그라 조회를 겸한다. §4 가 참조를 덜어내면 이 도구는 이름+설명만 남고, 그때는
조회로서 상주하는 편이 자연스럽다.

원장 전후 (지연 09-03 기준):

| | 지연 전 (7일) | 지연 후 (5일) |
|---|---:|---:|
| `keeper_skill` 활성 | 224 | 18 |
| 전체 스킬 활성 | 487 | 72 |
| **`keeper_skill` 비중** | **46%** | **25%** |

전체 활성이 같은 기간 82% 줄어 절대 수치는 무게를 못 싣는다. 비중은 절반 가까이
줄었다. 표본이 5일이고 전체가 왜 줄었는지 확인하지 못했으므로 **인과의 증명이 아니라
방향의 일관성**으로만 쓴다.

## 9. 근거

- 실측과 외부 대조: `docs/research/2026-09-04-skill-activation-research-r1.md`
- 근거 기록: `docs/research/2026-09-04-skill-activation-evidence-record.md`
- 이슈: `#32944` (교환), `#32953` (고장난 조합), `#31324` (참조 바이트)
