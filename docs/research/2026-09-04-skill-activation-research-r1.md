# Skill 활성화 — 라이브 실측과 외부 설계 대조 (r1)

**정정 이력**: 이 문서의 첫 두 판은 "카탈로그가 키퍼에 안 닿는다"고 적었다.
틀렸다. 세 번째 판에서 바로잡는다 — 카탈로그는 닿는다. 프롬프트가 아니라
`keeper_skill` **도구 서술에** 실려서 닿고, 매 턴 3,765바이트를 쓴다.

## 요약

- 스킬 10개의 이름·설명·**정확 참조(64hex 포함)**가 `keeper_skill` 도구
  서술의 `Available:` 블록으로 매 턴 실린다. 3,765B, 스킬당 376B.
- 조합 스킬은 별도로 `keeper_compose_<skill>` 도구가 되어 스키마에 들어간다.
- 키퍼 프로필 `skill_names` 는 **좁히는 필터**다. 선언하지 않으면 전역 카탈로그가
  전부 들어온다. 즉 아무 키퍼도 스킬을 못 보는 상태가 아니다.
- 그런데 하루 도구 호출 8,236건 중 스킬 계열은 13건(0.16%)이고, 그중 8건은
  `keeper_compose_work-intake` 인데 **8건 다 실패**했다.

그래서 문제는 "어떻게 보이게 할까"가 아니라 **매 턴 3.7KB 를 내고 0.01회를
얻는 교환**이고, 그 위에 제일 많이 불리는 하나가 고장나 있다는 것이다.

## 1. 라이브 실측 (2026-09-04, base-path `/Users/dancer/me`, PID 81077)

### 기계는 멀쩡하다

`GET /api/v1/skills` → `state: "ready"`, 소스 4개, 스킬 10개, snapshot revision
고정. 오늘 난 `keeper_skill` 호출 2건은 둘 다 성공해서 2,180B / 8,359B 의 실제
본문을 돌려줬다.

### 프롬프트에 없다

키퍼 11명의 `last-prompt.json` (`assembled`) 에서 `skill` 을 셌다.

| 키퍼 | 프롬프트 바이트 | `skill` 등장 |
|---|---:|---:|
| code-reviewer | 89,023 | 0 |
| analyst | 58,871 | 0 |
| edgar.a.poe | 53,014 | 0 |
| pr-updater | 24,334 | 0 |
| jazz-developer · kidsnote-pr-jira-checker · microvm-probe-829 · rondo | | 0 |
| lane-smith · polisher · sangsu | | **1 (각각)** |

그 1건은 카탈로그가 아니라 키퍼가 스스로 적어둔 메모리 행이다. polisher 쪽:

> `[category=lesson recorded=2026-09-02T02:03:14Z origin=injected basis=observed]`
> keeper_skill rejected the ci-red-attribution read for omitting content_revision
> and succeeded when the same call was reissued with it, so always include
> content_revision in keeper_skill calls.

오늘 성공한 2건이 바로 이 경로다. 프롬프트가 알려준 게 아니라 키퍼가 기억하고
있던 참조를 다시 쓴 것이다.

### 하지만 도구 서술에는 있다 — 매 턴 3,765바이트

프롬프트가 아니라 도구가 카탈로그를 진다.

`keeper_tool_composition_surface.ml:72` `instruction_skill_description` 이
`keeper_skill` 도구의 서술을 이렇게 만든다.

```
<기본 스키마 설명>

Available:
{"identity":{"source_id":"project-masc","package_id":"...","name":"..."},"content_revision":"<64hex>"}: <설명>
... (스킬 수만큼)
```

라이브 카탈로그로 계산하면 이 `Available:` 블록이 **3,765바이트**, 스킬당
**376바이트**다. 그중 절반쯤이 정확 참조 JSON 이다(64hex content_revision 포함).

조합 스킬은 또 따로다. `keeper_effective_tool_surface.ml` 이 스킬 프로필에서
`keeper_compose_<skill>` 도구를 만들어 스키마에 넣는다.

