---
rfc: "keeper-writes-own-compositions"
title: "Keeper가 자기 composition 카탈로그를 쓴다 — 제안은 staged, 반영은 승인 뒤"
status: Draft
created: 2026-09-01
updated: 2026-09-01
author: claude
supersedes: []
superseded_by: null
related: ["skills-as-tools", "tools-as-shell-commands"]
implementation_prs: []
---

# RFC: Keeper가 자기 composition 카탈로그를 쓴다 (keeper-writes-own-compositions)

## 0. Summary

composition 카탈로그(`skills/<name>/SKILL.md`의 `[[compositions]]`)의 작성 주체를
사람만에서 Keeper로 확장한다. Keeper가 반복할 만한 묶음을 발견하면
`keeper_compose_save` 도구로 **제안**하고, 사람 승인 뒤 카탈로그에 반영된다.

## 1. 배경

- 카탈로그는 지금 3개(work-intake / mission-snapshot / background-snapshot)이고 전부
  사람이 손으로 썼다. 7일 호출 345회(work-intake 281) — **재사용 수요는 실증됐는데
  작성이 병목**이다.
- Hermes `skill_manage`의 문서화된 트리거 3종: (1) 반복할 만한 다단계 워크플로 발견
  (2) 막다른 길에서 작동 경로 발견 (3) 사용자 정정 학습. 저장은 staged + 사람 승인.
- 범용 문법이 0호출로 죽은 것과 대칭: 카탈로그를 **사용 중 발생한 필요**가 채우면
  채택 근거가 데이터로 생긴다.

## 2. 설계

### 2.1 도구 — 이름 붙은 능력 하나

`keeper_compose_save`는 composition 정의(TOML 조각)를 받아 **제안**으로 저장한다.
즉석 문법을 주지 않는다("모델은 이름과 설명이 붙은 능력을 고른다" — RFC skills-as-tools).

### 2.2 검증 — 새 검증기를 만들지 않는다

제안은 기존 `Keeper_tool_composition_catalog`의 파서·오류
(`Toml_syntax`, `Duplicate_composition_name`, `Invalid_composition_name_character`,
`Composition_name_too_long`, …)를 **그대로** 통과해야 한다. 사람이 쓰는 것과 같은
문이 유일한 문이다. 파서를 통과하지 못한 제안은 설명된 실패로 거부된다.

### 2.3 반영 — staged, 승인 뒤에만 카탈로그에

- 제안은 카탈로그 디렉터리에 바로 반영되지 않고 pending 상태로 기록된다(서버 재시작에
  유지).
- 승인은 기존 HITL 결의 배달 경로를 재사용한다(registry meta 기반 — 승인은 라이브
  메타데이터를 본다).
- 승인되면 카탈로그에 기록되고 다음 턴부터 `keeper_compose_<name>`으로 표면화된다
  (기존 메커니즘, 변경 없음).
- Keeper가 파일을 직접 쓰는 경로는 만들지 않는다. 쓰기는 이 도구를 통해서만.
  `policy.leaves_masc` 축에서 내부 쓰기로 분류된다.

### 2.4 트리거 — 런타임 프롬프트에 3종

`config/prompts/keeper.md`에 Hermes의 3종 트리거를 옮긴다. 이 파일은 계약이 아니라
런타임 프롬프트다(docs/AGENTS.md가 분리를 명시) — 계약 수정 없이 실험할 수 있다.

## 3. PoC 판정 기준

라이브 Keeper에 트리거 프롬프트를 넣고 1주일:

- 자발적 제안 수(keeper당), 사람 승인률, 승인된 composition의 재호출 수.
- 통과선: 승인된 묶음이 1주일 내 최소 1회 재호출(학습 루프가 닫히는 증거).
- 기각 시: 트리거 프롬프트 제거로 롤백(계약 변경이 없으므로 원복이 프롬프트 한 줄).

## 4. 단계

- **PR-1**: `keeper_compose_save` + 기존 파서 재사용 + pending 저장 + HITL 승인 연결.
- **PR-2**: 제안→승인→반영→호출 수명의 가시성(TUI/board). tools-as-shell-commands
  PR-3와 접점: composition 정의를 셸 라인으로도 표현 가능하게.

## 5. 반론과 답

- **"카탈로그 오염"** — 승인 게이트 + 중복 이름 거부(기존 검증). 오염 시도 자체도
  계측된다(제안 수 vs 승인률).
- **"Keeper가 만든 묶음의 품질"** — 승인 시점에 사람이 노드 정의를 그대로 본다.
  묶음 실행 증거는 기존 `skill-composition-evidence-v1` 체계가 남긴다.
- **"왜 자동 승인이 아닌가"** — 이 제품의 Keeper 쓰기 경로는 승인이 기본이다(바깥
  서비스 호출 Gate가 그 선례). 자동화는 실측이 쌓인 뒤 판단.

## 6. 근거

- 내부: `.tmp/toolstudy/masc-gap.md` §3 (composition 3개/345호출)
- 외부: `.tmp/toolstudy/survey-products.md` §5 (Hermes skill_manage)
- 백로그: issue #32369 작전 2
