# `Sys.getcwd ()` Audit — MASC `lib/`

> Plan reference: `docs/superpowers/plans/2026-06-26-path-env-ssot-hardening-plan.md` (Task 2)

## Summary

- **Total occurrences:** 36
- **Files affected:** 23
- **Fallback-to-fix:** 14 occurrences
- **Legitimate:** 22 occurrences

Fallback uses anchor relative paths or default base paths to the process current working directory instead of an explicitly threaded `base_path`. These are **deferred to Phase 4** so the current PR stays focused and reviewable.

## Audit Table

| File | Line | Snippet | Category |
|------|------|---------|----------|
| `lib/mcp_tool_runtime_workspace.ml` | 91 | `Filename.concat (Sys.getcwd ()) path` | fallback-to-fix |
| `lib/voice_config/voice_config.ml` | 75 | `let cwd = Sys.getcwd () in` | legitimate |
| `lib/voice_config/voice_config.ml` | 86 | <code>&#124; None -> Sys.getcwd ()</code> | fallback-to-fix |
| `lib/config_dir_resolver/config_dir_resolver.ml` | 145 | `try Sys.getcwd () with` | fallback-to-fix |
| `lib/workspace/workspace_utils_backend_setup.ml` | 96 | `else if Filename.is_relative trimmed then Filename.concat (Sys.getcwd ()) trimmed` | fallback-to-fix |
| `lib/keeper_voice_local.ml` | 14 | `| None -> Workspace_utils_backend_setup.find_git_root (Sys.getcwd ())` | legitimate |
| `lib/tool_contract_prompts/tool_contract_guidance.ml` | 64 | `let cwd_candidate = find_seed_prompt_from (Sys.getcwd ()) key 0 in` | fallback-to-fix |
| `lib/repo_manager/repo_store.ml` | 372 | `have to canonicalize because [Filename.concat (Sys.getcwd ())` (comment) | legitimate |
| `lib/voice_bridge_core/voice_bridge_core.ml` | 470 | `| None -> find_git_root_from (Sys.getcwd ())` | legitimate |
| `lib/exec_policy/exec_policy_paths.ml` | 6 | `Filename.concat (Option.value ~default:(Sys.getcwd ()) base_dir) path` | fallback-to-fix |
| `lib/exec_policy/exec_policy_paths.ml` | 126 | <code>&#124;&#124; is_within_dir ~dir:(resolve_path (Sys.getcwd ())) resolved</code> | legitimate |
| `lib/build_identity.ml` | 37 | `let argv0 = if Array.length Sys.argv > 0 then Sys.argv.(0) else Sys.getcwd () in` | legitimate |
| `lib/build_identity.ml` | 39 | `if Filename.is_relative argv0 then Filename.concat (Sys.getcwd ()) argv0 else argv0` | legitimate |
| `lib/build_identity.ml` | 125 | `pick_repo_candidates ~exe_dir:(executable_dir ()) ~cwd:(Sys.getcwd ())` | legitimate |
| `lib/build_identity.ml` | 133 | `pick_repo_candidates ~exe_dir:(executable_dir ()) ~cwd:(Sys.getcwd ())` | legitimate |
| `lib/build_identity.ml` | 211 | `pick_repo_candidates ~exe_dir:(executable_dir ()) ~cwd:(Sys.getcwd ())` | legitimate |
| `lib/server/server_dashboard_http_perf.ml` | 75 | `let cwd = Sys.getcwd () in` | legitimate |
| `lib/server/server_routes_http_sidecar_paths.ml` | 27 | <code>&#124; _ -> Sys.getcwd ())</code> | fallback-to-fix |
| `lib/server/server_runtime_bootstrap.ml` | 79 | `(try Sys.getcwd () with` | fallback-to-fix |
| `lib/keeper/keeper_sandbox_control.ml` | 229 | `~cwd:(Sys.getcwd ())` | legitimate |
| `lib/keeper/keeper_sandbox_runtime_setup.ml` | 54 | `~cwd:(Sys.getcwd ())` | legitimate |
| `lib/keeper/keeper_sandbox_runtime_setup.ml` | 204 | `then Filename.concat (Sys.getcwd ()) base_path` | fallback-to-fix |
| `lib/keeper/keeper_turn_sandbox_runtime.ml` | 227 | `~cwd:(Sys.getcwd ())` | legitimate |
| `lib/keeper/keeper_turn_sandbox_runtime.ml` | 557 | `let cwd = Sys.getcwd () in` | legitimate |
| `lib/keeper/keeper_turn_sandbox_runtime.ml` | 600 | `~cwd:(Sys.getcwd ())` | legitimate |
| `lib/keeper/keeper_turn_sandbox_runtime.ml` | 628 | `let cwd = Sys.getcwd () in` | legitimate |
| `lib/keeper/keeper_turn_sandbox_runtime.ml` | 1061 | `cwd = Some (Sys.getcwd ()) })` | legitimate |
| `lib/keeper/keeper_sandbox_docker.ml` | 201 | `~cwd:(Sys.getcwd ())` | legitimate |
| `lib/keeper/keeper_sandbox_docker.ml` | 590 | `~cwd:(Sys.getcwd ())` | legitimate |
| `lib/keeper/keeper_sandbox_read_backend.ml` | 189 | `~cwd:(Sys.getcwd ())` | legitimate |
| `lib/dated_jsonl/dated_jsonl.ml` | 41 | `Filename.concat (Sys.getcwd ()) base_dir` | fallback-to-fix |
| `lib/jsonl_atomic/jsonl_atomic.ml` | 27 | `then Filename.concat (Sys.getcwd ()) path` | fallback-to-fix |
| `lib/mcp_tool_runtime_workspace.mli` | 32 | `against [Sys.getcwd ()].  Absolute paths are used verbatim.` (doc) | legitimate |
| `lib/web_dashboard.ml` | 31 | `Some (Filename.concat (Sys.getcwd ()) "assets");` | fallback-to-fix |
| `lib/web_dashboard.ml` | 43 | <code>&#124; [] -> Filename.concat (Sys.getcwd ()) "assets")</code> | fallback-to-fix |
| `lib/eval_calibration.ml` | 161 | `Filename.concat (match cwd with Some d -> d | None -> Sys.getcwd ()) raw` | fallback-to-fix |

## Category Notes

- **fallback-to-fix:** The call uses `Sys.getcwd ()` as an implicit base directory when a path is relative or when no explicit `base_path`/`cwd` is supplied. These should eventually thread an explicit `base_path` instead.
- **legitimate:** The call is for diagnostics/logging, executable-path resolution, git-root discovery, subprocess working-directory setup, or interface/comments describing intended behavior.

## Deferral Note

The **fallback-to-fix** call sites are intentionally not refactored in this PR. They are tracked for Phase 4 path-hardening work in <https://github.com/jeong-sik/masc/issues/22444> so the current changeset remains small and reviewable.
