---
title: "키퍼가 직접 만드는 Skill"
status: Accepted
created: 2026-09-11
updated: 2026-09-24
author: claude-main
---

# RFC: 키퍼가 직접 만드는 Skill

- 관련: PR #35228 (per-game MSX 스킬 착지), msx-retro-mania 지시문의
  "패턴은 Skill로 축적" 요구, #37633 (Memory 에서 Skill 로 가는 생산 경로가 없다).

## 문제

키퍼는 캠페인에서 반복 패턴과 게임 지식을 쌓지만 스킬로 발행하지
못한다. 발행 경로는 전부 운영자 몫이다.

- editor API(`POST /api/v1/skills/editor/create|save|preview`)는
  `CanAdmin` 권한으로 묶여 있어 키퍼 토큰으로는 못 쓴다.
- 스킬 소스는 디렉터리다(`[[skills.sources]]`의 `.masc/skills`,
  `.agents/skills`). 키퍼에게 파일 쓰기 도구가 없다.
- TUI `c`/`C`와 대시보드 Skill Studio는 인간 운영자의 손이다.

그래서 증류 고리는 "키퍼가 관측해 보드에 남김 → 운영자 세션이 읽고
발행"이고, 운영자가 읽지 않으면 쌓이지 않는다. 지시문이 축적을
요구해도 쓰기 경로가 없으면 그 요구는 매번 보드 글로 흩어진다.

## 착지하며 기록한 규칙 (PR #35228)

- 스킬당 composition은 정확히 1개.
- composition 이름은 스킬 이름과 같아야 한다.
- description은 YAML이다. 백틱·`@`·`%`는 따옴표가 필요하고, 말라면
  스킬 전체가 rejections로 빠진다.
- composition 오류는 rejection이 아니라 instruction 스킬 강등이다.
  발행은 성공한 것처럼 보이니 surface 분류(activation_tool)로 긍정
  확인해야 한다.
- 가변 키 매크로는 못 만든다. composition 파라미터는 스칼라
  4종(string/int/number/bool)과 정해진 문자열 목록(`enum`)뿐이라 `keys`
  목록을 넘길 수 없고, 고정 시퀀스만 리터럴로 선언된다.

## 제안

키퍼 발행 도구 하나를 tool surface에 추가한다(작업명
`keeper_skill_publish`).

- 쓰기 대상은 이미 선언된 `project-agents` 소스(`<base>/.agents/skills`)
  다. 새 소스가 아니라 runtime 설정에 이미 read-write로 있는 자리다.
- 검증은 editor create와 같은 파서를 그대로 통과시킨다. frontmatter
  YAML, composition grammar, catalog snapshot 발행까지 동일하고, 별도
  게이트를 추가하지 않는다.
- 이름은 키퍼가 정하고 description 라우팅이 발견을 담당한다. 이미
  모든 스킬이 그 경로로 발견된다.
- 삭제는 운영자 권한(DELETE editor 라우트) 그대로다. 조정 선은 사전
  승인이 아니라 사후 삭제다.

## 결정 (2026-09-23, 운영자)

#37633 은 "사람이 먼저 승인하고 발행" 을 요구하고, 이 RFC 는 "키퍼가 발행하고 운영자가 나중에 지운다" 를 제안해요.
운영자는 이 RFC 쪽을 골랐어요.
행동을 미리 막는 장치를 더하지 않고 키퍼가 스스로 고르게 둔다는 projects 규칙과 같은 방향이에요.
#37633 의 조건 중 아래 둘은 그대로 받아요.
- 발행한 Skill 은 정확한 불변 참조(`Skill_reference`)를 남기고, 다음 턴이 그 참조를 카탈로그로 찾아서 써요.
- 새 Skill 저장소를 따로 만들지 않고, 권한 판정도 우회하지 않아요.

## 경계

