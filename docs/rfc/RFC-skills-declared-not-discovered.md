---
rfc: "skills-declared-not-discovered"
title: "외부 skill 을 선언으로 받는다 — 확장 지점은 열되 언제 쓸지는 task 가 정한다"
status: Draft
created: 2026-08-24
updated: 2026-08-24
author: claude
supersedes: []
superseded_by: null
related: ["prompts-and-tool-definitions-outside-ocaml"]
implementation_prs: []
---

# RFC: 외부 skill 을 선언으로 받는다 (skills-declared-not-discovered)

## 0. Summary

masc 를 확장하려면 지금은 masc 저장소를 고쳐야 한다. 도구를 하나 늘리는 데 TOML 을 쓰고,
로더에 키를 가르치고, PR 을 올리고, 재배포한다. 그 사이 바깥에서는 Agent Skills 가 표준이
됐고 수천 개 skill 이 `SKILL.md` 한 장으로 배포된다. keeper 는 그중 하나도 못 쓴다.

이 RFC 는 외부 skill 을 받아들이되, **언제 쓸지는 모델이 고르지 않게** 한다. skill 은
task 나 goal 이 미리 지정하고, keeper 는 지정된 것만 본다. 확장 지점은 열고 라우팅은 닫는다.

RFC-prompts-and-tool-definitions-outside-ocaml 이 masc **자신의** 글을 config 파일로 옮겼다면,
이 RFC 는 **남이 쓴** 실행 지식을 받는 경로를 만든다. 둘 다 "모델이 읽는 것은 파일이
소유한다"는 같은 축이다.

## 1. 관측 (main `fb94d89e6c`, 2026-08-24)

### 1.1 keeper 는 skill 을 하나도 못 본다

`runtime_claude_code.ml:992` 가 `--setting-sources=` 를 빈 값으로 넘긴다. 같은 환경에서
플래그만 바꿔 `claude --print --output-format stream-json --verbose` 를 두 번 실행하고
init 메시지를 비교했다.

| 조건 | skills | plugins | `Skill` 도구 |
|---|---|---|---|
| `--setting-sources=` (masc 가 쓰는 값) | 16 | 0 | 있음 |
| 플래그 없음 | 91 | 12 | 있음 |

16개는 전부 CLI 빌트인이다. 운영자가 `~/.claude/skills/` 에 설치한 것과 플러그인 12개는
keeper 에게 도달하지 않는다. `Skill` 도구는 두 조건 모두에 실려 있으므로 **호출 경로는 이미
있고 목록만 비어 있다.**

### 1.2 확장은 전부 저장소를 거친다

| 지점 | 개수 / 크기 | 추가 절차 |
|---|---|---|
| `config/tools/*.toml` | 105개 / 106,613 B | TOML 작성 + 로더 수정 + PR + 재배포 |
| `config/prompts/*.md` | 16개 / 28,246 B | PR + 재배포 |
| MCP 서버 | 설정 | 운영자가 추가 가능 |

`tool_definition_toml.mli` 가 이 절차를 계약으로 못 박는다.

> a key the runtime does not consume yet is rejected until the PR that consumes it also
> teaches this loader to decode it.

부팅 시 1회 로드이고 hot reload 는 없다(같은 파일, RFC §6 인용).

### 1.3 도구 표면에는 자리가 없다

`test/test_keeper_tool_schema_bytes.ml:44` 의 `ceiling_bytes = 85_000`. 양방향 래칫이라
상한 초과도, 여유가 상한의 1/3(28,333 B)을 넘는 것도 실패한다. 2026-08-24 실행 결과는
통과이므로 현재 값은 56,667 ~ 85,000 B 사이다. 정확한 값은 재지 않았다 — 테스트는 실패할
때만 수치를 낸다.

같은 파일 주석의 이력이 추세를 말한다. 2026-08-07 에 72,485 B / 98개였고, 2026-08-23 에
88,138 B / 95개가 됐다. **도구는 3개 줄었는데 15,653 B 늘었고 원인 PR 이 없다.** 2주간
45커밋에 흩어져 있다.

비교로 조립된 keeper 시스템 프롬프트는 golden 기준 1,614 B, 2026-08-07 실측 9,167 B 다.
턴마다 나가는 고정 비용의 대부분은 도구 표면이다.

