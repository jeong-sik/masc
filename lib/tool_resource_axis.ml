(** Tool_resource_axis -- single resource-classification point for tool calls. *)

type t =
  | Ungated
  | Shell
  | Github
  | Docker
  | Filesystem_read
  | Filesystem_write
  | Board_write
  | Coordination_write
  | Web
  | Generic_write

let to_string = function
  | Ungated -> "ungated"
  | Shell -> "shell"
  | Github -> "github"
  | Docker -> "docker"
  | Filesystem_read -> "filesystem_read"
  | Filesystem_write -> "filesystem_write"
  | Board_write -> "board_write"
  | Coordination_write -> "coordination_write"
  | Web -> "web"
  | Generic_write -> "generic_write"
;;

let json_string_opt key json = Safe_ops.json_string_opt key json

let normalize_call ~tool_name ~arguments =
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix tool_name in
  match Keeper_tool_alias.canonical_resolution tool_name with
  | Keeper_tool_alias.Public_mcp { internal; _ } -> internal, arguments
  | Keeper_tool_alias.Public_alias { internal } ->
    internal, Keeper_tool_alias.translate_input ~public:stripped arguments
  | Keeper_tool_alias.Internal { canonical } -> canonical, arguments
  | Keeper_tool_alias.Unknown -> stripped, arguments
;;

let json_string_list_opt key fields =
  match List.assoc_opt key fields with
  | Some (`List values) ->
    Some
      (List.filter_map
         (function
           | `String value -> Some value
           | _ -> None)
         values)
  | _ -> None
;;

let git_network_subcommand = function
  | subcommand :: _ ->
    List.mem
      (String.lowercase_ascii subcommand)
      [ "clone"; "fetch"; "pull"; "push" ]
  | [] -> false
;;

