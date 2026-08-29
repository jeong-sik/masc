# Keeper Tool Boundary Matrix

Status: P0 ratchet source for keeper agent tool boundaries.
Last updated: 2026-08-09.

This matrix freezes the owner map for keeper modules that participate in the
agent tool path. A new file in scope must be added here with exactly one owner
category before it can land.

Audit command:

```bash
scripts/audit-keeper-tool-boundary-matrix.sh
```

Scope:

```text
^lib/keeper/keeper_(gh|hooks|sandbox|exec|shell|tool|tools)[^/]*\.mli?$
```

## Owner Categories

| Owner | Responsibility | Must not own |
| --- | --- | --- |
| `execution-dispatch` | Keeper-side command, board, status, task, keeper, memory, and receipt execution dispatch. | Tool name policy, sandbox runtime mechanics, GitHub transport details. |
| `hook-observation` | agent core hook event parsing, metrics, and observational adapters. | agent core tool handler execution or keeper runtime dispatch. |
| `agent-core-tool-bridge` | Keeper tool bridge for agent core bundle, handler, telemetry, and deterministic errors. | Generic tool policy or non-agent core hook observation. |
| `sandbox-runtime` | Sandbox containment, Docker runtime, read/session runners, executor, and shell IR target plumbing. | Tool naming policy or GitHub runtime. |
| `shell-surface` | Shell command parsing, typed Execute input, shell ops, path, runtime paths, and timeout semantics. | Sandbox runtime or keeper tool registry/policy. |
| `tool-surface-policy` | Keeper tool aliasing, boundary, disclosure, diversity, emission, registry, policy, resolution, and tool-specific policy records. | agent core bridge implementation, shell parsing, sandbox execution. |

## Coverage Manifest

Each path below must appear exactly once and use one owner from the table above.

