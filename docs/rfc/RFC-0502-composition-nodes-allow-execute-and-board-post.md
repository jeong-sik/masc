---
rfc: "0502"
title: "Keeper가 쓰는 합성의 노드 집합을 Execute와 게시까지 넓힌다"
status: Active
created: 2026-11-06
updated: 2026-11-09
author: github-pr-checker
supersedes: []
superseded_by: null
related: ["keeper-writes-own-compositions"]
implementation_prs: ["#50328"]
---

# RFC-0502 — 합성 노드 집합에 Execute와 게시를 허용한다

## 0. 요약

- Keeper가 만든 합성(composition) 스킬은 0개다. 카탈로그 53개 중 합성 4개는 전부 운영자 소유다(#49177).
- Keeper가 합성에 넣으려다 실패한 노드는 `Execute`와 `masc_board_post`다 — 노드 집합에 없어 거절됐다.
- 이 RFC는 합성 노드 집합에 두 도구를 추가할지 묻는 결정 초안이다. 두 도구는 이미 각자의 권한 경계(Gate 승인·게시 정책, 파일 생산자 권한 확인·저장 복구)를 통과하므로, 합성 안에서 불려도 권한 범위가 넓어지지 않는다.

## 1. 배경

- Keeper 15명이 지시형 스킬 24개를 만들어 1,079번 썼다(791번은 만든 Keeper가 아닌 다른 Keeper가 사용). 합성은 0개다 — 재사용 수요는 실증돼 있는데 만들 수 있는 합성이 없다(#49177).
- 노드 집합이 좁은 것이 원인 추정이다. 비동기 합성 0개도 같은 원인으로 본다.
- 10-25에는 같은 입력의 `keeper_skill_validate`가 1,632번 실패했다. 턴에는 실패한 읽기·검증 호출을 끊는 회로 차단기가 없어(같은 이슈에 보고) 같은 실패가 되풀이됐다 — 수요가 계속 검증에 부딪혔다는 뜻이다.
- 계보: `RFC-keeper-writes-own-compositions`(Draft)가 작성 주체 확장을 다룬다. 이 RFC는 그 전 단계인 "노드 집합 자체가 좁아 제안 자체가 성립하지 않는다"는 문제를 다룬다. `RFC-widen-whole-sets`(Dropped)는 회수 단위 문제로 별개다.

## 2. 제안

- 합성 노드 집합에 `Execute`와 `masc_board_post`를 추가한다.
- 안전 근거: (1) `Execute`는 효과 단계에서 Gate 승인을 거친다(intent=request_effect). (2) `masc_board_post`는 Board 게시 정책을 통과한다. (3) 파일 도구 단계는 이미 시스템 계약상 파일 생산자 권한 확인과 저장 복구를 거친다. 합성 실행기가 이 도구들을 대신 불 때 같은 경계를 통과하는 한 권한은 그대로다.
- 반복 실패 차단(보조 설계): 턴 스코프에서 (도구, 입력 digest)가 연속 N회 실패하면 같은 호출을 거절하고 실패 요약을 모델에 돌려준다. 이 절은 별도 구현 RFC로 갈라도 된다.

## 3. 구현 메모

- 노드 집합 검증 코드의 위치는 구현 세션이 특정한다 — 이 RFC는 좌표를 특정하지 못했다.
- `keeper-writes-own-compositions`의 staged 제안 경로(제안 → 사람 승인 → 카탈로그 반영)와 함께 가는 것을 권한다.
- 2026-11-09 현재 상태: 노드 집합에 `Execute`·`masc_board_post`를 넣는 변경은 #50328 로 main 에 착지했다(병합 2026-11-09T03:19:55Z). §4 의 두 항목은 아직 관측이 없다 — (1) 뒷부분 "Keeper 가 만든 합성 1개 이상이 검증·실행에 성공" 의 런타임 관측, (2) 같은 입력의 반복 실패 N회 차단. (2)는 이 RFC 본문이 "별도 구현 RFC 로 갈라도 된다"고 밝힌 항목이다. 그래서 status 는 `Implemented` 가 아니라 `Active` 로 둔다.

## 4. 완료 판정

- [ ] 노드 집합 정의가 두 도구를 포함하고, Keeper가 만든 합성 1개 이상이 검증·실행에 성공한다.
- [ ] 같은 입력의 반복 검증 실패가 턴에서 N회 후 끊기는 관측이 1건 이상 남는다.