let executable_lane executable argv =
  let executable = String.trim executable in
  let basename = Filename.basename executable |> String.lowercase_ascii in
  if String.equal basename "docker-compose"
  then Docker
  else (
    match Masc_exec.Exec_program.of_string executable with
    | Error (`Unknown _) -> Shell
    | Ok bin ->
      (match Masc_exec.Exec_program.known bin with
       | Some Masc_exec.Exec_program.Docker -> Docker
       | Some Masc_exec.Exec_program.Gh | Some Masc_exec.Exec_program.Glab -> Github
       | Some Masc_exec.Exec_program.Git when git_network_subcommand argv -> Github
       | _ -> Shell))
;;

let typed_bash_stage_class fields =
  match List.assoc_opt "executable" fields with
  | Some (`String executable) ->
    let argv =
      match json_string_list_opt "argv" fields with
      | Some values -> values
      | None -> []
    in
    executable_lane executable argv
  | _ -> Shell
;;

let typed_bash_args_class args =
  let combine left right =
    match left, right with
    | Docker, _ | _, Docker -> Docker
    | Github, _ | _, Github -> Github
    | _ -> Shell
  in
  let rec stages_class = function
    | [] -> Shell
    | `Assoc fields :: rest -> combine (typed_bash_stage_class fields) (stages_class rest)
    | _ :: rest -> stages_class rest
  in
  match args with
  | `Assoc fields ->
    let direct = typed_bash_stage_class fields in
    let pipeline =
      match List.assoc_opt "pipeline" fields with
      | Some (`List stages) -> stages_class stages
      | _ -> Shell
    in
    combine direct pipeline
  | _ -> Shell
;;

type keeper_shell_op_classification =
  | Known_shell_op of t
  | Unknown_shell_op of string

let classify_keeper_shell_op_value raw =
  match String.lowercase_ascii (String.trim raw) with
  | "git_worktree" -> Known_shell_op Filesystem_write
  | "git_status" | "git_log" | "git_diff" -> Known_shell_op Filesystem_read
  | "rg" | "find" | "tree" | "cat" | "head" | "tail" | "wc" | "ls" ->
    Known_shell_op Filesystem_read
  | "bash" | "exec" | "shell" | "sh" -> Known_shell_op Shell
  | unknown -> Unknown_shell_op unknown
;;

let classify_keeper_shell_op args =
  match json_string_opt "op" args with
  | Some raw ->
    (match classify_keeper_shell_op_value raw with
     | Known_shell_op resource_class -> resource_class
     | Unknown_shell_op unknown ->
       Log.Mcp.warn
         "unknown keeper_shell op; defaulting resource gate to shell: op=%s"
         unknown;
       Shell)
  | None -> Shell
;;

let classify_keeper_tool (tool : Tool_name.Keeper.t) args =
  let open Tool_name.Keeper in
  match tool with
  | Tool_name.Keeper.Execute -> typed_bash_args_class args
  | Shell -> classify_keeper_shell_op args
  | Pr_list | Pr_review_comment | Pr_review_read | Pr_review_reply | Pr_status ->
    Github
  | Preflight_check -> Shell
  | Fs_edit -> Filesystem_write
  | Fs_read | Code_read | Tool_search -> Filesystem_read
  | Memory_write | Handoff -> Filesystem_write
  | Memory_search | Library_read | Library_search -> Filesystem_read
  | Board_post
  | Board_comment
  | Board_comment_vote
  | Board_curation_submit
  | Board_delete
  | Board_cleanup
  | Board_sub_board_create
  | Board_sub_board_delete
  | Board_sub_board_update
  | Board_vote -> Board_write
  | Task_claim
  | Task_create
  | Task_done
  | Task_submit_for_verification
  | Task_force_done
  | Task_force_release -> Coordination_write
  | Broadcast | Voice_agent | Voice_listen | Voice_session_start | Voice_speak -> Generic_write
  | Board_curation_read
  | Board_get
  | Board_list
  | Board_search
  | Board_stats
  | Board_sub_board_get
  | Board_sub_board_list
  | Context_status
  | Discovery
  | Ide_annotate
  | Stay_silent
  | Tasks_audit
  | Tasks_list
  | Time_now
  | Tools_list
  | Voice_session_end
  | Voice_sessions -> Ungated
;;

let classify_masc_tool (tool : Tool_name.Masc.t) =
  let open Tool_name.Masc in
  match tool with
  | Tool_name.Masc.Code_shell -> Shell
  | Code_git | Worktree_create | Worktree_remove -> Github
  | Code_delete | Code_edit | Code_write -> Filesystem_write
  | Code_read | Code_search | Code_symbols | Worktree_list -> Filesystem_read
  | Web_fetch | Web_search -> Web
  | Board_post
  | Board_comment
  | Board_comment_vote
  | Board_curation_submit
  | Board_delete
  | Board_cleanup
  | Board_reaction
  | Board_sub_board_create
  | Board_sub_board_delete
  | Board_sub_board_update
  | Board_vote -> Board_write
  | Add_task
  | Batch_add_tasks
  | Claim_next
  | Deliver
  | Goal_transition
  | Goal_upsert
  | Goal_verify
  | Heartbeat
  | Join
  | Leave
  | Note_add
  | Plan_clear_task
  | Plan_init
  | Plan_set_task
  | Plan_update
  | Reset
  | Tool_grant
  | Tool_revoke
  | Transition
  | Update_priority -> Coordination_write
  | Agent_update
  | Broadcast
  | Cleanup_zombies
  | Gc
  | Operator_action
  | Operator_confirm
  | Tool_admin_update -> Generic_write
  | Agent_card
  | Agent_fitness
  | Agents
  | Approval_get
  | Approval_pending
  | Board_curation_read
  | Board_get
  | Board_hearths
  | Board_list
  | Board_profile
  | Board_search
  | Board_stats
  | Board_sub_board_get
  | Board_sub_board_list
  | Check
  | Config
  | Coordination_fsm_snapshot
  | Dashboard
  | Get_metrics
  | Goal_list
  | Mcp_session
  | Messages
  | Operator_digest
  | Operator_snapshot
  | Pause
  | Plan_get
  | Plan_get_task
  | Resume
  | Spawn
  | Start
  | Status
  | Task_history
  | Tasks
  | Tool_admin_snapshot
  | Tool_help
  | Tool_list
  | Tool_stats
  | Who
  | Workflow_guide -> Ungated
;;

let classify_masc_keeper_tool (tool : Tool_name.Masc_keeper.t) =
  let open Tool_name.Masc_keeper in
  match tool with
  | Tool_name.Masc_keeper.Sandbox_start
  | Sandbox_stop
  | Sandbox_status -> Docker
  | Clear | Compact | Create_from_persona | Down | Msg | Repair | Reset | Up ->
    Coordination_write
  | List | Msg_result | Persona_audit | Status -> Ungated
;;

let classify_non_catalog_tool ~tool_name =
  match tool_name with
  | "dashboard_worktree_status.gh_pr_list" -> Some Github
  | "shell_exec" -> Some Shell
  | _ -> None
;;

let classify_normalized ~tool_name ~arguments ~is_read_only =
  match Tool_name.of_string tool_name with
  | Some (Tool_name.Keeper tool) -> classify_keeper_tool tool arguments
  | Some (Tool_name.Masc tool) -> classify_masc_tool tool
  | Some (Tool_name.Masc_keeper tool) -> classify_masc_keeper_tool tool
  | None ->
    (match classify_non_catalog_tool ~tool_name with
     | Some resource_class -> resource_class
     | None -> if is_read_only then Ungated else Generic_write)
;;

let classify ~tool_name ~arguments ~is_read_only =
  let tool_name, arguments = normalize_call ~tool_name ~arguments in
  classify_normalized ~tool_name ~arguments ~is_read_only
;;