그리고 프로필 필드 `skill_names` 는 **좁히는 쪽**이다.
`keeper_skill_catalog.ml:376` `project_turn`:

```ocaml
match names with
| None -> candidates, []        (* task + 전역 카탈로그 전부 *)
| Some names -> (* names 에 있는 것만 *)
```

선언하지 않은 키퍼가 더 많이 본다. 라이브 11명 전원이 선언하지 않았으므로
전원이 전체 카탈로그를 갖고 있다.

### task 선택 경로는 여전히 0건이다

프롬프트 슬롯 `keeper.current_task.skills` 는 "Exact Skill catalog rows
selected by this task" 로 시작하고, `.masc/tasks/backlog.json` 800건 중 skill
필드를 가진 것은 0건이다. `config/tools/masc_add_task.toml:85` 에 `skills`
배열이 선언돼 있지만 호출이 없다.

다만 이건 **추가 선택**이지 유일한 입구가 아니다. 전역 카탈로그가 이미 들어와
있으므로, task 선택이 0건이어도 키퍼는 스킬을 부를 수 있다. 실제로 부른다.

### 사용량

`.masc/tool_calls/2026-09/03.jsonl` 하루, `tool` 필드 집계.

| 지표 | 값 |
|---|---:|
| tool_call 행 | 8,236 |
| 서로 다른 도구 | 82 |
| 서로 다른 턴 | 1,796 |
| `keeper_skill` | 2 |
| `keeper_compose_<skill>` | 11 |
| **스킬 계열 합** | **13 (0.16%)** |

턴 1,796개에 13건, 턴당 0.01건이다. 상위 도구는 `keeper_artifact_read` 1,475 ·
`keeper_time_now` 1,102 · `Execute` 879 · `Read` 572 · `keeper_memory_write` 501.

스킬은 도구 계열이 **둘**이다. `keeper_skill` 은 본문을 정확 참조로 읽고,
`keeper_compose_<skill>` 은 스킬이 정의한 조합을 실행한다. 후자는
`keeper_effective_tool_surface.ml` 이 스킬 프로필에서 만들어 **도구 스키마에
넣는다**(`Instruction_skill | Composition_skill _ | Composition_control` origin).
그래서 프롬프트에 카탈로그가 없어도 조합 도구는 키퍼가 볼 수 있다.

### 그리고 그중 8건이 전부 실패한다

| 도구 | 호출 | 성공 |
|---|---:|---:|
| `keeper_compose_work-intake` | 8 | **0** |
| `keeper_compose_mission-snapshot` | 2 | 2 |
| `keeper_compose_background-snapshot` | 1 | 1 |
| `keeper_skill` | 2 | 2 |

`keeper_compose_work-intake` 는 오늘 8번 불려 8번 다 `Tool_result.Failed` 로
끝났다. 기록된 payload 는 `composition_tool`/`tool_kind`/`settled`/`cause`/
`effect_disposition` 모양인데, 이건 `keeper_tool_composition_surface.ml:570`
`failure_data` 가 **Error 분기에서만** 내는 모양이다. 성공한
`keeper_compose_mission-snapshot` 은 `actions` 키를 갖는다.

보이는 범위의 노드는 둘 다 `disposition: "completed"` 다. 실패 원인은
`cause` 필드에 있는데 **읽을 수가 없다** — 기록된 output 이 3,557자에서
`...(truncated)` 로 잘리고(`observability_redact.ml:34`) `cause` 는 `settled`
뒤에 오기 때문이다. 키퍼는 온전한 결과를 받았다(`result_bytes` 11,858~12,004).

즉 masc 의 tool_calls 저장소로는 **어떤 조합이 왜 실패했는지 알 수 없다**.
진단 필드가 정확히 잘리는 자리에 있다.

### 열린 이슈와의 관계

