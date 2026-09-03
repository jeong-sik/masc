# Skill 이 도달하지 않는다 — 라이브 실측과 외부 설계 대조 (r1)

masc 의 Skill 서브시스템은 고장난 게 아니라 **키퍼가 볼 수 없다**. 발행·스냅샷·
정확 참조·원장까지 다 도는데, 키퍼 프롬프트에 카탈로그가 0바이트로 들어간다.
이 문서는 그 사실을 먼저 못박고, 같은 문제를 외부 시스템·논문이 어떻게 푸는지
대조한 다음, masc 에 맞는 활성화 방안을 셋으로 좁힌다.

근거는 `2026-09-04-skill-activation-evidence-record.md`.

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

### 왜 0인가 — 입구가 조건부다

프롬프트 슬롯 `keeper.current_task.skills` 는 이렇게 시작한다.

```
- Exact Skill catalog rows selected by this task: {{skill_surfaces}}. ...
```

**이 task 가 고른 행**만 싣는다. 그런데 `.masc/tasks/backlog.json` 800건 중
skill 필드를 가진 것은 **0건**이다. 문자열 `skill` 은 115번 나오지만 전부
description 산문이고 필드 모양(`"...skill...":`)은 0건이다.

쓰기 경로는 있다. `config/tools/masc_add_task.toml:85` 에 `skills` 배열이
선언돼 있고 `identity`(source_id/package_id/name) + `content_revision` 을
요구한다. 선언은 있고 호출이 없다. 그래서 fragment 가 한 번도 렌더되지 않고,
카탈로그는 턴 안에서 볼 방법이 없다.

### 사용량

`.masc/tool_calls/2026-09/03.jsonl` 하루, `tool` 필드 집계.

| 지표 | 값 |
|---|---:|
| tool_call 행 | 8,160 |
| 서로 다른 도구 | 82 |
| 서로 다른 턴 | 1,770 |
| `keeper_skill` | **2 (0.025%)** |

턴 885개당 1건이다. 상위 도구는 `keeper_artifact_read` 1,475 ·
`keeper_time_now` 1,102 · `Execute` 879 · `Read` 572 · `keeper_memory_write` 501.

### 열린 이슈와의 관계

skill 이슈 20건(2026-08-24 ~ 09-02)은 대부분 이 도달 불가 표면의 정밀도를
다듬는 내용이다. 그중 하나는 전제가 라이브와 다르다.

`#31324` 는 "keeper_skill 의 exact reference 가 매 턴 skill 당 185바이트를
컨텍스트에 싣는다"고 적혀 있다. 지금은 11명 전원 0바이트다. fragment 가
렌더되지 않아서 그렇다. 그 이슈의 수치는 표면이 실제로 켜진 뒤에 다시 재야
한다. 도달 문제는 `#32944` 로 분리했다.

## 2. 외부 시스템은 어떻게 하는가

### 2.1 Anthropic Agent Skills / Claude Code — 3단 점진 공개

Discovery 단계에서 **모든** 스킬의 name + description 만 시스템 프롬프트에
무조건 올린다. 공식 문서 표현으로 description 필드가 "enables Skill discovery"
이고 "what it does and when to use it" 둘 다 담아야 한다. 측정된 비용은 스킬당
약 80토큰(중앙값, 55~235 범위) 또는 약 100토큰 수준이다. 본문(SKILL.md)은
task 가 description 에 걸릴 때 비로소 읽고, 번들 스크립트·참조 파일은 실행
중에 또 미룬다.

masc 와의 차이가 정확히 여기다. masc 는 1단계(무조건 discovery)가 **없고**
2단계(본문 로드)를 task 선택에 걸어놨다. 그래서 아무도 1단계를 못 밟는다.

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

## 4. masc 안 (셋으로 좁힘)

세 안 모두 판정 기준은 같다. 조치 후 **`keeper_skill` 호출/턴 비율**과, 가능하면
**Skill Coverage**(짚은 constraint 비율).

### 안 A — 무조건 카탈로그 블록 (Claude Code 방식)

