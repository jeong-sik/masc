---
title: Keeper 런타임 설정
description: tool_approval_timeout_sec, 영속 Keeper yolo 모드, keeper_memory_select, wiki_contents, microvm_dns, jsonl_retention_days 및 워크스페이스 메모리 메트릭 가이드.
---

## 개요

Keeper 런타임의 인간 개입(HITL) 도구 승인 대기 시간(`tool_approval_timeout_sec`)과 영속 `yolo` 모드, 목적 기반 장기 기억 선별 도구(`keeper_memory_select`), 워크스페이스 위키 목차 주입(`[wiki_contents]`), microVM 게스트 DNS(`[sandbox] microvm_dns`), 날짜별 JSONL 보존 기간(`[maintenance] jsonl_retention_days`), 그리고 OpenTelemetry(OTLP) 워크스페이스 메모리 관측 게이지 메트릭을 설정하고 제어하는 가이드입니다.

---

## 켜는 법: 설정 및 환경 변수

### 1. 도구 승인 대기 시간 (`tool_approval_timeout_sec`) 및 영속 `yolo` 모드
Keeper가 Gate 보호 대상 민감 도구를 호출했을 때 오퍼레이터의 승인을 기다리는 시간과, 열린 채팅 스트림 훅을 건너뛸지 여부를 제어합니다.

- **TOML 설정**: `<base-path>/.masc/config/runtime.toml`
  ```toml
  [keeper.hitl]
  tool_approval_timeout_sec = 300  # 기본값: 180초. 5~3600초 범위로 고정(clamp)됨.
  ```
- **환경 변수**:
  ```bash
  export MASC_KEEPER_TOOL_APPROVAL_TIMEOUT_SEC=300
  ```
- **영속 Keeper `yolo` 모드**: TUI의 Keepers 화면에서 `g`를 누르면 선택한 Keeper의 채팅 스트림 PreToolUse 승인 훅이 `auto`와 `yolo` 사이에서 전환됩니다. 이 설정은 워크스페이스 게이트 루트(`masc.tool_approval_modes.v1`)에 영속 저장되어 부팅 시 서버 레지스트리로 복원되므로, 서버를 재시작해도 유지되며 다시 `auto`로 바꿀 때까지 유지됩니다(단, 샌드박스 명령·외부 서비스 쓰기·영속 기억 쓰기 같은 외부 Gate 효과는 여전히 워크스페이스 Gate 정책을 따릅니다).

### 2. 목적 기반 기억 선별 (`keeper_memory_select`)
`keeper_memory_select` 도구를 활성화하여 Keeper가 명시적 의사결정 맥락에 맞는 일반 기억 및 원천 결속(source-bound) 사실을 선별 인출할 수 있게 합니다.

- **TOML 설정**: `<base-path>/.masc/config/runtime.toml`
  ```toml
  [typesafeai]
  workspace_memory_selection_enabled = true  # 기본값: false
  # excluded_keepers = ["some-keeper"]       # 선택적 제외 목록
  ```

### 3. 워크스페이스 위키 목차 주입 (`[wiki_contents]`)
`<base-path>/.masc/wiki`의 위키 페이지 목차(페이지당 제목·파일·요약 한 줄)를 매 Keeper 턴 시작 시 컨텍스트에 주입합니다.

- **TOML 설정**: `<base-path>/.masc/config/runtime.toml`
  ```toml
  [wiki_contents]
  enabled = true  # 기본값: true. false로 두면 모든 턴에서 위키 목차를 생략합니다.
  ```

### 4. MicroVM 샌드박스 게스트 DNS (`[sandbox] microvm_dns`)
microVM Keeper 게스트(`apple_container`, `microsandbox`, `nerdctl_kata`)에 전달할 사용자 정의 DNS 서버 목록을 설정합니다.

- **TOML 설정**: `<base-path>/.masc/config/runtime.toml`
  ```toml
  [sandbox]
  microvm_dns = ["1.1.1.1", "8.8.8.8"]  # 유효한 IPv4 또는 IPv6 리터럴 목록
  ```

### 5. 날짜별 JSONL 저장소 보존 기간 (`[maintenance] jsonl_retention_days`)
`.masc/` 아래의 날짜별 JSONL 저장소(`audit`, `telemetry`, `tool_usage`, `tool_calls`, `agent-core-events` 등)에 대해 시작 시 정리 및 24시간 주기 정리가 공유하는 보존 일수를 설정합니다.

- **TOML 설정**: `<base-path>/.masc/config/runtime.toml`
  ```toml
  [maintenance]
  jsonl_retention_days = 30  # 양의 정수; 기본값 30
  ```
- **환경 변수**: `MASC_JSONL_RETENTION_DAYS` (`runtime.toml`보다 우선).

### 6. 워크스페이스 메모리 관측 게이지 (`gauge`)
브리핑 크기와 분류된 원장 주장(claim) 수를 추적합니다.

- **메트릭 이름**:
  - `masc_keeper_workspace_memory_briefing_bytes`: 발행된 공유 워크스페이스 브리핑 요약 본문의 현재 바이트 크기.
  - `masc_keeper_workspace_memory_ledger_claims`: 공유 원장에 활성 상태로 분류된 기억 주장 총수.
- **활성화**: 직접 오너 턴과 통합 깨움(unified wake) 턴 모두에서 `Workspace_memory_ledger.observe` 경계마다 자동 수집됩니다. 별도 설정은 필요 없습니다.

