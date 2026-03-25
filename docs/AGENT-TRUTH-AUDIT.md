# Agent Truth Audit

Status: active contract on `main`
Date: 2026-03-11

## Purpose

`masc-mcp`에서 agent처럼 보이는 surface는 다음 중 하나로 명시되어야 한다.

- `truth`: 원천 상태. 읽기 모델이 아니라 사실 기록이다.
- `judgment`: MODEL + prompt + runtime/tool path로 생성된 판단이다.
- `derived`: truth를 결정적으로 압축하거나 번역한 읽기 모델이다.
- `fallback`: primary judgment가 없거나 실패했을 때 쓰는 결정적 대체 경로다.
- `narrative`: 사람을 위한 MODEL 서술 계층이다. 제어면의 canonical judgment가 아니다.
- `simulation`: 의도적으로 비실런타임인 compatibility/test surface다.
- `placeholder`: 미완성 또는 기본 노출 금지 surface다.

이 구분이 없는 public surface는 설계 버그로 본다.

## Current Main Contract

### Tool catalog

- `implementationStatus`가 tool truth의 기본 계약이다.
- default-visible tool은 `real` 또는 `adapter`만 허용한다.
- `simulation`과 `placeholder`는 기본 노출 금지다.

### Operator / Swarm / Mission

- `command_plane`은 `truth`
- `swarm_status`는 `derived`
- `attention_items`는 `derived`
- `recommended_actions`와 `recommended_next_action`은 `fallback`
- `Mission briefing`은 `narrative`

`operator_control`과 `swarm_status`는 resident judge가 없으므로 현재 canonical judgment owner가 아니다. 둘 다 fallback read-model 계층으로 노출한다.

### Keeper / classifier-style surfaces

- `keeper` skill selection 기본값은 `agent` 경로다.
- `capability_match` 기본값은 `hybrid`다.
즉 primary path는 MODEL judgment를 먼저 시도하고, 실패 시에만 fallback을 쓴다.

## Validation

최소 검증 명령:

```bash
dune build ./_build/default/test/test_tool_contract_truth.exe \
  ./_build/default/test/test_operator_control.exe \
  ./_build/default/test/test_swarm_status.exe \
  ./_build/default/test/test_dashboard_mission_briefing.exe \
  ./_build/default/test/test_capability_match_coverage.exe

./_build/default/test/test_tool_contract_truth.exe
./_build/default/test/test_operator_control.exe
./_build/default/test/test_swarm_status.exe
./_build/default/test/test_dashboard_mission_briefing.exe
./_build/default/test/test_capability_match_coverage.exe
```

이 검증의 목적은 품질 점수보다 truthfulness다.

- public JSON에 provenance가 있는가
- heuristic surface가 fallback/derived로 격하되어 있는가
- model-first path가 기본값으로 설정되어 있는가
- placeholder/simulation이 truth surface로 위장하지 않는가
