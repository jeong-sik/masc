# Keeper Tool Boundary Matrix

Status: P0 ratchet source for keeper agent tool boundaries.
Last updated: 2026-05-25.

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
| `execution-dispatch` | Keeper-side command, board, status, task, persona, memory, and receipt execution dispatch. | Tool name policy, sandbox runtime mechanics, GitHub transport details. |
| `github-runtime` | GitHub environment, repository, runner, and shared GitHub runtime helpers. | Generic keeper execution dispatch or tool policy. |
| `hook-observation` | OAS hook event parsing, metrics, and observational adapters. | OAS tool handler execution or keeper runtime dispatch. |
| `oas-tool-bridge` | Keeper tool bridge for OAS bundle, handler, telemetry, JSON, markers, workflow, and deterministic errors. | Generic tool policy or non-OAS hook observation. |
| `sandbox-runtime` | Sandbox containment, Docker runtime, read/session runners, executor, and shell IR target plumbing. | Tool naming policy or GitHub runtime. |
| `shell-surface` | Shell command parsing, typed bash input, shell ops, path, readonly policy, runtime paths, and timeout semantics. | Sandbox runtime or keeper tool registry/policy. |
| `tool-surface-policy` | Keeper tool aliasing, boundary, disclosure, diversity, emission, registry, policy, resolution, and tool-specific policy records. | OAS bridge implementation, shell parsing, sandbox execution. |

## Coverage Manifest

Each path below must appear exactly once and use one owner from the table above.

