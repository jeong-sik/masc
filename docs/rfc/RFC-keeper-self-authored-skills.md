---
title: "키퍼가 직접 만드는 Skill"
status: Draft
created: 2026-09-11
author: claude-main
---

# RFC: 키퍼가 직접 만드는 Skill

- 관련: PR #35228 (per-game MSX 스킬 착지), msx-retro-mania 지시문의
  "패턴은 Skill로 축적" 요구.

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
- 가변 키 매크로는 못 만든다. composition 파라미터가 스칼라
  4종(string/int/number/bool)뿐이라 `keys` 목록을 넘길 수 없고, 고정
  시퀀스만 리터럴로 선언된다.

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

## 열린 질문

- `project-masc`와 이름이 겹치면 섀도잉이 된다(catalog의 `shadows`).
  키퍼 발행 스킬에 네임스페이스 규약이 필요한가, 섀도잉이 이미
  답인가.
- Available 리스트는 매 턴 모든 키퍼에게 상주한다. 발행 빈도의 자연
  상한(턴당 1건 등)을 도구에 싣는 것이 규범인가, 오염은 실제로
  관측된 뒤에 다룰 문제인가.
- 게임 지식이 "검증된 사실"인지는 도구가 강제할 수 없다. 지시문과
  스킬 규범 수준에서 담당한다 — 이 문서의 범위 밖이다.