- `lib/keeper/keeper_tool_board_runtime.ml` - execution-dispatch
- `lib/keeper/keeper_tool_board_runtime.mli` - execution-dispatch
- `lib/keeper/keeper_tool_code_query.ml` - execution-dispatch
- `lib/keeper/keeper_tool_code_query.mli` - execution-dispatch
- `lib/keeper/keeper_tool_filesystem_runtime.ml` - execution-dispatch
- `lib/keeper/keeper_tool_filesystem_runtime.mli` - execution-dispatch
- `lib/keeper/keeper_tool_ide_runtime.ml` - execution-dispatch
- `lib/keeper/keeper_tool_ide_runtime.mli` - execution-dispatch
- `lib/keeper/keeper_tool_in_process_runtime.ml` - execution-dispatch
- `lib/keeper/keeper_tool_in_process_runtime.mli` - execution-dispatch
- `lib/keeper/keeper_tool_memory_runtime.ml` - execution-dispatch
- `lib/keeper/keeper_tool_memory_runtime.mli` - execution-dispatch
- `lib/keeper/keeper_tool_registered_runtime.ml` - execution-dispatch
- `lib/keeper/keeper_tool_registered_runtime.mli` - execution-dispatch
- `lib/keeper/keeper_tool_shared_runtime.ml` - execution-dispatch
- `lib/keeper/keeper_tool_shared_runtime.mli` - execution-dispatch
- `lib/keeper/keeper_tool_task_runtime.ml` - execution-dispatch
- `lib/keeper/keeper_tool_task_runtime.mli` - execution-dispatch
- `lib/keeper/keeper_tool_terminal_boundary.ml` - execution-dispatch
- `lib/keeper/keeper_tool_terminal_boundary.mli` - execution-dispatch
- `lib/keeper/keeper_tool_voice_runtime.ml` - execution-dispatch
- `lib/keeper/keeper_tool_voice_runtime.mli` - execution-dispatch
- `lib/keeper/keeper_tool_webmcp.ml` - execution-dispatch
- `lib/keeper/keeper_tool_webmcp.mli` - execution-dispatch
- `lib/keeper/keeper_tool_dispatch_runtime.ml` - execution-dispatch
- `lib/keeper/keeper_tool_dispatch_runtime.mli` - execution-dispatch
- `lib/keeper/keeper_tool_runtime.ml` - execution-dispatch
- `lib/keeper/keeper_tool_runtime.mli` - execution-dispatch
- `lib/keeper/keeper_execution_receipt_types.ml` - execution-dispatch
- `lib/keeper/keeper_execution_receipt_types.mli` - execution-dispatch
- `lib/keeper_failure_taxonomy/keeper_execution_receipt_failure_site.ml` - execution-dispatch
- `lib/keeper_failure_taxonomy/keeper_execution_receipt_failure_site.mli` - execution-dispatch
- `lib/keeper_outcome_taxonomy/keeper_execution_receipt_outcome_kind.ml` - execution-dispatch
- `lib/keeper_outcome_taxonomy/keeper_execution_receipt_outcome_kind.mli` - execution-dispatch
- `lib/keeper/keeper_execution_receipt.ml` - execution-dispatch
- `lib/keeper/keeper_execution_receipt.mli` - execution-dispatch
- `lib/keeper/keeper_execution_outcome.ml` - execution-dispatch
- `lib/keeper/keeper_execution_outcome.mli` - execution-dispatch
- `lib/keeper/keeper_execution.ml` - execution-dispatch
- `lib/keeper/keeper_execution.mli` - execution-dispatch
- `lib/keeper/keeper_tool_execution.ml` - execution-dispatch
- `lib/keeper/keeper_tool_execution.mli` - execution-dispatch
- `lib/keeper/keeper_tool_plan_executor.ml` - execution-dispatch
- `lib/keeper/keeper_tool_plan_executor.mli` - execution-dispatch
- `lib/keeper/keeper_execution_join.ml` - execution-dispatch
- `lib/keeper/keeper_execution_join.mli` - execution-dispatch
- `lib/keeper/keeper_hooks_agent_core_cost_events.ml` - hook-observation
- `lib/keeper/keeper_hooks_agent_core_cost_events.mli` - hook-observation
- `lib/keeper/keeper_hooks_agent_core_introspection.ml` - hook-observation
- `lib/keeper/keeper_hooks_agent_core_introspection.mli` - hook-observation
- `lib/keeper/keeper_hooks_agent_core_response_metrics.ml` - hook-observation
- `lib/keeper/keeper_hooks_agent_core_response_metrics.mli` - hook-observation
- `lib/keeper_hooks_agent_core_types/keeper_hooks_agent_core_types.ml` - hook-observation
- `lib/keeper_hooks_agent_core_types/keeper_hooks_agent_core_types.mli` - hook-observation
- `lib/keeper/keeper_hooks_agent_core.ml` - hook-observation
- `lib/keeper/keeper_hooks_agent_core.mli` - hook-observation
- `lib/keeper/keeper_tool_activity.ml` - hook-observation
- `lib/keeper/keeper_tool_activity.mli` - hook-observation
- `lib/keeper/keeper_sandbox_containment.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_containment.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_control.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_control.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_control_contract.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_control_contract.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_docker_container_name.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_docker_container_name.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_docker.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_docker.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_microvm.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_microvm.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_ssh.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_ssh.mli` - sandbox-runtime
- `lib/keeper_sandbox_error/keeper_sandbox_error.ml` - sandbox-runtime
- `lib/keeper_sandbox_error/keeper_sandbox_error.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_exec_failure.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_exec_failure.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_factory.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_factory.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_read_backend.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_read_backend.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_read_runner.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_read_runner.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_repo_path.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_repo_path.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_runner.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_runner.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_runtime_classify.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_runtime_classify.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_runtime_setup.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_runtime_setup.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_runtime_setup_mount_failure.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_runtime_setup_mount_failure.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_runtime.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_runtime.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_shell_ir_target.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_shell_ir_target.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox.mli` - sandbox-runtime
- `lib/keeper/keeper_tool_execute_input.ml` - shell-surface
- `lib/keeper/keeper_tool_execute_input.mli` - shell-surface
- `lib/keeper/keeper_tool_execute_runtime.ml` - shell-surface
- `lib/keeper/keeper_tool_execute_runtime.mli` - shell-surface
- `lib/keeper_tool_execute_shell_ir/keeper_tool_execute_shell_ir.ml` - shell-surface
- `lib/keeper_tool_execute_shell_ir/keeper_tool_execute_shell_ir.mli` - shell-surface
- `lib/keeper/keeper_tool_execute_path.ml` - shell-surface
- `lib/keeper/keeper_tool_execute_path.mli` - shell-surface
- `lib/keeper_tool_execute_timeout/keeper_tool_execute_timeout.ml` - shell-surface
- `lib/keeper_tool_execute_timeout/keeper_tool_execute_timeout.mli` - shell-surface
- `lib/keeper/keeper_tool_execute_typed_input.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_execute_typed_input.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_approval_mode.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_approval_mode.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_approval_gate.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_approval_gate.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_approval_policy.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_approval_policy.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_approval_registry.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_approval_registry.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_boundary.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_boundary.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_descriptor.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_descriptor.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_descriptor_contract.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_descriptor_contract.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_descriptor_resolution.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_descriptor_resolution.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_runtime_schemas.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_runtime_schemas.mli` - tool-surface-policy
- `lib/keeper_tool_name/keeper_tool_name.ml` - tool-surface-policy
- `lib/keeper_tool_name/keeper_tool_name.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_diversity.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_diversity.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_emission_hook.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_emission_hook.mli` - tool-surface-policy
- `lib/keeper_outcome_taxonomy/keeper_tool_outcome.ml` - tool-surface-policy
- `lib/keeper_outcome_taxonomy/keeper_tool_outcome.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_keeper_audit.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_keeper_audit.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_policy.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_policy.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_progress_identity.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_progress_identity.mli` - tool-surface-policy
- `lib/keeper_tool_response/keeper_tool_response.ml` - tool-surface-policy
- `lib/keeper_tool_response/keeper_tool_response.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_surface.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_surface.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_surface_ops.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_plan.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_plan.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_plan_request.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_plan_request.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_composition_catalog.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_composition_catalog.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_composition_plan_index.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_composition_plan_index.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_definition_source.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_definition_source.mli` - tool-surface-policy
- `lib/keeper/keeper_tools_agent_core_bundle.ml` - agent-core-tool-bridge
- `lib/keeper/keeper_tools_agent_core_bundle.mli` - agent-core-tool-bridge
- `lib/keeper/keeper_tools_agent_core_handler_exec.ml` - agent-core-tool-bridge
- `lib/keeper/keeper_tools_agent_core_handler_exec.mli` - agent-core-tool-bridge
- `lib/keeper/keeper_tools_agent_core_handler_telemetry.ml` - agent-core-tool-bridge
- `lib/keeper/keeper_tools_agent_core_handler_telemetry.mli` - agent-core-tool-bridge
- `lib/keeper/keeper_tools_agent_core_handler.ml` - agent-core-tool-bridge
- `lib/keeper/keeper_tools_agent_core_handler.mli` - agent-core-tool-bridge
- `lib/keeper/keeper_tools_agent_core.ml` - agent-core-tool-bridge
- `lib/keeper/keeper_tools_agent_core.mli` - agent-core-tool-bridge
- `lib/keeper/keeper_tool_composition_surface.ml` - agent-core-tool-bridge
- `lib/keeper/keeper_tool_composition_surface.mli` - agent-core-tool-bridge
