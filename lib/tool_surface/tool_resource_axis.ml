(** Tool_resource_axis -- single resource-classification point for tool calls. *)

type t =
  | Ungated
  | Shell
  | Github
  | Docker
  | Filesystem_read
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
  | "Grep" | "Search" -> translate_search_files_public_args args
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

let classify_non_catalog_tool ~tool_name =
  match tool_name with
  | "shell_exec" -> Some Shell
  | _ -> None
;;

let classify_catalog_metadata_tool ~tool_name =
  let meta = Tool_catalog.metadata tool_name in
  match meta.readonly, meta.destructive, meta.requires_actor_binding, meta.effect_domain with
  | Some true, _, _, _ -> Some Ungated
  | _, Some true, _, _ -> Some Generic_write
  | _, _, Some true, _ -> Some Generic_write
  | _, _, _, Some Tool_catalog.Read_only -> Some Ungated
  | _, _, _, Some Tool_catalog.Masc_workspace -> Some Workspace_write
  | _, _, _, Some Tool_catalog.Playground_write
  | _, _, _, Some Tool_catalog.Host_repo_write -> Some Workspace_write
  | _ -> None
;;

let classify_board_tool_name ~tool_name =
  match Tool_name.Board_name.of_string tool_name with
  | Some board_name ->
    Some
      (if Tool_name.Board_name.is_resource_write board_name then Board_write else Ungated)
  | None -> None
;;

let classify_catalog_tool ~tool_name =
  match classify_board_tool_name ~tool_name with
  | Some resource_class -> Some resource_class
  | None ->
    (match tool_name with
     | "masc_web_fetch" | "masc_web_search" -> Some Web
     | "masc_add_task"
     | "masc_batch_add_tasks"
     | "masc_deliver"
     | "masc_goal_transition"
     | "masc_goal_upsert"
     | "masc_goal_verify"
     | "masc_heartbeat"
     | "masc_note_add"
     | "masc_plan_clear_task"
     | "masc_plan_init"
     | "masc_plan_set_task"
     | "masc_plan_update"
     | "masc_reset"
     | "masc_tool_grant"
     | "masc_tool_revoke"
     | "masc_transition"
     | "masc_update_priority" -> Some Workspace_write
     | "masc_broadcast"
     | "masc_cleanup_zombies"
     | "masc_gc" -> Some Generic_write
     | "masc_check"
     | "masc_config"
     | "masc_dashboard"
     | "masc_get_metrics"
     | "masc_goal_list"
     | "masc_messages"
     | "masc_operator_digest"
     | "masc_operator_snapshot"
     | "masc_pause"
     | "masc_plan_get"
     | "masc_plan_get_task"
     | "masc_resume"
     | "masc_session"
     | "masc_start"
     | "masc_status"
     | "masc_task_history"
     | "masc_tasks"
     | "masc_tool_list"
     | "masc_tool_stats" -> Some Ungated
     | _ -> None)
;;

let classify_descriptor_tool ~tool_name ~arguments =
  match tool_name with
  | "tool_execute" -> Some (typed_execute_args_class arguments)
  | "tool_search_files" -> Some (classify_structured_shell_op arguments)
  | "tool_read_file" -> Some Filesystem_read
  | "tool_write_file" | "tool_edit_file" -> Some Workspace_write
  | "shell_exec" -> Some Shell
  | _ -> None
;;

let classify_normalized ~tool_name ~arguments ~is_read_only =
  match classify_descriptor_tool ~tool_name ~arguments with
  | Some resource_class -> resource_class
  | None ->
    (match classify_catalog_tool ~tool_name with
     | Some resource_class -> resource_class
     | None ->
       (match classify_non_catalog_tool ~tool_name with
        | Some resource_class -> resource_class
        | None ->
          (match classify_catalog_metadata_tool ~tool_name with
           | Some resource_class -> resource_class
           | None -> if is_read_only then Ungated else Generic_write)))
;;

let classify ~tool_name ~arguments ~is_read_only =
  let tool_name, arguments = normalize_call ~tool_name ~arguments in
  classify_normalized ~tool_name ~arguments ~is_read_only
;;
