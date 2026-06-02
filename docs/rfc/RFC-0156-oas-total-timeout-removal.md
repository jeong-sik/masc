---
name: RFC-0156
title: OAS total timeout 제거 — turn timeout + stream idle 두 layer로 단순화
status: Implemented
authors:
  - vincent.dev@kidsnote.com (Agent-LLM-A Opus 4.7 paired)
created: 2026-05-22
---

# RFC-0156: OAS total timeout 제거

## 1. 배경

이 RFC의 핵심은 `MASC_KEEPER_OAS_TIMEOUT_SEC` 기반 OAS total timeout 정책에서,
호출 인자가 무시된 상태로 `300` 초 상수형 동작이 남아 있던 상태를 정리하는 것이었다.
현재는 해당 기능이 회복된 정책으로 정리되어, OAS 시도별 예산은 아래와 같이 동작한다.

- `MASC_KEEPER_TURN_TIMEOUT_SEC`(wall-clock turn cap)을 기본 기준으로 사용.
- `MASC_KEEPER_OAS_TIMEOUT_SEC`는 레거시 override이며 설정 시 `turn_timeout_sec` 상한에서 clamp 후 적용.
- provider idle 처리의 실 유효 트리거는 `MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC`, HTTP error,
  completion contract로 남아 있다.

## 2. 구현 정리

### 2.1 소스 정합

```ocaml
(* lib/keeper/keeper_runtime_resolved.ml *)
let oas_call_timeout_sec () : float =
  let runtime = current () in
  match runtime.oas_timeout_override_sec.value with
  | Some value -> value
  | None -> runtime.turn_timeout_sec.value
```

```ocaml
(* lib/keeper/keeper_turn_runtime_budget.ml *)
let adaptive_timeout_sec = Keeper_runtime_resolved.oas_call_timeout_sec ()
```

`source` 라벨도 오래된 `"static_300s*"` 계열이 제거되어
`turn_budget_*` 계열로 수렴했다.

### 2.2 config 스냅샷 문서

`lib/config/env_config_snapshot.ml`에서 `MASC_KEEPER_OAS_TIMEOUT_SEC` 항목을
레거시 override 설명으로 정리했고, 이에 맞춰 런타임 노출 문서가 갱신 대상이 되었다.

## 3. env var 동작

| Env var | 동작 |
|---------|------|
| `MASC_KEEPER_OAS_TIMEOUT_SEC` | 레거시 override. 설정 시 값이 파싱되어 `turn_timeout_sec`에 clamp 됨 (`[30, turn_timeout_sec]`). 미설정 시 `MASC_KEEPER_TURN_TIMEOUT_SEC` 사용 |
| `MASC_KEEPER_TURN_TIMEOUT_SEC` | 단일 keeper turn wall-clock cap |
| `MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC` | 스트림 idle gap cap (provider 응답 단위의 stream idle 감시) |

## 4. 검증

- 문서/코드 정합:
  - `lib/config/env_config_snapshot.ml`, `README.md`, `docs/runtime-tunables.md` 업데이트.
- 런타임 테스트:
  - `test/test_keeper_unified.ml`: RFC-0156 커버 테스트(`static_300s` 미사용, override 계열 source 미발생, 타임아웃 감산 추적)
  - `test/test_work_as_heartbeat.ml`: `MASC_KEEPER_OAS_TIMEOUT_SEC` 미설정 시 `oas_call_timeout_sec = turn_timeout_sec` 검증

## 5. 위험 및 보완

- `MASC_KEEPER_OAS_TIMEOUT_SEC`는 호환성 레이어로 유지되므로,
  기존 프로필/스크립트의 override 값은 여전히 받아들여진다.
- 새 정책은 기존 300초 상수 라벨/동작을 더 이상 가정하지 않는다.
  즉, 회귀 탐지는 테스트로 처리한다.

## 6. 상태

현재 코드 기준으로 RFC 목표는 구현 완료 상태이다.
