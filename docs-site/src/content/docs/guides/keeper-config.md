---
title: Keeper Runtime Configuration
description: User guide for tool_approval_timeout_sec, keeper_memory_select, and workspace memory metrics gauges.
---

## (a) Overview / 한 줄 요약

This guide details configuration settings for tuning human-in-the-loop (HITL) tool approval timeouts, enabling the purpose-driven `keeper_memory_select` tool, and observing workspace memory briefing and claim growth through Prometheus metrics gauges.

Keeper 런타임의 인간 개입(HITL) 도구 승인 대기 시간 조절, 목적 기반 장기 기억 선별 도구(`keeper_memory_select`) 활성화, 워크스페이스 메모리 관측 게이지 메트릭을 설정하고 제어하는 가이드입니다.

---

## (b1) Enabling: Settings & Environment Variables / 켜는 법: 설정 이름

### 1. Tool Approval Timeout (`tool_approval_timeout_sec`, #41768)
Controls the duration the runtime waits for an operator's approval when a Keeper invokes a sensitive tool protected by the Gate.

- **TOML Setting**: `<base-path>/.masc/config/runtime.toml`
  ```toml
  [keeper.hitl]
  tool_approval_timeout_sec = 300  # Default: 180 seconds. Clamped between 5 and 3600.
  ```
- **Environment Variable**:
  ```bash
  export MASC_KEEPER_TOOL_APPROVAL_TIMEOUT_SEC=300
  ```

### 2. Purpose-Driven Memory Selection (`keeper_memory_select`, #42075)
Enables the `keeper_memory_select` tool, allowing Keepers to retrieve verified current ordinary and source-bound memory facts relevant to an explicit decision context.

- **TOML Setting**: `<base-path>/.masc/config/runtime.toml`
  ```toml
  [typesafeai]
  workspace_memory_selection_enabled = true  # Default: false
  # excluded_keepers = ["some-keeper"]       # Optional exclusion list
  ```

### 3. Workspace Memory Observation Gauges (`gauge`, #42276, #42298)
Tracks briefing size and classified ledger claim count to prevent unbounded memory growth.

- **Metric Names**:
  - `masc_keeper_workspace_memory_briefing_bytes`: Current byte size of the published shared workspace briefing summary body.
  - `masc_keeper_workspace_memory_ledger_claims`: Total count of active classified memory claims in the shared ledger.
- **Activation**: Automatically collected at the `Workspace_memory_ledger.observe` boundary during both direct owner turns and unified wake turns. No configuration needed.

### Key Code & Module Coordinates
- `lib/keeper_config.ml`: HITL configuration parser and validation clamping.
- `lib/typesafeai/typesafeai_config.ml:140` & `lib/runtime/runtime_schema.ml:478`: `workspace_memory_selection_enabled` flag.
- `lib/keeper_metrics/keeper_workspace_memory_observation_metrics.ml:1-39`: Unlabeled gauge series definitions and update logic.
- `lib/keeper/keeper_turn.ml` & `lib/keeper/keeper_unified_turn.ml`: Turn observation hook boundaries.
- PR references: #41768 (`36db387f`), #42075 (`917cc096`), #42276 (`bfbb23bc`), #42298 (`c0ed3b7b`).

---

## (b2) Activation Conditions & Diagnostic Behavior / 켜지는 조건과 실패 증상

### Conditions
- **Tool Approval Timeout**:
  - Triggered whenever a Keeper turn generates an effect requiring Gate authorization (`intent = "request_effect"`).
  - Clamping: Any value below 5s is clamped to 5s; any value above 3600s is clamped to 3600s.
- **Memory Selection Tool**:
  - Requires `workspace_memory_selection_enabled = true`, an armed destination, and that the calling Keeper is not in `excluded_keepers`.
  - Revalidates underlying source-bound file bytes before returning claims.
- **Metrics Gauges**:
  - Emitted whenever a Keeper turn completes an observation pass.
  - Unlabeled single series: Both metrics publish exactly one global series for the workspace rather than proliferating per-Keeper copies (#42298).

### Failure Symptoms & Diagnostics
- **Approval Timeout Expiry**: When the timeout expires before operator decision, the tool call fails with a `timed_out` rejection. If the operator approves later, the response is routed to the late-approval journal rather than resurrecting the expired turn.
- **Memory Select Rejection**: If `workspace_memory_selection_enabled = false`, calling `keeper_memory_select` fails immediately with `workflow_rejection`.
- **Missing Briefing Gauge Retention**: If the shared briefing is temporarily missing or unreadable, the gauge retains its last measured size rather than erroneously dropping to 0 bytes (#42298).

---

## (c) Runnable Examples / 실행 예시

### 1. Configuration in `runtime.toml`
```toml
# Append to .masc/config/runtime.toml

[keeper.hitl]
# Set operator approval wait window to 5 minutes
tool_approval_timeout_sec = 300

[typesafeai]
# Enable purpose-based memory selection
workspace_memory_selection_enabled = true
```

### 2. Environment Variable Override
```bash
# Launch server with custom approval timeout
export MASC_KEEPER_TOOL_APPROVAL_TIMEOUT_SEC=600
dune exec bin/masc.exe -- run
```

### 3. Inspecting Memory Metrics via Curl
```bash
# Query the local Prometheus metrics endpoint
curl -s http://127.0.0.1:8935/metrics | grep masc_keeper_workspace_memory

# Example output:
# # HELP masc_keeper_workspace_memory_briefing_bytes Byte size of the published workspace briefing body
# # TYPE masc_keeper_workspace_memory_briefing_bytes gauge
# masc_keeper_workspace_memory_briefing_bytes 1814
# # HELP masc_keeper_workspace_memory_ledger_claims Count of classified memory claims in the shared ledger
# # TYPE masc_keeper_workspace_memory_ledger_claims gauge
# masc_keeper_workspace_memory_ledger_claims 422
```

---

## (d) Disabling & Reverting / 끄는 법 및 되돌리는 법

- **Reset Approval Timeout**: Remove `tool_approval_timeout_sec` or unset `MASC_KEEPER_TOOL_APPROVAL_TIMEOUT_SEC` to restore the 180s default.
- **Disable Memory Select**: Set `workspace_memory_selection_enabled = false` in `[typesafeai]`.
- **Metrics**: The metrics gauges are zero-overhead observation probes built into the turn pipeline and require no deactivation.

---

## (e) Experimental Status & Known Limitations / 실험 표시 및 알려진 한계

- **Status**: Stable in v0.52.0+.
- **Silent Clamping**: Setting `tool_approval_timeout_sec` outside 5–3600 seconds silently clamps the value without raising a configuration error.
- **Provenance Verification Latency**: When `keeper_memory_select` is called in workspaces with large numbers of source-bound facts, file hash revalidation across local worktrees may introduce slight turn latency.
- **Unlabeled Aggregation**: Gauges reflect workspace-level totals; individual Keeper attribution is not tracked in the metric series to avoid high-cardinality leakage.