**따라서 새 능력을 도구로 추가하는 길은 이미 막혀 있다.** skill 은 `Skill` 도구 하나에
이름과 한 줄 설명으로 붙으므로 이 예산을 쓰지 않는다.

### 1.4 도구 표면은 정적이고, task 는 프롬프트로 들어간다

`keeper_tool_descriptor.mli:31` 의 `keeper_model_projection` 은 도구마다 **고정된** 값이다.

```ocaml
type keeper_model_projection =
  | Preferred_public_name
  | Internal_name
  | Operator_only
  | Transport_alias of { projected_by : string }
```

턴마다 바뀌는 것은 `keeper_agent_tool_surface.mli` 의 `turn_lane`(`text_only` / `tool_optional`
/ `tool_disabled` / `retry`)뿐이고, 이는 도구를 켜고 끄는 축이지 **어느 도구를 고르는 축이
아니다.** task 별로 도구 표면을 바꾸는 구조는 지금 없다.

한편 task 는 프롬프트를 통해 들어간다. `keeper_unified_prompt.mli:57` 에
`val format_current_task : Masc_domain.task -> string` 이 있다.

`types_core.ml:543` 의 task 레코드는 이렇게 생겼다.

```ocaml
type task = {
  id: string; title: string; description: string;
  task_status: task_status; priority: int; [@default 3]
  files: string list; [@default []]
  ...
  contract: task_contract option; [@default None]
  execution_links: task_execution_links; [@default no_execution_links]
  ...
} [@@deriving show]
```

모든 선택 필드가 `[@default ...]` 를 달고 있다.

**이 두 사실이 설계를 결정한다.** skill 은 도구가 아니라 프롬프트에 실리므로 정적인
`keeper_model_projection` 을 건드릴 필요가 없고, task 가 이미 프롬프트에 도달하므로 task 에
붙인 선언이 keeper 에게 닿는 경로도 이미 있다.

## 2. 무엇이 문제인가

확장이 안 되는 게 아니라, **확장하는 사람이 masc 개발자뿐**이다. 운영자가 자기 팀의 배포
절차나 문서 규칙을 keeper 에게 가르치려면 masc 에 PR 을 올려야 한다. 이건 masc 가 커질수록
비싸진다.

바깥의 답은 이미 있다. Agent Skills 는 2025-12-18 에 오픈 표준이 됐고 필수 필드는
`name` 과 `description` 둘뿐이며, 런타임은 모르는 frontmatter 키를 무시한다. pi, Hermes,
OpenClaw, Codex, Gemini CLI 가 같은 형식을 읽는다.

## 3. 왜 skill 단위인가

세 후보를 놓고 골랐다.

| 단위 | 도구 표면 비용 | 생태계 호환 | 새로 생기는 개념 |
|---|---|---|---|
| **도구** (`config/tools/` 경로 확장) | 85,000 B 예산 직격 | 없음 | 없음 |
| **skill** (`SKILL.md` 수용) | 없음 (`Skill` 도구 하나) | 수천 개 | 로더 하나 |
| **keeper** (역할로 취급) | 없음 | 없음 | 없음, 대신 단위가 무겁다 |

도구 단위는 §1.3 때문에 탈락한다. 여유 1~2KB 안에서 새 능력을 넣을 수 없고, 넣더라도
그 도구는 **모든 keeper 의 모든 턴**에 실린다. 확장 하나가 전체 비용이 된다.

keeper 단위는 비용은 없지만 단위가 너무 크다. "PR 본문 다듬기" 같은 일에 keeper 를 하나
세우는 건 과하다.

## 4. 설계

### 4.1 경계 — 두 파일은 다른 규칙을 따른다

masc 로더의 fail-closed 는 **masc 자신의 계약 파일**에 걸린 규칙이다. `config/tools/*.toml`
은 masc 가 쓰고 masc 가 읽는다. 모르는 키가 있으면 masc 의 버그이므로 부팅에서 죽는 게 맞다.

외부 `SKILL.md` 는 masc 의 계약이 아니다. 거기 있는 `metadata.openclaw` 나 `metadata.hermes`
는 masc 가 몰라도 되는 남의 필드다. 스펙이 요구하는 대로 무시한다.

대신 **skill 이 masc 에게 요구하는 것은 fail-closed 로 검증한다.**

```yaml
name: humanize-korean
description: 한국어 문장의 AI 티를 제거한다
metadata:
  masc:
    requires:
      bins: [python3]
      env: []
    surface: task_declared      # 닫힌 어휘
```