발행 로직은 이미 `Server_skill_editor.create` 에 있어요.
새 패키지 디렉터리를 만들되 덮어쓰지 않고, editor 와 같은 파서로 검증하고, read-write 로 선언된 소스에만 쓰고, 카탈로그 snapshot 을 발행해요.
문제는 이 모듈이 `lib/server` 에 있고 키퍼 도구는 `lib/keeper` 에 있다는 점이에요. keeper 는 server 를 참조할 수 없어요.

그래서 `Workspace_hooks` 에 이미 있는 방식을 따라요.
서버가 부팅할 때 Atomic ref 하나를 채우고(`server_bootstrap_loops.ml` 에서 다른 hook 을 채우는 자리), 키퍼 도구는 그 ref 로 `create` 를 불러요.
설치 전 기본값은 `Error Not_installed` 예요. 조용한 no-op 이 아니에요.
모듈을 아래 층으로 옮기는 방법도 봤어요. 하지만 `refresh` 가 `Server_skill_snapshot_runtime.refresh_from_observation` 을 쓰기 때문에, 옮기려면 snapshot runtime 까지 같이 내려야 해요. 범위가 두 배가 돼서 이 방법은 쓰지 않아요.

## 도구 계약 (`keeper_skill_publish`)

입력:
- `package_id`: 새 패키지 이름이에요. editor 의 `Invalid_package_id` 검사를 그대로 받아요.
- `source_text`: `SKILL.md` 전체예요. `keeper_skill_validate` 가 읽는 것과 같은 문서예요.
- `evidence`: 이 절차가 실제로 통했다는 근거예요(Memory fact id, turn 참조, tool call 참조). 문자열 목록이고, 비어 있으면 거절해요.

출력은 editor 의 결과를 타입 그대로 투영해요.
- `Created_and_published` → 참조와 snapshot revision
- `Created_but_shadowed` → 참조, snapshot revision, 같은 이름을 먼저 선언해 이긴 패키지(`winner`)
- `Created_but_unpublished` → 이유
- `error_code` 와 문장

쓰기 대상은 `project-agents` 소스 하나로 고정해요. 키퍼는 소스를 고르지 못해요.

기록: 발행마다 감사 원장에 한 줄을 남겨요. 행위자는 키퍼 이름, 참조, `evidence` 예요. editor HTTP 경로의 `audit_skill_write` 와 같은 원장이에요.
`evidence` 는 게이트가 아니라 사실 기록이에요. 도구는 근거가 참인지 판정하지 않아요. 판정 없이 문자열만 있는지 보는 것, 그 이상은 하지 않아요.

## 열린 질문에 대한 답

- **이름 겹침**: 같은 소스 안에서는 `create` 가 `Package_already_exists` 로 거절해요. 다른 소스와 이름이 겹치면 지금 카탈로그 규칙대로 섀도잉이 되고, `shadows` 로 보여요. 네임스페이스 규약은 두지 않아요. 실제로 겹치는 일이 관측되면 그때 다뤄요.
- **발행 빈도 상한**: 두지 않아요. 상한은 행동을 막는 장치예요. 오염이 관측되기 전에는 더하지 않아요. 운영자의 사후 삭제가 조정선이에요.
- **"검증된 사실" 강제**: 도구 범위 밖이에요. 도구는 근거를 기록만 하고, 규범은 지시문 수준에서 다뤄요.

## 검증

- 단위 테스트
  - hook 이 설치되지 않았으면 `Not_installed` 로 거절해요.
  - `evidence` 가 비어 있으면 거절해요.
  - editor 결과 세 갈래(`Created_and_published`, `Created_but_unpublished`, `error_code`)가 타입 그대로 투영돼요.
  - 이미 있는 이름이면 `Package_already_exists` 로 거절하고 덮어쓰지 않아요.
- 끝에서 끝까지: 한 키퍼가 발행하고, 다음 턴에 카탈로그의 Available 목록에 그 참조가 뜨는지 봐요. 운영자가 삭제하면 그다음 턴에는 사라져요.