### 주요 코드 및 모듈 좌표
- `lib/keeper/keeper_config.ml` 및 `lib/keeper/keeper_config.mli`: HITL 설정 파서 및 범위 고정(`tool_approval_timeout_sec`).
- `lib/keeper/keeper_tool_approval_mode.ml` 및 `lib/keeper/keeper_tool_approval_mode.mli`: 영속 `auto` / `yolo` 도구 승인 모드 저장소 및 부팅 복원.
- `lib/typesafeai/typesafeai_config.ml` & `lib/runtime/runtime_schema.ml`: `workspace_memory_selection_enabled` 플래그.
- `lib/keeper/keeper_workspace_memory_observation_metrics.ml`: 무라벨(unlabeled) 게이지 시리즈 정의 및 갱신 로직(`record`).
- `lib/keeper/keeper_turn.ml` & `lib/keeper/keeper_unified_turn.ml`: 턴 관측 훅 경계.

---

## 활성화 조건과 진단 동작

### 조건
- **도구 승인 대기 시간**:
  - Keeper 턴이 Gate 승인이 필요한 효과(`intent = "request_effect"`)를 생성할 때마다 적용됩니다.
  - 범위 고정: 5초 미만은 5초로, 3600초 초과는 3600초로 고정됩니다.
- **기억 선별 도구**:
  - `workspace_memory_selection_enabled = true`이고 대상(destination)이 준비되어 있으며 호출 Keeper가 `excluded_keepers`에 없어야 합니다.
  - 주장을 반환하기 전에 원천 결속 파일의 바이트 해시를 재검증합니다.
- **메트릭 게이지**:
  - Keeper 턴이 관측 패스를 마칠 때마다 기록됩니다.
  - 단일 시리즈: 두 메트릭 모두 Keeper별 복사본을 늘리지 않고 워크스페이스 전체에 대해 하나의 전역 시리즈를 발행합니다.

### 실패 증상 및 진단
- **승인 타임아웃 만료**: 오퍼레이터 결정 전에 타임아웃이 만료되면 도구 호출은 `timed_out` 거절로 실패합니다. 이후 오퍼레이터가 뒤늦게 승인하더라도 만료된 턴을 되살리지 않고 지연 승인 저널(late-approval journal)로 기록합니다.
- **기억 선별 거절**: `workspace_memory_selection_enabled = false`인 상태에서 `keeper_memory_select`를 호출하면 즉시 `workflow_rejection`으로 실패합니다.
- **브리핑 누락 시 게이지 유지**: 공유 브리핑이 일시적으로 없거나 읽을 수 없을 때 게이지는 0 바이트로 떨어지지 않고 마지막 실측 크기를 유지합니다.

---

## 실행 예시

### 1. `runtime.toml` 설정
```toml
# .masc/config/runtime.toml

[wiki_contents]
enabled = true

[maintenance]
jsonl_retention_days = 30

[sandbox]
microvm_dns = ["1.1.1.1", "8.8.8.8"]

[keeper.hitl]
# 오퍼레이터 승인 대기 창을 5분으로 설정
tool_approval_timeout_sec = 300

[typesafeai]
# 목적 기반 기억 선별 활성화
workspace_memory_selection_enabled = true
```

### 2. 환경 변수 오버라이드
```bash
# 사용자 정의 승인 타임아웃과 JSONL 보존 일수로 서버 시작
export MASC_KEEPER_TOOL_APPROVAL_TIMEOUT_SEC=600
export MASC_JSONL_RETENTION_DAYS=14
masc start --base-path . --port 8935
```

### 3. OpenTelemetry (OTLP)로 메모리 게이지 내보내기
게이지는 `Otel_metric_store`에 저장되며 매 수집 틱마다 OpenTelemetry OTLP로 푸시됩니다(`lib/otel_metrics/otel_metrics.mli`, `lib/otel_spans/otel_config.mli`; 레거시 `/metrics` 스크레이프 경로는 RFC-0217 S4-2에서 폐지됨):
```bash
# 로컬 OTLP HTTP 컬렉터로 OTel 내보내기 활성화 (기본값 http://127.0.0.1:4318)
export MASC_OTEL_ENABLED=true
export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4318"
masc start --base-path . --port 8935

# OTLP 메트릭 배치로 내보내지는 게이지 시리즈 이름:
# - masc_keeper_workspace_memory_briefing_bytes (Gauge, unlabeled)
# - masc_keeper_workspace_memory_ledger_claims (Gauge, unlabeled)
```

---

## 끄는 법 및 되돌리는 법

- **승인 타임아웃 초기화**: `tool_approval_timeout_sec`를 제거하거나 `MASC_KEEPER_TOOL_APPROVAL_TIMEOUT_SEC`를 해제하면 기본값 180초로 돌아갑니다.
- **Keeper `yolo` 모드 해제**: TUI에서 해당 Keeper를 선택하고 `g`를 누르면(또는 API로 `auto`를 지정하면) 영속 오버라이드 행이 제거됩니다.
- **위키 목차 주입 끄기**: `[wiki_contents] enabled = false`로 설정합니다.
- **기억 선별 끄기**: `[typesafeai]`에서 `workspace_memory_selection_enabled = false`로 설정합니다.
- **메트릭**: 메트릭 게이지는 턴 관측 파이프라인에 내장되어 있어 별도 비활성화가 필요하지 않습니다.

---

## 상태 및 알려진 한계

- **지원 상태**: v0.52.0 이상에서 안정 지원.
- **범위 자동 고정**: `tool_approval_timeout_sec`를 5~3600초 밖으로 지정하면 설정 오류를 내지 않고 범위 안으로 고정합니다.
- **원천 검증 지연**: 원천 결속 사실이 많은 워크스페이스에서 `keeper_memory_select`를 호출하면 로컬 워크트리의 파일 해시 재검증으로 인해 약간의 턴 지연이 발생할 수 있습니다.
- **무라벨 집계**: 게이지는 워크스페이스 전체 합계를 나타내며, 고카디널리티(high-cardinality) 방지를 위해 개별 Keeper별 라벨은 분리하지 않습니다.
