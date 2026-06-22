# RFC-0278 Caller Context

Owner request, 2026-06-22 (Vincent, fusion 설계 대화 — slice 1 머지 직후):

- AskUserQuestion "다음 구현" → **operator-config 슬라이스 2 (same-model-different-prompt)** 선택.
  "이야기 했지만 COST 는 중요하지 않음 여기서는" → 어떤 cost-control도 다시 넣지 않는다
  (RFC-0277에서 budget 전면 제거한 결정 유지).

수렴한 경계 결정 (앞선 대화, RFC-0277과 동일):

- Fusion = 심의(deliberation) primitive로만 남는다. Router/Bind/Subgraph/loop/일반
  태스크 분해는 짓지 않는다. keeper 저작(Free Fusion)은 Phase-0 harness 게이트 뒤.
- 본 RFC는 정적 preset 안의 패널 정체성만 다룬다.

Design constraints:

- `panel_group`에 `label : string`(기본 "") 추가. 패널 정체성 `panelist_id` =
  `if label="" then model else "label (model)"`. SSOT 함수 한 곳(`fusion_policy.ml`).
- 정체성을 model에서 분리: 카드명(Async_agent.all 반환 키)·심판 태그·panel_answer.model이
  정체성을 담고, provider 라우팅은 원 model로 build 시점에 따로. 두 개념을 한 문자열에
  압축하지 않는다.
- RFC-0277의 `preset_duplicate_model`(model 유일성)을 `preset_duplicate_panelist`
  (panelist_id 유일성)로 교체. 한 그룹 내 동일 model·라벨 없는 동일 model·동일 라벨+model을
  한 invariant로 흡수. 서로 다른 라벨의 동일 model은 통과.
- config_error `Duplicate_panel_model` → `Duplicate_panelist` rename.
- judge/sink/dashboard 무변경(이미 `.model`/synthesis 문자열 소비). OAS 0줄.
- byte-identity: label 없는 모든 config(legacy flat + RFC-0277 이종 그룹)는 정체성=model →
  오늘과 동일 동작.

Verification expectation:

- 본 RFC는 로컬 rfc-enforcer(R1–R5, 이 caller-context 포함)를 통과한다.
- `test/fusion_core/test_fusion.ml`이 정체성 SSOT(panelist_id), same-model-different-prompt
  통과(distinct ids + no duplicate), 라벨 없는 동일 model 거부(Duplicate_panelist),
  legacy 정체성=model 골든을 증명한다 (35 tests).
- `dune build bin/fusion_run.exe`로 heavy Masc lib 포함 전체 컴파일을 확인한다.
- ocamlformat 0.29.0 clean (변경 9파일).
