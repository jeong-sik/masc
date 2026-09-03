---
rfc: "0411"
title: Skill 카탈로그가 참조 대신 이름을 싣는다
status: Draft
created: 2026-09-04
author: Claude Opus 5
supersedes: []
superseded_by: null
related: ["0042"]
---

## 0. 한 줄 요약

`keeper_skill` 도구 서술의 `Available:` 블록은 스킬마다 정확 참조 전체(64hex
`content_revision` 포함)를 싣는다. 매 턴 3,685바이트다. 회수는 0.0072회/턴.
이 문서는 그 블록에서 참조를 덜어내고 이름으로 부르게 하는 것, 그리고 그때
필요한 이름 충돌 규칙을 정한다.

## 1. 실측

라이브 base-path `/Users/dancer/me`, 2026-09-04.

### 1.1 비용

`keeper_tool_composition_surface.ml:72` `instruction_skill_description`:

```ocaml
skill_tool_schema.description ^ "\n\nAvailable:\n" ^ listed
```

`listed` 는 스킬마다 한 줄이고, 그 줄은
`Skill_reference.to_yojson skill.reference |> Yojson.Safe.to_string` 로 시작한다.
즉 `source_id` / `package_id` / `name` / 64hex `content_revision` 이 전부 들어간다.

라이브 카탈로그(`/api/v1/skills`, 스킬 10개)로 같은 문자열을 재구성해 재면:

| | 바이트 |
|---|---:|
| `Available:` 블록 전체 | 3,685 |
| 스킬당 | 368 |
| 그중 참조 JSON | 185 |

`Yojson.Safe.to_string` 은 공백 없이 낸다. 위 값은 그 형식으로 계산했다.
참조 185B/스킬은 `#31324` 가 적은 값과 정확히 같다.

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

## 4. 제안

### 4.1 서술

`Available:` 블록의 각 줄을 참조 JSON 대신 이름으로 시작한다.

```
Available:
ci-red-attribution: PR 이 빨간데 내 변경 탓인지 ...
work-intake: See the clock, your open tasks, ...
```

스킬당 185바이트가 줄어 블록이 약 1.9KB 가 된다.

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
- task 선택 경로(`masc_add_task` 의 `skills`). 이 RFC 는 건드리지 않는다.
- 조합 도구(`keeper_compose_<skill>`). 그쪽은 이름이 도구 이름이라 이미
  참조를 안 싣는다.

## 6. 검증

조치 전후를 같은 방법으로 잰다.

| 지표 | 방법 | 기준선 |
|---|---|---|
| `Available:` 바이트 | 라이브 카탈로그로 블록 재구성 | 3,685 B |
| 스킬 계열 호출/턴 | `tool_calls/*.jsonl` 의 `tool` 필드 | 0.0072 |
| 참조 누락 거부 | system log 의 keeper_skill 거부 | polisher 사례 1건 |

호출/턴이 오르지 않으면 이 RFC 는 비용만 줄인 것이다. 그것도 결과이므로 그렇게
기록한다 — 마찰이 원인이 아니었다는 뜻이 된다.

## 7. 선행 조건

`#32953` 이 먼저다. 지금 스킬 호출의 62%가 `keeper_compose_work-intake` 이고
8/8 실패한다. 실패 원인은 `#32966` 이 배포돼야 읽을 수 있다. 고장난 도구를 둔
채 마찰을 줄이면, 줄어든 마찰로 더 자주 실패하게 된다.

## 8. 대안과 그 이유

- **목록 도구(`skills_list()`)로 미루기.** Hermes 와 Anthropic Tool Search 의
  방식이고 3,685B 를 전부 없앤다. 다만 지금 회수가 0.0072회/턴인데 왕복을 하나
  더 세우면 더 줄 수 있다. §4 를 먼저 하고 회수를 본 뒤에 판단한다.
- **프롬프트에 카탈로그 블록 추가.** 도구 서술이 이미 같은 일을 한다. 두 번
  싣는 것이고 `#32935`·`#32939` 의 컨텍스트 압력과 부딪힌다.
- **아무것도 안 하기.** 매 턴 3,685B 는 키퍼 11명이 계속 낸다. 회수가 낮은
  것과 별개로, 비용의 절반이 호출부가 알 필요 없는 값이라는 점은 남는다.

## 9. 근거

- 실측과 외부 대조: `docs/research/2026-09-04-skill-activation-research-r1.md`
- 근거 기록: `docs/research/2026-09-04-skill-activation-evidence-record.md`
- 이슈: `#32944` (교환), `#32953` (고장난 조합), `#31324` (참조 바이트)