`metadata.masc` 아래는 masc 의 계약이므로 기존 TOML 로더와 같은 규칙을 쓴다. 모르는 키는
거부하고, 열거값은 닫힌 어휘로 검사한다. `metadata.masc` 가 아예 없는 skill 은 거부가
아니라 기본값으로 읽는다 — 남의 skill 이 masc 를 알아야 할 이유는 없다.

이 방향은 새로 만드는 게 아니라 OpenClaw 가 이미 하는 것과 같다. 거기서는 코드가 쓰는
환경변수를 frontmatter 에 선언하지 않으면 불일치로 표시한다.

### 4.2 라우팅 — task 가 정하고 keeper 는 고르지 않는다

여기가 이 RFC 의 핵심이다.

Agent Skills 의 기본 라우팅은 description 을 전부 프롬프트에 늘어놓고 모델이 고르는
것이다. 91개가 실리면 91줄이 매 턴 나가고, 어느 것이 걸릴지는 모델이 정한다. masc 는
semantic string matching 을 금지하고 있으므로 이 방식을 그대로 쓸 수 없다.

대신 task 나 goal 이 skill 을 지정한다.

```
task: "PR #123 본문을 한국어 규칙에 맞게 다듬는다"
skills: [humanize-korean]
```

keeper 가 그 task 를 claim 하면 지정된 skill 만 표면에 올라온다. 지정이 없으면 아무것도
올라오지 않는다. 라우팅이 결정론이 되고, 어느 턴에 무엇이 실렸는지는 task 를 보면 안다.

**배선은 도구 쪽이 아니라 프롬프트 쪽이다** (§1.4). 도구 표면은 정적이므로 건드리지 않고,
이미 있는 task → 프롬프트 경로에 얹는다.

```
types_core.ml:543       task 에 skills : string list; [@default []]
        │
        ▼
masc_add_task           붙이는 시점에 requires 검사 (§4.3)
        │
        ▼
keeper_unified_prompt   format_current_task 가 지정된 skill 만 블록으로 넣는다
        │
        ▼
keeper                  Skill / Read / Execute 로 실행 (새 도구 없음)
```

필드를 하나 늘리는 것이므로 근거가 필요하다. "이 task 는 이 skill 로 한다"는 사람이 정하는
사실이고 다른 상태에서 파생되지 않는다. `description` 에 자연어로 적어 추론하게 하는 대안은
semantic string matching 이라 배제한다. `files` 에 넣는 대안은 작업 대상과 실행 지식을 같은
필드에 섞는다.

`[@default []]` 는 레거시 reader 가 아니라 레코드의 기존 관행이다. 이 필드가 없던 task 는
skill 이 0개인 task 로 읽히고, 그것이 맞는 뜻이다.

### 4.3 실행 — 새 도구를 만들지 않는다

skill 본문은 마크다운이고, 안에 있는 스크립트는 파일이다. keeper 에게는 이미 `Read` 와
`Execute` 가 있다. skill 을 실행하기 위해 새 도구를 정의하지 않는다 — §1.3 의 예산 때문에도
그렇고, 없어도 동작하는 Gate 는 추가하지 않는다는 원칙 때문에도 그렇다.

`requires.bins` 검사는 task 에 skill 을 붙이는 시점에 한 번 한다. 없으면 그때 실패한다.
keeper 가 턴 중에 알게 되는 것보다 낫다.

### 4.4 설치 위치 — `<base_path>/.masc/skills/`

skill 은 워크스페이스 단위로 산다. 같은 base path 를 쓰는 에이전트들이 같은 skill 을 본다.

```
<base_path>/.masc/skills/<name>/SKILL.md
```

`config/skills/` 가 아닌 이유는 그쪽이 masc 저장소 소유라 §2 의 문제를 그대로 남기기
때문이다. `.masc/` 아래면 운영자가 masc 에 PR 없이 skill 을 놓을 수 있다.

