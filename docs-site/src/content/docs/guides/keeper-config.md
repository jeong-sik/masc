---
title: Keeper Runtime Configuration
description: User guide for tool_approval_timeout_sec, persistent Keeper yolo mode, keeper_memory_select, wiki_contents, microvm_dns, jsonl_retention_days, and workspace memory metrics gauges.
---

## Overview

This guide details configuration settings for tuning human-in-the-loop (HITL) tool approval timeouts and persistent Keeper `yolo` mode, enabling the purpose-driven `keeper_memory_select` tool and workspace wiki table-of-contents injection (`[wiki_contents]`), configuring microVM guest DNS (`[sandbox] microvm_dns`) and JSONL retention (`[maintenance] jsonl_retention_days`), and observing workspace memory briefing and claim growth through OpenTelemetry (OTLP) metrics gauges.

---

## Enabling: Settings & Environment Variables

### 1. Tool Approval Timeout (`tool_approval_timeout_sec`) & Persistent `yolo` Mode
Controls the duration the runtime waits for an operator's approval when a Keeper invokes a sensitive tool protected by the Gate, and whether the open chat stream hook is skipped per Keeper.

- **TOML Setting**: `<base-path>/.masc/config/runtime.toml`
  ```toml
  [keeper.hitl]
  tool_approval_timeout_sec = 300  # Default: 180 seconds. Clamped between 5 and 3600.
  ```
- **Environment Variable**:
  ```bash
  export MASC_KEEPER_TOOL_APPROVAL_TIMEOUT_SEC=300
  ```
- **Persistent Keeper `yolo` Mode**: Pressing `g` on the Keepers surface toggles a Keeper between `auto` and `yolo` for the chat stream PreToolUse approval hook. Overrides are persisted on disk under the workspace gate root (`masc.tool_approval_modes.v1`) and replayed into the server registry at boot so the stance survives server restarts until explicitly switched back to `auto`. (External Gate effects such as sandbox commands, attached service writes, and durable memory writes are still governed by the workspace Gate policy.)

### 2. Purpose-Driven Memory Selection (`keeper_memory_select`)
Enables the `keeper_memory_select` tool, allowing Keepers to retrieve verified current ordinary and source-bound memory facts relevant to an explicit decision context.

- **TOML Setting**: `<base-path>/.masc/config/runtime.toml`
  ```toml
  [typesafeai]
  workspace_memory_selection_enabled = true  # Default: false
  # excluded_keepers = ["some-keeper"]       # Optional exclusion list
  ```

### 3. Workspace Wiki Table of Contents (`[wiki_contents]`)
Injects the Workspace Wiki table of contents (one line per page: title, file, summary) from `<base-path>/.masc/wiki` at the start of every Keeper turn.

- **TOML Setting**: `<base-path>/.masc/config/runtime.toml`
  ```toml
  [wiki_contents]
  enabled = true  # Default: true. Set false to omit the wiki listing from Keeper turns.
  ```

### 4. MicroVM Sandbox Guest DNS (`[sandbox] microvm_dns`)
Configures custom DNS servers passed into microVM Keeper guests (`apple_container`, `microsandbox`, `nerdctl_kata`).

- **TOML Setting**: `<base-path>/.masc/config/runtime.toml`
  ```toml
  [sandbox]
  microvm_dns = ["1.1.1.1", "8.8.8.8"]  # Valid IPv4 or IPv6 literals
  ```

### 5. Dated JSONL Store Retention (`[maintenance] jsonl_retention_days`)
Controls the day-file retention window for dated JSONL stores under `.masc/` (`audit`, `telemetry`, `tool_usage`, `tool_calls`, `agent-core-events`, etc.), shared by startup prune and periodic 24-hour maintenance prune.

- **TOML Setting**: `<base-path>/.masc/config/runtime.toml`
  ```toml
  [maintenance]
  jsonl_retention_days = 30  # Positive integer; default 30
  ```
- **Environment Variable**: `MASC_JSONL_RETENTION_DAYS` (takes precedence over `runtime.toml`).

### 6. Workspace Memory Observation Gauges (`gauge`)
Tracks briefing size and classified ledger claim count to monitor memory growth.

- **Metric Names**:
  - `masc_keeper_workspace_memory_briefing_bytes`: Current byte size of the published shared workspace briefing summary body.
  - `masc_keeper_workspace_memory_ledger_claims`: Total count of active classified memory claims in the shared ledger.
- **Activation**: Automatically collected at the `Workspace_memory_ledger.observe` boundary during both direct owner turns and unified wake turns. No configuration needed.