`keeper.md` 에 task 무관 fragment 를 하나 넣어 스킬 10개의 name +
description 을 항상 싣는다.

- 비용: 스킬당 약 80~150토큰 × 10 = 약 800~1,500토큰/턴. 지금 0이므로 순증이다.
- 장점: 표준이 하는 그대로다. 구현이 가장 작다(프롬프트 슬롯 하나 + 렌더러).
- 단점: `#31324`·`#31133` 이 미리 반대한 비용이 여기서 실제로 발생한다. 그리고
  masc 는 이미 컨텍스트가 빡빡하다 — `#32935`(Fleet Messages 가 턴 컨텍스트
  90%), `#32939`(요청당 138개 중 85개 미사용 도구)가 열려 있다.

### 안 B — 목록 도구 + defer_loading (Hermes `skills_list()` + Anthropic Tool Search 방식) ← 권고

`keeper_skills_list` 도구 하나를 노출하고 본문 로드는 기존 `keeper_skill` 에
맡긴다.

- 비용: 도구 스키마 하나(수백 바이트). Anthropic 측 검색 도구 오버헤드가 약
  500토큰이라는 값이 참고선이다.
- 근거: masc 는 **이미 이 패턴을 도구에 쓰고 있다**(deferred tool loading).
  같은 기전을 스킬에 쓰는 것이므로 새 개념을 도입하지 않는다.
- 측정된 방향: Tool Search 는 토큰을 85% 줄이면서 호출 정확도를 79.5%→88.1%
  올렸다. 컨텍스트에서 안 쓰는 정의를 빼면 정확도가 같이 오른다는 뜻이다.
- 단점: 키퍼가 "목록 도구가 있다"는 걸 알아야 한다. 도구 스키마의 description
  이 그 역할을 한다(`the-model-reads-descriptor-description-not-the-toml`).
  한 왕복이 더 든다.

### 안 C — 호출부에서 revision 핀을 걷어낸다 (skillfold 방식)

`keeper_skill` 의 `content_revision` 을 required 에서 optional 로 내리고,
빠지면 **발행된 최신 revision** 으로 서버가 해석한다. 재현성은 스냅샷
revision 이 이미 들고 있다.

- 근거: polisher 가 이 마찰을 메모리에 적어둘 정도였다. 거부 → 재발행 →
  "always include content_revision" 라는 lesson 이 남았다. 호출부 계약이
  학습 비용을 만들고 있다.
- 이건 A·B 와 배타적이지 않다. **B 와 같이 가야 효과가 있다** — 목록을 보고
  이름으로 부를 수 있어야 하니까.
- 주의: 이건 결정론의 후퇴가 아니다. 어떤 revision 이 쓰였는지는 원장이
  기록한다. 호출자가 그걸 미리 알아야 하느냐가 다른 문제다.

### 안 D — 자가 저술 (Hermes 학습 루프)

키퍼가 같은 절차를 3회 이상 성공하면 SKILL.md 를 스스로 쓴다.

지금 권하지 않는다. 활성화가 0인 상태에서 생산을 늘리면 아무도 안 보는 스킬만
늘어난다. B(+C)로 활성화가 measurable 하게 오른 다음에 볼 문제다. 다만 방향은
기록해 둔다 — 키퍼 메모리에 이미 절차·함정·검증이 쌓이고 있고, 그게 SKILL.md
의 재료다.

## 5. 권고

**B + C 를 한 RFC 로 묶는다.** A 는 masc 의 현재 컨텍스트 압력과 정면으로
부딪히고(`#32935`, `#32939`), B 는 masc 가 이미 쓰는 기전이라 새 개념이 없다.
C 없이 B 만 하면 목록을 봐도 64hex 를 어디서 구할지가 남는다.

D 는 활성화가 오른 뒤로 미룬다.

측정은 조치 전후 같은 방법으로 한다. `tool_calls/*.jsonl` 의 `tool` 필드로
`keeper_skill` 호출/턴, 그리고 키퍼 `last-prompt.json` 의 스킬 바이트. 지금
기준선은 **0.025% (2/8,160), 프롬프트 0바이트**다.
