(** Keeper_tool_capability_axis -- semantic capability classification for tool names.

    Callers may pass public aliases ([Bash], [Write], ...), public MCP names,
    prefixed MCP names, or internal handler names. This module normalizes names
    through the alias SSOT before answering capability predicates. *)

type t =
  | Claim_task
  | Board_activity
  | Work_discovery
  | Pr_work_action
  | Pr_work_shell_command
  | Pr_work_git_action
  | Docker_route_pr_work_action

let keeper_name (tool : Tool_name.Keeper.t) =
  Tool_name.to_string (Tool_name.Keeper tool)
;;

let masc_name (tool : Tool_name.Masc.t) =
  Tool_name.to_string (Tool_name.Masc tool)
;;

let masc_keeper_name (tool : Tool_name.Masc_keeper.t) =
  Tool_name.to_string (Tool_name.Masc_keeper tool)
;;

let canonical_tool_name name =
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix name in
  match Keeper_tool_alias.canonical_resolution name with
  | Keeper_tool_alias.Public_mcp { internal; _ }
  | Keeper_tool_alias.Public_alias { internal } -> internal
  | Keeper_tool_alias.Internal { canonical } -> canonical
  | Keeper_tool_alias.Unknown -> stripped
;;

let candidate_names name =
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix name in
  let canonical = canonical_tool_name name in
  if String.equal stripped canonical then [ canonical ] else [ canonical; stripped ]
;;

let claim_task_tool_names =
  [ keeper_name Tool_name.Keeper.Task_claim; masc_name Tool_name.Masc.Claim_next ]
;;

let board_activity_tool_names =
  [ keeper_name Tool_name.Keeper.Board_post
  ; keeper_name Tool_name.Keeper.Board_comment
  ; masc_name Tool_name.Masc.Broadcast
  ; masc_keeper_name Tool_name.Masc_keeper.Msg
  ]
;;

let work_discovery_tool_names =
  [ keeper_name Tool_name.Keeper.Board_post
  ; keeper_name Tool_name.Keeper.Board_comment
  ; keeper_name Tool_name.Keeper.Task_create
  ; masc_name Tool_name.Masc.Add_task
  ; keeper_name Tool_name.Keeper.Tasks_audit
  ; keeper_name Tool_name.Keeper.Board_cleanup
  ; keeper_name Tool_name.Keeper.Shell
  ; keeper_name Tool_name.Keeper.Bash
  ; masc_name Tool_name.Masc.Code_shell
  ; keeper_name Tool_name.Keeper.Fs_edit
  ; masc_name Tool_name.Masc.Code_edit
  ; "MultiEdit"
  ; keeper_name Tool_name.Keeper.Task_submit_for_verification
  ; keeper_name Tool_name.Keeper.Task_done
  ]
;;

let work_discovery_routing_tool_names =
  [ keeper_name Tool_name.Keeper.Task_claim
  ; masc_name Tool_name.Masc.Claim_next
  ; keeper_name Tool_name.Keeper.Board_post
  ; keeper_name Tool_name.Keeper.Task_create
  ; masc_name Tool_name.Masc.Add_task
  ; keeper_name Tool_name.Keeper.Tasks_audit
  ; keeper_name Tool_name.Keeper.Board_cleanup
  ]
;;

let preferred_work_discovery_tool_names =
  [ keeper_name Tool_name.Keeper.Task_claim
  ; keeper_name Tool_name.Keeper.Task_create
  ; masc_name Tool_name.Masc.Add_task
  ; keeper_name Tool_name.Keeper.Board_comment
  ; keeper_name Tool_name.Keeper.Board_post
  ]
;;

let inspect_worktree_delta_tool_names =
  [ keeper_name Tool_name.Keeper.Shell
  ; keeper_name Tool_name.Keeper.Bash
  ; masc_name Tool_name.Masc.Code_shell
  ; keeper_name Tool_name.Keeper.Fs_edit
  ]
;;

let preferred_inspect_worktree_delta_tool_names =
  [ keeper_name Tool_name.Keeper.Shell; keeper_name Tool_name.Keeper.Bash ]
;;

let pr_work_shell_command_tool_names =
  [ keeper_name Tool_name.Keeper.Bash; masc_name Tool_name.Masc.Code_shell ]
;;

let pr_work_git_action_tool_names =
  [ masc_name Tool_name.Masc.Code_git ]
;;

let tool_names = function
  | Claim_task -> claim_task_tool_names
  | Board_activity -> board_activity_tool_names
  | Work_discovery -> work_discovery_tool_names
  | Pr_work_shell_command -> pr_work_shell_command_tool_names
  | Pr_work_git_action -> pr_work_git_action_tool_names
  | Pr_work_action | Docker_route_pr_work_action ->
    pr_work_git_action_tool_names @ pr_work_shell_command_tool_names
;;

let supports capability name =
  let supported = tool_names capability in
  candidate_names name |> List.exists (fun candidate -> List.mem candidate supported)
;;

let supports_any capability names =
  List.exists (supports capability) names
;;

let shell_command_input_field tool_name =
  if supports Pr_work_shell_command tool_name
  then
    match canonical_tool_name tool_name with
    | "keeper_bash" -> Some "cmd"
    | "masc_code_shell" -> Some "command"
    | _ -> None
  else None
;;