### Key Code & Module Coordinates
- `lib/keeper/keeper_config.ml` and `lib/keeper/keeper_config.mli`: HITL configuration parser and validation clamping (`tool_approval_timeout_sec`).
- `lib/keeper/keeper_tool_approval_mode.ml` & `lib/keeper/keeper_tool_approval_mode.mli`: Persistent `auto` / `yolo` tool approval stance store and boot replay.
- `lib/typesafeai/typesafeai_config.ml` & `lib/runtime/runtime_schema.ml`: `workspace_memory_selection_enabled` flag.
- `lib/keeper/keeper_workspace_memory_observation_metrics.ml`: Unlabeled gauge series definitions and update logic (`record`).
- `lib/keeper/keeper_turn.ml` & `lib/keeper/keeper_unified_turn.ml`: Turn observation hook boundaries.

---

## Activation Conditions & Diagnostic Behavior

### Conditions
- **Tool Approval Timeout**:
  - Triggered whenever a Keeper turn generates an effect requiring Gate authorization (`intent = "request_effect"`).
  - Clamping: Any value below 5s is clamped to 5s; any value above 3600s is clamped to 3600s.
- **Memory Selection Tool**:
  - Requires `workspace_memory_selection_enabled = true`, an armed destination, and that the calling Keeper is not in `excluded_keepers`.
  - Revalidates underlying source-bound file bytes before returning claims.
- **Metrics Gauges**:
  - Emitted whenever a Keeper turn completes an observation pass.
  - Unlabeled single series: Both metrics publish exactly one global series for the workspace rather than proliferating per-Keeper copies.

### Failure Symptoms & Diagnostics
- **Approval Timeout Expiry**: When the timeout expires before operator decision, the tool call fails with a `timed_out` rejection. If the operator approves later, the response is routed to the late-approval journal rather than resurrecting the expired turn.
- **Memory Select Rejection**: If `workspace_memory_selection_enabled = false`, calling `keeper_memory_select` fails immediately with `workflow_rejection`.
- **Missing Briefing Gauge Retention**: If the shared briefing is temporarily missing or unreadable, the gauge retains its last measured size rather than dropping to 0 bytes.

---

## Runnable Examples

### 1. Configuration in `runtime.toml`
```toml
# In .masc/config/runtime.toml

[wiki_contents]
enabled = true

[maintenance]
jsonl_retention_days = 30

[sandbox]
microvm_dns = ["1.1.1.1", "8.8.8.8"]

[keeper.hitl]
# Set operator approval wait window to 5 minutes
tool_approval_timeout_sec = 300

[typesafeai]
# Enable purpose-based memory selection
workspace_memory_selection_enabled = true
```

### 2. Environment Variable Override
```bash
# Launch server with custom approval timeout and JSONL retention
export MASC_KEEPER_TOOL_APPROVAL_TIMEOUT_SEC=600
export MASC_JSONL_RETENTION_DAYS=14
masc start --base-path . --port 8935
```

### 3. Exporting Memory Gauges via OpenTelemetry (OTLP)
The gauges are stored in `Otel_metric_store` and pushed via OpenTelemetry OTLP on each collector tick (`lib/otel_metrics/otel_metrics.mli`, `lib/otel_spans/otel_config.mli`; the legacy `/metrics` scrape route was retired in RFC-0217 S4-2):
```bash
# Enable OTel export to a local OTLP HTTP collector (defaults to http://127.0.0.1:4318)
export MASC_OTEL_ENABLED=true
export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4318"
masc start --base-path . --port 8935

# Exported gauge series names in OTLP metric batches:
# - masc_keeper_workspace_memory_briefing_bytes (Gauge, unlabeled)
# - masc_keeper_workspace_memory_ledger_claims (Gauge, unlabeled)
```

---

## Disabling & Reverting

- **Reset Approval Timeout**: Remove `tool_approval_timeout_sec` or unset `MASC_KEEPER_TOOL_APPROVAL_TIMEOUT_SEC` to restore the 180s default.
- **Revert Keeper `yolo` Mode**: Press `g` on the selected Keeper in the TUI (or set mode to `auto` via the API) to remove the persisted override row.
- **Disable Wiki Table of Contents**: Set `[wiki_contents] enabled = false`.
- **Disable Memory Select**: Set `workspace_memory_selection_enabled = false` in `[typesafeai]`.
- **Metrics**: The metrics gauges are built into the turn observation pipeline and require no separate deactivation.

---

## Status & Known Limitations

- **Status**: Stable in v0.52.0+.
- **Silent Clamping**: Setting `tool_approval_timeout_sec` outside 5–3600 seconds clamps the value without raising a configuration error.
- **Provenance Verification Latency**: When `keeper_memory_select` is called in workspaces with large numbers of source-bound facts, file hash revalidation across local worktrees may add turn latency.
- **Unlabeled Aggregation**: Gauges reflect workspace-level totals; individual Keeper attribution is not tracked in the metric series to avoid high-cardinality series.
