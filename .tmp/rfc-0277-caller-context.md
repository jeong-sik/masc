# RFC-0277 Caller Context

Owner request, 2026-06-22 (Vincent, fusion 설계 대화):

- "Fusion 기능을 어디에든 붙였다 뗐다 할 수 있으면 좋겠다 / 병렬 조립만 된다고 하더라도
  훌륭할 수 있음 / 헤테로지니어스도 핵심이고." → 첫 슬라이스로 **이종 패널 그룹**
  (한 preset 안에서 서로 다른 system_prompt/web_tools/tool-budget/timeout을 가진
  그룹들이 하나의 judge로 수렴)을 operator-config 수준에서 구현.
- "budget 개념 필요없음 / 여기서 비용통제는 하나도 의미 없음." → RFC-0252 §6의
  발동 예산(`per_hour_budget` activation cap)을 메커니즘째 제거. cost-control cap을
  두지 않는다.

수렴한 경계 결정 (앞선 대화):

- Fusion = 심의(deliberation) primitive로만 남는다. Router/Bind/Subgraph/loop/일반
  태스크 분해는 짓지 않는다(전부 orchestration이고 masc에 이미 있음). ChainEngine
  부활(consumer 0으로 죽은 17K LOC)을 회피한다.
- keeper 저작(Free Fusion)은 Phase-0 harness 게이트 뒤로 미룬다. 본 RFC는 정적
  preset 안의 그룹 리스트만 다룬다.

Design constraints:

- `preset.panel : string list` → `preset.panels : panel_group list`. legacy flat
  `panel=[...]`는 같은 `parse_group`을 preset 테이블에 적용해 길이-1 그룹으로
  desugar — 운영자 TOML 0줄 변경, 단일 그룹이면 byte-identical.
- judge/sink 무변경(심판은 preset당 1개, 평면 panel_outcome list만 본다). 단일
  `Async_agent.all`로 union fan-out — 이종 설정은 build_agent 시점에 baked.
- byte-identity 복구: 심판 web_tools/max_tool_calls + 외곽 timeout이 오늘 preset-level
  값에서 왔으므로, 단일 그룹에서 같은 값을 derive하는 순수 함수
  (`judge_web_tools_of`/`judge_tool_budget_of`/`panel_outer_timeout_of`)를 둔다.
- 중복 모델은 parse-time `Duplicate_panel_model`로 거부(Async_agent.all 카드명 충돌
  방지). same-model-different-prompt는 비목표(후속).
- budget 제거: `Fusion_budget` 모듈·`per_hour_budget` 필드·`Over_hourly_budget`
  deny_reason·`Invalid_per_hour_budget` config_error·gate 소비·config 키 전부 제거.

Verification expectation:

- 본 RFC는 로컬 rfc-enforcer(R1–R5, 이 caller-context 포함)를 통과한다.
- `test/fusion_core/test_fusion.ml`이 golden 동등성(flat == 단일 그룹), 헤테로
  멀티그룹, strict 에러(empty/conflicting/duplicate), judge-arg byte-identity를
  증명한다 (32 tests).
- `dune build bin/fusion_run.exe`로 heavy Masc lib 포함 전체 컴파일을 확인한다.