경로 리터럴은 새로 박지 않는다. `lib/core/common.ml:40` 의 `masc_dirname` 이 이미 SSOT 이고,
`workspace_utils_paths_backend.ml:27` 이 `Filename.concat base_path ".masc"` 의 재인라인을
금지한다(#8355). skill 경로도 그 상수를 지난다.

부팅 1회 로드라는 기존 계약은 유지하므로, skill 을 놓은 뒤에는 재시작이 필요하다.

### 4.5 skill 이 skill 을 부르는 것 — 허용하되 아무것도 만들지 않는다

skill 안에서 다른 skill 을 부르는 것을 허용한다. 오케스트레이터형 skill 은 이미 존재하고
(예: `humanize-korean` 은 진단·윤문·마무리를 나눠 부른다), 1단계로 자르면 그런 skill 이
통째로 못 들어온다.

허용한다는 것은 **masc 가 아무 장치도 두지 않는다**는 뜻이다. skill 이 다른 skill 을 부르는
일은 keeper 가 `Skill` 도구를 한 번 더 부르는 것일 뿐이고, masc 가 새로 알아야 할 사실이
없다. 깊이 제한도, 순환 감지도 두지 않는다.

"facade 가 facade 를 호출하는 구조를 만들지 않는다"는 원칙은 masc **자신의** 모듈 구조에
대한 것이다. 남의 skill 이 자기들끼리 어떻게 짜였는지는 masc 의 구조가 아니다.

순환은 실재하는 위험이지만 이미 막혀 있다. keeper 의 턴 예산과 컨텍스트 상한이 상한이고,
순환하는 skill 은 그 상한에 닿아 멈춘다. 없어도 동작하는 Gate 는 추가하지 않는다.

## 5. 비목표

- **skill 마켓플레이스를 만들지 않는다.** 설치는 파일을 놓는 것이고, 어디서 가져올지는
  운영자가 정한다.
- **hot reload 를 만들지 않는다.** 부팅 1회 로드라는 기존 계약을 그대로 따른다.
- **`--setting-sources=user` 로 열지 않는다.** 91개가 통째로 들어오고 keeper 가 고르게
  되므로 §4.2 와 정반대다. 확인용 스위치로는 쓸 수 있다.
- **레거시 경로를 만들지 않는다.** 이전 형식을 읽는 reader 나 converter 는 없다.

## 6. 미해결 질문

1. **skill 목록이 프롬프트에서 몇 바이트인가.** §4.2 대로 task 가 지정하면 한 번에 한두
   개지만, 상한이 필요한지는 재봐야 안다. 도구 표면처럼 래칫을 걸 것인지.
2. **skill 의 실패를 무엇으로 볼 것인가.** skill 대로 했는데 결과가 틀린 것과 skill 자체가
   깨진 것을 구분할 방법이 지금은 없다.
3. **운영자가 설치한 skill 을 신뢰하는 근거.** `requires` 는 무엇이 필요한지 말할 뿐 무엇을
   하는지는 말하지 않는다. §4.5 대로 skill 이 skill 을 부를 수 있으므로 한 장만 읽고
   무엇이 실행될지 아는 것도 보장되지 않는다.
4. **`.masc/skills/` 가 워크스페이스마다 다르면 keeper 간 능력이 갈린다.** 같은 base path 를
   공유하면 같은 skill 을 보지만, 여러 워크스페이스를 오가는 운영에서 이게 어떻게 보일지는
   설계하지 않았다.

## 7. 완료 정의

- [ ] `SKILL.md` 한 장을 읽어 `name`/`description`/`metadata.masc` 를 얻는 로더.
      `metadata.masc` 아래는 닫힌 어휘로 fail-closed, 그 밖의 네임스페이스는 무시.
- [ ] `types_core.ml` 의 task 에 `skills : string list; [@default []]`.
- [ ] skill 경로가 `Common.masc_dirname` 을 지나고 `.masc` 리터럴을 새로 박지 않는다(#8355).
- [ ] `masc_add_task` 가 붙이는 시점에 `requires` 를 검사하고, 못 갖추면 그때 실패.
- [ ] `keeper_unified_prompt.format_current_task` 가 지정된 skill 만 블록으로 넣는다.
- [ ] 지정이 0개인 task 의 프롬프트가 **이 변경 전과 바이트 단위로 같다**
      (`test_keeper_system_prompt_bytes` golden 무변경). Gate 를 추가하지 않았다는 증거다.
- [ ] `test_keeper_tool_schema_bytes` 무변경 — skill 은 도구 표면을 쓰지 않는다.
- [ ] skill 지정이 프롬프트에서 몇 바이트인지 재고, 래칫이 필요한지 그 수치로 판단(§6.1).