`#31324` 는 "keeper_skill 의 exact reference 가 매 턴 skill 당 185바이트를
컨텍스트에 싣는다"고 적혀 있다. **맞다.** 라이브 참조 JSON 은 스킬당 약
190바이트이고 서술 전체로는 376바이트다. 이 문서의 첫 판이 프롬프트만 보고
"0바이트"라고 반박했는데, 잘못 본 것이다 — 비용은 프롬프트가 아니라 도구
서술에 있다.

`#31324` 가 제안한 방향(참조를 enum 이나 이름으로 줄이기)이 지금 측정과
맞물린다. 매 턴 3,765바이트를 내고 0.01회를 얻는 교환에서, 그중 절반이
호출부가 굳이 알 필요 없는 64hex 다.

## 2. 외부 시스템은 어떻게 하는가

### 2.1 Anthropic Agent Skills / Claude Code — 3단 점진 공개

Discovery 단계에서 **모든** 스킬의 name + description 만 시스템 프롬프트에
무조건 올린다. 공식 문서 표현으로 description 필드가 "enables Skill discovery"
이고 "what it does and when to use it" 둘 다 담아야 한다. 측정된 비용은 스킬당
약 80토큰(중앙값, 55~235 범위) 또는 약 100토큰 수준이다. 본문(SKILL.md)은
task 가 description 에 걸릴 때 비로소 읽고, 번들 스크립트·참조 파일은 실행
중에 또 미룬다.

masc 도 1단계를 한다. 위치가 다를 뿐이다 — 시스템 프롬프트가 아니라
`keeper_skill` 도구 서술의 `Available:` 블록이다. 기능은 같다.

다른 것은 **무엇을 싣느냐**다. Anthropic 쪽은 name + description 이고 masc 는
거기에 정확 참조(64hex 포함)를 더 싣는다. 그래서 스킬당 약 80~100토큰이
아니라 376바이트(약 94토큰... 한글 설명이라 토큰은 더 든다)가 되고, 호출부가
그 64hex 를 그대로 받아 적어야 한다.

### 2.2 Hermes Agent (Nous Research) — 목록 도구 + 슬래시 명령 + 자가 저술

- 스킬은 `~/.hermes/skills/<name>/SKILL.md`, frontmatter 는 name·description +
  선택 metadata(tags, version, author, platforms).
- Level 0 은 프롬프트 블록이 아니라 **도구**다: `skills_list()` →
  `[{name, description, category}, ...]`, 약 3k 토큰. 본문은 "실제로 필요할 때만"
  읽는다.
- 활성화가 둘이다. 설치된 스킬은 **전부 슬래시 명령으로 자동 노출**되고
  (한 메시지에 최대 5개 체이닝), 자연어 대화로도 고를 수 있다.
- 이름 충돌 우선순위가 정해져 있다: project > profile > bundled, 번들 > 개별,
  local dir > external dir.
- **학습 루프**: observe → distill → reuse → refine. 유사 task 패턴을
  **3회 이상 성공**하면 절차·함정·검증 단계를 담은 SKILL.md 를 스스로 쓴다.

masc 키퍼는 이미 같은 본능을 보인다. polisher 의 "always include
content_revision" 는 Hermes 가 distill 할 내용을 메모리 행에 쓴 것이다. 저장소가
다를 뿐이다.

### 2.3 OpenAI Codex — 이름 호출과 항상-켜진 규칙의 분리

