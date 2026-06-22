# RFC-0280 Caller Context

Owner request, 2026-06-22 (Vincent, fusion 슬라이스 연속 — 슬라이스 2 머지 직후):

- AskUserQuestion "다음 Free Fusion 구현 슬라이스" → **B: typed Validated_graph** 선택.
  preview로 본 의도: "preset/panel_group을 parse-time 검증된 타입드 그래프로, illegal
  states 제거, 기존 of_toml 검증 → 타입 경계로 이동."
- "다음 구현 병렬로 진행해" → renumber(#22064 RFC-0279)를 백그라운드로 돌리며 본 슬라이스 진행.

수렴한 경계 결정 (앞선 대화, 슬라이스 1·2와 동일):

- Fusion = 심의 primitive로만. Router/Bind/Subgraph/loop는 짓지 않음. keeper 저작(C)은
  Phase-0 harness 게이트 뒤. 본 슬라이스는 그 C 전에 타입 안전을 깔아두는 작업.

Design constraints:

- `Validated_preset.t = private preset` + smart constructor `of_preset`. 검증을 한 곳으로,
  검증된 타입을 private로 → illegal states unrepresentable.
- `Fusion_policy.t.presets`를 validated로, 게이트 `decide`의 `preset_size_ok` 재검증 제거.
- config_error 출력·게이트 동작 byte-identical (검증 위치만 이동, 새 거부 규칙 없음).
- `run`은 raw groups primitive 유지(harness arm이 임의 그룹 구성). per-group NonEmpty는 비목표.

Verification expectation:

- 로컬 rfc-enforcer(R1–R5, 이 caller-context 포함) 통과.
- `test/fusion_core/test_fusion.ml` 기존 config 테스트 그대로 통과(동작 보존) +
  `Validated_preset.of_preset` 단위 테스트(각 invalid + Ok).
- OCaml 빌드는 CI에서 (사용자 지시). 로컬은 ocamlformat + DET/NDT 게이트만.
