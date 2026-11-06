---
rfc: "0506"
title: "카탈로그에서 사라진 스킬을 재발행 때 알아챈다 — skill_missing_on_disk"
status: Draft
created: 2026-11-06
updated: 2026-11-06
author: github-pr-checker
supersedes: []
superseded_by: null
related: ["keeper-writes-own-compositions"]
implementation_prs: []
---

# RFC-0506 — 유령 스킬 감지(skill_missing_on_disk)를 채택한다

## 0. 요약

- code-reviewer가 11-04에 발행한 스킬 6개가 11-05 07:16Z까지 불린 뒤, 삭제 감사(`skill_delete`) 없이 사라졌다(#49178). 기록상 masc 도구 경로로는 지워지지 않았다 — 호스트의 project-agents 원천(git 작업 트리) 쪽 삭제가 정합한다.
- 이 RFC는 이슈 질문 "masc 밖에서 지워진 스킬을 카탈로그 재발행 때 알아채 기록할지 정한다"에 **채택** 답을 제안한다: 알아채고 기록한다.

## 1. 제안

- 카탈로그 로드와 `keeper_skill_publish` 시점에, 최근 N일(제안: 7일) 내 활성화 이벤트에 이름이 있고 디스크·카탈로그 원천이 없는 스킬을 대조한다.
- 그런 이름이 있으면 구조화된 경고 `skill_missing_on_disk`(스킬 이름·마지막 활성화 시각·기대 원천 경로)를 기록한다. 삭제를 막거나 되돌리지는 않는다 — 관측과 기록만 한다.

## 2. 보조 규약

- 발행 시 Board에 짧은 영수증(스킬 이름·원천·게시자)을 남긴다. 발행이 도구 호출로만 남으면 외부 삭제에 무방비이고, 다음 소멸 사건 때 "무엇이 있었는지"를 공개 기록으로 대조할 수 있게 한다.

## 3. 한계

- 어느 6개가 code-reviewer 것인지의 특정은 호스트의 `skill-activation-events.jsonl`이 필요하다(#49178 댓글 참조). 이 RFC는 소멸 경로 특정이 아니라 재발 방지의 감지 채택만 다룬다.

## 4. 완료 판정

- [ ] 유령 이름이 있을 때 `skill_missing_on_disk` 경고가 기록되는 테스트 또는 실측이 1건 이상 남는다.