스킬은 `~/.agents/skills/` 의 SKILL.md 이고 task 가 맞으면 자동 로드된다.
명시적으로 부르는 경로도 따로 있다("invoke a skill explicitly with a mention or
let Codex select it when the request matches the skill description").
세션마다 항상 필요한 규칙은 스킬이 아니라 `AGENTS.md` 로 분리한다.

### 2.4 OpenClaw / Pi / Orca — 하네스 계층

OpenClaw 는 Pi 의 SDK(`@earendil-works/pi-agent-core`, `createAgentSession()`)를
메시징 게이트웨이에 끼워 넣은 형태고, Orca 는 Claude Code·Codex·Hermes·Pi·
Antigravity 등 여러 CLI 에이전트를 병렬로 돌리는 오케스트레이터다. 즉 이 셋은
스킬 활성화 방식을 새로 정의하지 않고 **밑에 깔린 하네스의 방식을 그대로
쓴다**. masc 는 자기 하네스이므로 여기서 베낄 것은 없다.

### 2.5 skillfold — 정확 참조는 lockfile 에, 호출부에 두지 않는다

YAML 매니페스트 하나에 스킬을 선언하고 **lockfile 에 exact revision 을 핀** 한
다음 재현 가능하게 설치한다. codex 타깃이면 `.agents/skills` 에도 깔고, 규칙은
`AGENTS.md` 의 마커로 감싼 블록에만 동기화한다.

이게 masc 의 마찰과 정확히 대비된다. masc 는 revision 핀을 **호출부에**
요구한다 — `keeper_skill` 의 `identity`(3필드)와 `content_revision`(64hex)이
전부 required 다. skillfold 는 같은 재현성을 매니페스트/lockfile 로 옮겨서
호출부는 이름만 쓴다.

## 3. 논문

| 출처 | 판정에 쓰는 내용 |
|---|---|
| arXiv 2602.12430 §3.1·§7 (Agent Skills survey) | 점진 공개가 "defining innovation". 다만 Challenge 2 가 **Skill Selection at Scale** 이고, 임계 라이브러리 크기를 넘으면 선택 정확도가 급격히 떨어지는 phase transition 이 보고돼 있다(§4.6 인용) |
| Anthropic Tool Search Tool (defer_loading) | 도구 정의 토큰 85% 감소. 50+ MCP 도구에서 약 77K → 약 8.7K. 정확도는 Opus 4 49%→74%, Opus 4.5 79.5%→88.1%. 검색 도구 자체 오버헤드는 약 500토큰 |
| arXiv 2606.20659 (Skill Coverage) | 스킬 지시문을 behavior constraint 로 뽑아 trajectory 가 그 constraint 를 짚었는지 본다. SkillsBench 리더보드 trajectory 가 평균 **38.66~45.51%** 만 커버. Fail 판정 난 지시문을 강조만 해서 다시 돌리면 실패 task 의 평균 **16.0%** 가 회복 (abstract) |
| arXiv 2605.15215 (SkillSmith) | 매칭된 스킬을 통째로 컨텍스트에 주입하는 방식의 낭비 둘 — 무관한 컨텍스트 주입, 스킬별 추론·계획 반복. 경계를 뽑아 최소 실행 인터페이스로 오프라인 컴파일. solve 단계 토큰 **57.44%** 감소, thinking iteration **42.99%** 감소, 2.02배 빠름 (abstract) |
| arXiv 2603.14805 (Knowledge Activation) | 병목은 모델 능력이 아니라 knowledge architecture. 스킬을 Atomic Knowledge Unit(무엇을 할지·어떤 도구를·어떤 제약을·다음은 어디로)으로 특화. Yahoo 배포, 엔지니어 67명 설문에서 주당 2.6시간 절약, NPS +35 (abstract) |

masc 에 직접 걸리는 것 두 개만 짚는다.

- **선택 정확도의 phase transition 은 masc 문제가 아니다.** 스킬이 10개다.
  임계 크기 논의는 수백 개 라이브러리 얘기다. masc 의 병목은 선택 정확도가
  아니라 도달이다.
- **Skill Coverage 는 판정 기준으로 쓸 수 있다.** "호출/턴 비율"은 거친 지표다.
  스킬 지시문을 constraint 로 뽑아 키퍼 trajectory 가 그걸 짚었는지 보면,
  "불렀다"와 "따랐다"를 가를 수 있다. 라이브 원장에 이미 USED 단계가 있으니
  절반은 있는 셈이다.

## 4. masc 안

전제가 바뀌었으므로 안도 바뀐다. **발견은 이미 된다.** 문제는 그 발견을 매 턴
3,765바이트로 사고 있고, 회수가 0.01회/턴이며, 제일 많이 불리는 하나가
고장나 있다는 것이다.

판정 기준: 조치 전후의 **스킬 계열 호출/턴**과 **`Available:` 블록 바이트**.
지금 기준선은 0.0072회/턴(13/1,796), 3,765B.

### 안 0 — 고장난 것부터 (진행 중)

`keeper_compose_work-intake` 8/8 실패. 오늘 스킬 호출의 62%다. 원인을 아직
못 읽어서 먼저 진단 경로를 고쳤다(#32966: 실패 payload 에서 `cause` 를
`settled` 앞으로). 배포되면 다음 실패가 이유를 남긴다.

시도한 키퍼가 실패를 받는 상태를 두고 나머지를 논할 수 없다.

### 안 1 — 참조를 서술에서 덜어낸다 (skillfold 방식, `#31324` 방향)

`Available:` 블록에서 64hex `content_revision` 을 빼고 이름 + 설명만 남긴다.
호출부는 이름으로 부르고, 서버가 발행된 revision 으로 해석한다. 재현성은
스냅샷 revision 과 원장이 이미 들고 있다.

- 아끼는 것: 스킬당 약 190바이트 × 10 = 약 1.9KB/턴. 블록이 절반이 된다.
- 없애는 마찰: polisher 가 "always include content_revision" 를 메모리에
  적어둘 만큼 걸렸던 지점.
- 위험: 이름이 겹치면 어느 것인지 모호해진다. Hermes 는 이 문제를
  project > profile > bundled 우선순위로 닫는다. masc 는 소스가 4개이므로
  같은 종류의 규칙이 필요하다.

### 안 2 — 목록을 도구로 미룬다 (Hermes `skills_list()` / Tool Search 방식)

`Available:` 블록을 아예 빼고 `keeper_skills_list` 도구를 둔다.

- 아끼는 것: 3,765B 전부. 대신 도구 스키마 하나.
- 근거: masc 는 이미 도구에 defer_loading 을 쓴다. Tool Search 는 토큰을
  85% 줄이면서 호출 정확도를 79.5%→88.1% 올렸다.
- 위험: 지금도 0.0072회/턴인데 왕복을 하나 더 세우면 더 줄 수 있다.
  **안 1 을 먼저 하고 재는 편이 낫다** — 안 1 은 비용을 반으로 줄이면서
  마찰도 줄이므로 방향이 한쪽이다.

### 안 3 — 자가 저술 (Hermes 학습 루프)

키퍼가 같은 절차를 3회 이상 성공하면 SKILL.md 를 쓴다. 지금 권하지 않는다.
회수가 0.0072회/턴인데 생산을 늘리면 `Available:` 블록만 커진다.

다만 재료는 이미 있다 — 키퍼 메모리에 절차·함정·검증이 쌓이고 있고,
polisher 의 lesson 이 그 예다.

### 안 4 — 무조건 프롬프트 카탈로그

**버린다.** masc 는 이미 도구 서술로 같은 일을 하고 있다. 프롬프트에 또 넣으면
같은 것을 두 번 싣는 것이고, `#32935`(Fleet Messages 가 턴 컨텍스트 90%)·
`#32939`(요청당 138개 중 85개 미사용 도구)와 정면으로 부딪힌다.

## 5. 권고

1. **#32953 / #32966** — 고장난 조합부터. 배포 후 `cause` 를 읽고 판정.
2. **안 1** — 서술에서 64hex 를 덜어낸다. 비용 절반, 마찰 제거, 방향이 한쪽.
   이름 충돌 규칙을 같이 정한다(소스 4개).
3. 그다음 안 2 를 **재고** 판단한다. 안 1 이후 호출/턴이 오르면 왕복을 더
   세울 이유가 약해진다.
4. 안 3 은 회수가 오른 뒤.

측정은 조치 전후 같은 방법으로. `tool_calls/*.jsonl` 의 `tool` 필드로 스킬
계열 호출/턴, 그리고 라이브 카탈로그로 계산한 `Available:` 블록 바이트.
기준선은 **0.0072회/턴, 3,765B**.
