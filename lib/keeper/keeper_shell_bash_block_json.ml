open Keeper_shell_bash_shape_messages
open Keeper_shell_bash_task_state

let workflow_rejection_field = "failure_class", `String "workflow_rejection"

let bash_shape_block_result ~cmd ~cmd_for_log ~env_snapshot block =
  Yojson.Safe.to_string
    (Exec_core.blocked_result_json
       ~cmd
       ~error:"keeper_bash_command_shape_blocked"
       ~reason:(bash_shape_block_reason block)
       ~hint:(bash_shape_block_hint ~cmd block)
       ~alternatives:(bash_shape_block_alternatives ~cmd block)
       ~diag:
         (Some
            {
              Exec_core.rule_id =
                "keeper_bash_" ^ bash_shape_block_tag block ^ "_blocked";
              explanation = bash_shape_block_reason block;
              rewrite = Some (bash_shape_block_hint ~cmd block);
              tool_suggestion =
                (match block with
                 | Gh_pr_checks -> Some "keeper_pr_status"
                 | _ when command_looks_like_task_state_discovery cmd ->
                   Some "keeper_tasks_list"
                 | Pipe_or_redirect -> Some "keeper_shell"
                 | Repo_wide_scan -> Some "keeper_shell"
                 | Chaining | Substitution -> None);
            })
       ~extra:
         [
           workflow_rejection_field;
           "cmd", `String cmd_for_log;
           "shape_block", `String (bash_shape_block_tag block);
           "execution_time_ms", `Int 0;
         ]
       ~env_snapshot
       ())

let task_state_http_probe_block ~cmd ~cmd_for_log () =
  Yojson.Safe.to_string
    (Exec_core.blocked_result_json
       ~cmd
       ~error:"task_state_http_probe_blocked"
       ~reason:
         "Task state is not exposed through guessed localhost HTTP APIs from \
          keeper_bash."
       ~hint:task_state_shell_hint
       ~alternatives:task_state_shell_alternatives
       ~retryability:Exec_core.Self_correct
       ~diag:
         (Some
            { Exec_core.rule_id = "task_state_http_probe_blocked"
            ; explanation =
                "Keepers must use task-state tools instead of probing \
                 localhost task APIs from shell."
            ; rewrite = Some task_state_shell_hint
            ; tool_suggestion = Some "keeper_tasks_list"
            })
       ~extra:[ "cmd", `String cmd_for_log; "execution_time_ms", `Int 0 ]
       ())

let task_state_file_probe_block ~cmd ~cmd_for_log () =
  Yojson.Safe.to_string
    (Exec_core.blocked_result_json
       ~cmd
       ~error:"task_state_file_probe_blocked"
       ~reason:
         "Task state is owned by the MASC task tools, not by guessed \
          backlog/current-task files in keeper sandboxes."
       ~hint:task_state_shell_hint
       ~alternatives:task_state_shell_alternatives
       ~retryability:Exec_core.Self_correct
       ~diag:
         (Some
            { Exec_core.rule_id = "task_state_file_probe_blocked"
            ; explanation =
                "Keepers must use task-state tools instead of cat/find/rg \
                 against .masc backlog files or worktree .task.json files."
            ; rewrite = Some task_state_shell_hint
            ; tool_suggestion = Some "keeper_tasks_list"
            })
       ~extra:[ "cmd", `String cmd_for_log; "execution_time_ms", `Int 0 ]
       ())
