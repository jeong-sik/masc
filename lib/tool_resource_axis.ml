(** Tool_resource_axis -- single resource-classification point for tool calls. *)

type t =
  | Ungated
  | Shell
  | Github
  | Docker
  | Filesystem_read
  | Filesystem_write
  | Board_write
  | Workspace_write
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
  | Workspace_write -> "workspace_write"
  | Web -> "web"
  | Generic_write -> "generic_write"
;;


let translate_search_files_public_args args =
  match args with
  | `Assoc fields ->
    let out = ref [ "op", `String "rg" ] in
    let is_case_insensitive =
      match List.assoc_opt "-i" fields with
      | Some (`Bool true) -> true
      | _ -> false
    in
    List.iter
      (fun (k, v) ->
         match k with
         | "pattern" ->
           let v' =
             if is_case_insensitive
             then (
               match v with
               | `String s -> `String ("(?i)" ^ s)
               | _ -> v)
             else v
           in
           out := (k, v') :: !out
         | "path" | "glob" | "type" -> out := (k, v) :: !out
         | "op" | "-i" -> ()
         | _ -> out := (k, v) :: !out)
      fields;
    `Assoc (List.rev !out)
  | _ -> args
;;

let translate_public_alias_args ~public args =
  match public with
  | "Grep" -> translate_search_files_public_args args
  | _ -> args
;;

let normalize_call ~tool_name ~arguments =
  let stripped = Tool_name_alias_axis.strip_mcp_masc_prefix tool_name in
  match Tool_name_alias_axis.internal_name_of_public stripped with
  | Some internal -> internal, translate_public_alias_args ~public:stripped arguments
  | None -> stripped, translate_public_alias_args ~public:stripped arguments
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

let typed_execute_stage_class fields =
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

let typed_execute_args_class args =
  let combine left right =
    match left, right with
    | Docker, _ | _, Docker -> Docker
    | Github, _ | _, Github -> Github
    | _ -> Shell
  in
  let rec stages_class = function
    | [] -> Shell
    | `Assoc fields :: rest -> combine (typed_execute_stage_class fields) (stages_class rest)
    | _ :: rest -> stages_class rest
  in
  match args with
  | `Assoc fields ->
    let direct = typed_execute_stage_class fields in
    let pipeline =
      match List.assoc_opt "pipeline" fields with
      | Some (`List stages) -> stages_class stages
      | _ -> Shell
    in
    combine direct pipeline
  | _ -> Shell
;;

type shell_op_classification =
  | Known_shell_op of t
  | Unknown_shell_op of string

let classify_shell_op_value raw =
  match String.lowercase_ascii (String.trim raw) with
  | "git_status" | "git_log" | "git_diff" -> Known_shell_op Filesystem_read
  | "rg" | "find" | "tree" | "cat" | "head" | "tail" | "wc" | "ls" ->
    Known_shell_op Filesystem_read
  | unknown -> Unknown_shell_op unknown
;;

let classify_structured_shell_op args =
  match Safe_ops.json_string_opt "op" args with
  | Some raw ->
    (match classify_shell_op_value raw with
     | Known_shell_op resource_class -> resource_class
     | Unknown_shell_op unknown ->
       Log.Mcp.warn
         "unknown structured workspace op; skipping resource gate for unsupported op=%s"
         unknown;
       Ungated)
  | None -> Ungated
;;

let classify_masc_tool (tool : Tool_name.Masc.t) =
  let open Tool_name.Masc in
  (* PR-S1: domain tool names moved to Task/Board/Goal/Operator submodules.
     Resource classification is NON-uniform across each domain (e.g.
     Board_post is Board_write but Board_list is Ungated), so this match stays
     flat over [Masc.t] with each domain constructor mechanically wrapped —
     bucket groupings are byte-for-byte unchanged from before the partition,
     and the compiler still enforces exhaustiveness over every variant. *)
  match tool with
  | Web_fetch | Web_search -> Web
  | Board Board_post
  | Board Board_cleanup
  | Board Board_comment
  | Board Board_comment_vote
  | Board Board_curation_submit
  | Board Board_delete
  | Board Board_reaction
  | Board Board_sub_board_create
  | Board Board_sub_board_delete
  | Board Board_sub_board_update
  | Board Board_vote -> Board_write
  | Task Add_task
  | Task Batch_add_tasks
  | Task Claim_next
  | Deliver
  | Goal Goal_transition
  | Goal Goal_upsert
  | Goal Goal_verify
  | Heartbeat
  | Note_add
  | Plan_clear_task
  | Plan_init
  | Plan_set_task
  | Plan_update
  | Reset
  | Tool_grant
  | Tool_revoke
  | Task Transition
  | Task Update_priority -> Workspace_write
  | Agent_update
  | Broadcast
  | Cleanup_zombies
  | Gc
  | Operator Operator_action
  | Operator Operator_confirm
  | Tool_admin_update -> Generic_write
  | Agent_card
  | Agent_fitness
  | Agents
  | Approval_get
  | Approval_pending
  | Board Board_curation_read
  | Board Board_get
  | Board Board_hearths
  | Board Board_list
  | Board Board_profile
  | Board Board_search
  | Board Board_stats
  | Board Board_sub_board_get
  | Board Board_sub_board_list
  | Check
  | Config
  | Dashboard
  | Get_metrics
  | Goal Goal_list
  | Mcp_session
  | Messages
  | Operator Operator_digest
  | Operator Operator_snapshot
  | Pause
  | Plan_get
  | Plan_get_task
  | Resume
  | Start
  | Status
  | Task Task_history
  | Task Tasks
  | Tool_admin_snapshot
  | Tool_help
  | Tool_list
  | Tool_stats -> Ungated
;;

let classify_non_catalog_tool ~tool_name =
  match tool_name with
  | "shell_exec" -> Some Shell
  | _ -> None
;;

let classify_normalized ~tool_name ~arguments ~is_read_only =
  match Tool_name.of_string tool_name with
  | Some (Tool_name.Masc tool) -> classify_masc_tool tool
  | None ->
    (match classify_non_catalog_tool ~tool_name with
     | Some resource_class -> resource_class
     | None -> if is_read_only then Ungated else Generic_write)
;;

let classify ~tool_name ~arguments ~is_read_only =
  let tool_name, arguments = normalize_call ~tool_name ~arguments in
  classify_normalized ~tool_name ~arguments ~is_read_only
;;