- `lib/keeper/agent_tool_board_runtime.ml` - execution-dispatch
- `lib/keeper/agent_tool_board_runtime.mli` - execution-dispatch
- `lib/keeper/agent_tool_filesystem_runtime.ml` - execution-dispatch
- `lib/keeper/agent_tool_filesystem_runtime.mli` - execution-dispatch
- `lib/keeper/agent_tool_ide_runtime.ml` - execution-dispatch
- `lib/keeper/agent_tool_ide_runtime.mli` - execution-dispatch
- `lib/keeper/agent_tool_in_process_runtime.ml` - execution-dispatch
- `lib/keeper/agent_tool_in_process_runtime.mli` - execution-dispatch
- `lib/keeper/agent_tool_memory_runtime.ml` - execution-dispatch
- `lib/keeper/agent_tool_memory_runtime.mli` - execution-dispatch
- `lib/keeper/agent_tool_persona_runtime.ml` - execution-dispatch
- `lib/keeper/agent_tool_persona_runtime.mli` - execution-dispatch
- `lib/keeper/agent_tool_preflight_runtime.ml` - execution-dispatch
- `lib/keeper/agent_tool_preflight_runtime.mli` - execution-dispatch
- `lib/keeper/agent_tool_remote_mcp_runtime.ml` - execution-dispatch
- `lib/keeper/agent_tool_remote_mcp_runtime.mli` - execution-dispatch
- `lib/keeper/agent_tool_shared_runtime.ml` - execution-dispatch
- `lib/keeper/agent_tool_shared_runtime.mli` - execution-dispatch
- `lib/keeper/agent_tool_shell_runtime.ml` - execution-dispatch
- `lib/keeper/agent_tool_shell_runtime.mli` - execution-dispatch
- `lib/keeper/agent_tool_task_runtime.ml` - execution-dispatch
- `lib/keeper/agent_tool_task_runtime.mli` - execution-dispatch
- `lib/keeper/agent_tool_voice_runtime.ml` - execution-dispatch
- `lib/keeper/agent_tool_voice_runtime.mli` - execution-dispatch
- `lib/keeper/agent_tool_dispatch_runtime.ml` - execution-dispatch
- `lib/keeper/agent_tool_dispatch_runtime.mli` - execution-dispatch
- `lib/keeper/keeper_execution_receipt_types.ml` - execution-dispatch
- `lib/keeper/keeper_execution_receipt_types.mli` - execution-dispatch
- `lib/keeper/keeper_execution_receipt_failure_site.ml` - execution-dispatch
- `lib/keeper/keeper_execution_receipt_failure_site.mli` - execution-dispatch
- `lib/keeper/keeper_execution_receipt_outcome_kind.ml` - execution-dispatch
- `lib/keeper/keeper_execution_receipt_outcome_kind.mli` - execution-dispatch
- `lib/keeper/keeper_execution_receipt.ml` - execution-dispatch
- `lib/keeper/keeper_execution_receipt.mli` - execution-dispatch
- `lib/keeper/keeper_execution.ml` - execution-dispatch
- `lib/keeper/keeper_execution.mli` - execution-dispatch
- `lib/keeper/keeper_hooks_oas_cost_events.ml` - hook-observation
- `lib/keeper/keeper_hooks_oas_cost_events.mli` - hook-observation
- `lib/keeper/keeper_hooks_oas_gate_attempt.ml` - hook-observation
- `lib/keeper/keeper_hooks_oas_gate_attempt.mli` - hook-observation
- `lib/keeper/keeper_hooks_oas_idle.ml` - hook-observation
- `lib/keeper/keeper_hooks_oas_idle.mli` - hook-observation
- `lib/keeper/keeper_hooks_oas_introspection.ml` - hook-observation
- `lib/keeper/keeper_hooks_oas_introspection.mli` - hook-observation
- `lib/keeper/keeper_hooks_oas_output_json.ml` - hook-observation
- `lib/keeper/keeper_hooks_oas_output_json.mli` - hook-observation
- `lib/keeper/keeper_hooks_oas_pr_metrics.ml` - hook-observation
- `lib/keeper/keeper_hooks_oas_pr_metrics.mli` - hook-observation
- `lib/keeper/keeper_hooks_oas_response_metrics.ml` - hook-observation
- `lib/keeper/keeper_hooks_oas_response_metrics.mli` - hook-observation
- `lib/keeper/keeper_hooks_oas_types.ml` - hook-observation
- `lib/keeper/keeper_hooks_oas_types.mli` - hook-observation
- `lib/keeper/keeper_hooks_oas.ml` - hook-observation
- `lib/keeper/keeper_hooks_oas.mli` - hook-observation
- `lib/keeper/keeper_sandbox_containment.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_containment.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_control.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_control.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_docker_container_name.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_docker_container_name.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_docker_nested_runtime.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_docker_nested_runtime.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_docker_semantic.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_docker_semantic.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_docker.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_docker.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_exec_failure.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_exec_failure.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_executor.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_executor.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_factory.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_factory.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_oneshot_plan.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_oneshot_plan.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_read_backend.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_read_backend.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_read_runner.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_read_runner.mli` - sandbox-runtime
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
- `lib/keeper/keeper_sandbox_session_executor.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_session_executor.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_session_plan.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_session_plan.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox_shell_ir_target.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox_shell_ir_target.mli` - sandbox-runtime
- `lib/keeper/keeper_sandbox.ml` - sandbox-runtime
- `lib/keeper/keeper_sandbox.mli` - sandbox-runtime
- `lib/keeper/keeper_shell_bash_typed_input.ml` - shell-surface
- `lib/keeper/keeper_shell_bash_typed_input.mli` - shell-surface
- `lib/keeper/keeper_shell_bash.ml` - shell-surface
- `lib/keeper/keeper_shell_bash.mli` - shell-surface
- `lib/keeper/keeper_shell_command_parse.ml` - shell-surface
- `lib/keeper/keeper_shell_command_parse.mli` - shell-surface
- `lib/keeper/keeper_shell_command_semantics.ml` - shell-surface
- `lib/keeper/keeper_shell_command_semantics.mli` - shell-surface
- `lib/keeper/keeper_shell_command_words.ml` - shell-surface
- `lib/keeper/keeper_shell_command_words.mli` - shell-surface
- `lib/keeper/keeper_shell_ir.ml` - shell-surface
- `lib/keeper/keeper_shell_ir.mli` - shell-surface
- `lib/keeper/keeper_shell_path.ml` - shell-surface
- `lib/keeper/keeper_shell_path.mli` - shell-surface
- `lib/keeper/keeper_shell_readonly_policy.ml` - shell-surface
- `lib/keeper/keeper_shell_readonly_policy.mli` - shell-surface
- `lib/keeper/keeper_shell_runtime_paths.ml` - shell-surface
- `lib/keeper/keeper_shell_runtime_paths.mli` - shell-surface
- `lib/keeper/keeper_shell_timeout.ml` - shell-surface
- `lib/keeper/keeper_shell_timeout.mli` - shell-surface
- `lib/keeper/keeper_tool_affinity.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_affinity.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_alias.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_alias.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_bash_input.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_bash_input.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_boundary.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_boundary.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_capability_axis.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_capability_axis.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_deterministic_error.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_deterministic_error.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_completion_contract.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_completion_contract.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_query.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_query.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_selection.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_selection.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_diversity.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_diversity.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_emission_hook.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_emission_hook.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_guidance.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_guidance.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_name_projection.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_name_projection.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_observation.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_observation.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_outcome.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_outcome.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_policy_config.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_policy_config.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_policy_failure_site.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_policy_failure_site.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_policy.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_policy.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_progress.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_progress.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_registry.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_registry.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_response.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_response.mli` - tool-surface-policy
- `lib/keeper/keeper_tool_resolution.ml` - tool-surface-policy
- `lib/keeper/keeper_tool_resolution.mli` - tool-surface-policy
- `lib/keeper/keeper_tools_oas_bundle.ml` - oas-tool-bridge
- `lib/keeper/keeper_tools_oas_bundle.mli` - oas-tool-bridge
- `lib/keeper/keeper_tools_oas_deterministic_error.ml` - oas-tool-bridge
- `lib/keeper/keeper_tools_oas_deterministic_error.mli` - oas-tool-bridge
- `lib/keeper/keeper_tools_oas_failure_boundary.ml` - oas-tool-bridge
- `lib/keeper/keeper_tools_oas_failure_boundary.mli` - oas-tool-bridge
- `lib/keeper/keeper_tools_oas_handler_exec.ml` - oas-tool-bridge
- `lib/keeper/keeper_tools_oas_handler_exec.mli` - oas-tool-bridge
- `lib/keeper/keeper_tools_oas_handler_telemetry.ml` - oas-tool-bridge
- `lib/keeper/keeper_tools_oas_handler_telemetry.mli` - oas-tool-bridge
- `lib/keeper/keeper_tools_oas_handler.ml` - oas-tool-bridge
- `lib/keeper/keeper_tools_oas_handler.mli` - oas-tool-bridge
- `lib/keeper/keeper_tools_oas_json.ml` - oas-tool-bridge
- `lib/keeper/keeper_tools_oas_json.mli` - oas-tool-bridge
- `lib/keeper/keeper_tools_oas_markers.ml` - oas-tool-bridge
- `lib/keeper/keeper_tools_oas_markers.mli` - oas-tool-bridge
- `lib/keeper/keeper_tools_oas_workflow.ml` - oas-tool-bridge
- `lib/keeper/keeper_tools_oas_workflow.mli` - oas-tool-bridge
- `lib/keeper/keeper_tools_oas.ml` - oas-tool-bridge
- `lib/keeper/keeper_tools_oas.mli` - oas-tool-bridge
