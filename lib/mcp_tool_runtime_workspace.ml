(** Mcp_tool_runtime_workspace — project startup tool handler.

    Handles: masc_start.

    Extracted from mcp_tool_runtime.ml to keep the runtime router small. *)

module Planning_eio = Task.Planning_eio

open Mcp_tool_runtime_types

(* RFC-0189 PR-2: lifecycle handlers return [Tool_result.result option]
   directly, matching the shared MCP runtime alias. *)

let runtime_ok ~tool_name ~start_time body : Tool_result.result =
  Tool_result.ok ~tool_name ~start_time body
;;

let runtime_err_runtime ~tool_name ~start_time msg : Tool_result.result =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Runtime_failure
    ~start_time
    msg
;;

let runtime_err_workflow ~tool_name ~start_time msg : Tool_result.result =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    msg
;;

let masc_add_task_name =
  Tool_name.Task_name.to_string Tool_name.Task_name.Add_task

(** Argument extraction helpers bound to ctx.arguments. *)
let arg_get_string ctx key default =
  Safe_ops.json_string ~default key ctx.arguments

let expand_start_path_home ~path_syntax ~suffix =
  match Config_dir_resolver.initial_env_home with
  | Some home ->
    Ok (if String.equal suffix "" then home else Filename.concat home suffix)
  | None ->
    Error (Printf.sprintf "HOME is required to expand '%s' in masc_start path" path_syntax)
;;

let expand_start_path ~config path =
  if String.length path >= 2 && Char.equal path.[0] '~' && Char.equal path.[1] '/'
  then
    expand_start_path_home
      ~path_syntax:"~/"
      ~suffix:(String.sub path 2 (String.length path - 2))
  else if String.length path = 1 && Char.equal path.[0] '~'
  then expand_start_path_home ~path_syntax:"~" ~suffix:""
  else if Filename.is_relative path
  then (
    (* Initialized sessions keep the active workspace as the relative-path
       anchor. Only bootstrap calls without a workspace fall back to the
       resolver/cwd bootstrap policy. *)
    let anchor =
      if Workspace.is_initialized config
      then config.base_path
      else Config_dir_resolver.base_path_or_cwd ()
    in
    Ok (Filename.concat anchor path))
  else Ok path
;;

type workspace_setup_error =
  | Workspace_request_rejected of string
  | Workspace_runtime_failed of Mcp_server.workspace_switch_error

let activate_workspace state config =
  match Mcp_server.set_workspace_config state config with
  | Ok () -> Ok config
  | Error error -> Error (Workspace_runtime_failed error)
;;

(** masc_start — compound onboarding (set project root + bind session + optional task) *)
let handle_start ~tool_name ~start_time (ctx : context) : Tool_result.result option =
  let config = ctx.config in
  let agent_name = ctx.agent_name in
  let state = ctx.state in
  let path =
    let p = arg_get_string ctx "path" "" in
    if String.equal p "" then arg_get_string ctx "workspace" "" else p
  in
  let task_title = arg_get_string ctx "task_title" "" in
  (* Step 1: set project root *)
  let workspace_result =
    if String.equal path "" then begin
      if Workspace.is_initialized (Mcp_server.workspace_config state) then
        Ok config
      else
        Error
          (Workspace_request_rejected
             "path is required when no project scope is set. Provide the project directory path.")
    end else begin
      match expand_start_path ~config path with
      | Error error -> Error (Workspace_request_rejected error)
      | Ok expanded ->
        if not (Sys.file_exists expanded && Sys.is_directory expanded) then
          Error
            (Workspace_request_rejected
               (Printf.sprintf "Directory not found: %s" expanded))
        else begin
          let cfg = Workspace.default_config expanded in
          match Mcp_server.validate_workspace_config state cfg with
          | Error error -> Error (Workspace_runtime_failed error)
          | Ok () ->
            if Workspace.is_initialized cfg then
              activate_workspace state cfg
            else begin
              let _msg = Workspace.init cfg ~agent_name:None in
              activate_workspace state cfg
            end
        end
    end
  in
  match workspace_result with
  | Error (Workspace_request_rejected error) ->
      (* workspace_result Error sources are all caller-input rejections:
         missing [path] argument or non-existent directory. *)
      Some
        (runtime_err_workflow ~tool_name ~start_time
           (Printf.sprintf
              "masc_start failed while setting project scope: %s"
              error))
  | Error (Workspace_runtime_failed error) ->
    Some
      (runtime_err_runtime
         ~tool_name
         ~start_time
         (Printf.sprintf
            "masc_start failed while setting project scope: %s"
            (Mcp_server.workspace_switch_error_to_string error)))
  | Ok active_config ->
    (* RFC-0393 D4: identity uniqueness is durable truth. An external agent
       binding under a name that already names a Keeper would poison every
       ledger attribution for that Keeper, so the join is refused at this
       boundary. Keeper runtimes do not bind through masc_start. *)
    let uniqueness_refusal =
      (* An unreadable census refuses the join: nothing was checked, so
         uniqueness is unproven. The keeper_names wrapper folds a census
         Error to [], which admitted the join exactly then. *)
      match Keeper_meta_store.keeper_names_result active_config with
      | Error census_error ->
        Some
          (Printf.sprintf
             "keeper name census unavailable (%s); retry once keeper metadata is readable"
             census_error)
      | Ok keeper_names ->
        (* Compare under the fold ledger attribution uses:
           [Keeper_identity.Keeper_id.of_string] lowercases, so "Alpha"
           and keeper "alpha" share one attribution id. A byte compare
           admits exactly the collision this gate exists to refuse. *)
        let joining = String.lowercase_ascii (String.trim agent_name) in
        if
          List.exists
            (fun keeper -> String.equal joining (String.lowercase_ascii keeper))
            keeper_names
        then
          Some
            (Printf.sprintf
               "%S already names a Keeper; join under a different agent name"
               agent_name)
        else None
    in
    match uniqueness_refusal with
    | Some reason ->
      Some
        (runtime_err_workflow ~tool_name ~start_time
           ("masc_start refused: " ^ reason))
    | None ->
    (* Step 2: bind session (idempotent) *)
    let session_binding_result =
      try
        let _msg = Workspace.bind_session active_config ~agent_name ~capabilities:[] () in
        Ok ()
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        let msg = Tool_error.to_string (Tool_error.of_exn exn) in
        if String.length msg > 0 then Error msg else Error "session binding failed"
    in
    match session_binding_result with
    | Error e ->
      (* Session binding exception caught from [Workspace.bind_session] — internal failure. *)
      Some
        (runtime_err_runtime ~tool_name ~start_time
           (Printf.sprintf "masc_start failed while binding agent session: %s" e))
    | Ok () ->
      (* Step 3: add_task + claim + plan_set_task (if task_title provided) *)
      if String.equal task_title "" then
        Some
          (runtime_ok ~tool_name ~start_time
             (Printf.sprintf
                "masc_start complete (project scope set + session bound as %s). No task created — use %s to create one."
                agent_name
                masc_add_task_name))
      else begin
        match
          Workspace_task_create.add_task_with_result
            active_config ~title:task_title ~priority:3 ~description:""
        with
        | Error error ->
          let detail = Workspace_task_create.add_task_error_to_string error in
          Some
            (Tool_result.make_err
               ~tool_name
               ~class_:Tool_result.Runtime_failure
               ~start_time
               ~data:
                 (`Assoc
                   [ ("agent_name", `String agent_name)
                   ; ( "effect_disposition"
                     , `String
                         (Tool_result.failure_effect_disposition_to_string
                            Tool_result.Proven_post_effect) )
                   ; ("error", `String detail)
                   ])
               (Printf.sprintf
                  "masc_start failed while creating a task after binding session %s: %s"
                  agent_name
                  detail))
        | Ok created ->
          let task_id = created.task_id in
          let add_result = created.summary in
          match
            Workspace_task.claim_task_r active_config ~agent_name ~task_id ()
          with
          | Error error ->
            let failure_class =
              match error with
              | Masc_domain.Task _ | Masc_domain.Agent _ ->
                Tool_result.Workflow_rejection
              | Masc_domain.Auth _ ->
                Tool_result.Policy_rejection
              | Masc_domain.RateLimitExceeded _
              | Masc_domain.System
                  (Masc_domain.System_error.IoError _
                  | Masc_domain.System_error.StorageError _
                  | Masc_domain.System_error.LockContention _)
              | Masc_domain.CacheError
                  (Masc_domain.CacheReadFailed _
                  | Masc_domain.CacheWriteFailed _
                  | Masc_domain.CacheExpired _) ->
                Tool_result.Dependency_unavailable
              | Masc_domain.System
                  (Masc_domain.System_error.NotInitialized
                  | Masc_domain.System_error.AlreadyInitialized
                  | Masc_domain.System_error.InvalidJson _
                  | Masc_domain.System_error.InvalidFilePath _
                  | Masc_domain.System_error.ValidationError _)
              | Masc_domain.CacheError (Masc_domain.CacheCorrupted _) ->
                Tool_result.Runtime_failure
            in
            Some
              (Tool_result.make_err
                 ~tool_name
                 ~class_:failure_class
                 ~start_time
                 ~data:
                   (`Assoc
                     [ ("task_id", `String task_id)
                     ; ("primary_result", `String add_result)
                     ; ( "effect_disposition"
                       , `String
                           (Tool_result.failure_effect_disposition_to_string
                              Tool_result.Proven_post_effect) )
                     ; ("error", `String (Masc_domain.to_string error))
                     ])
                 (Printf.sprintf
                    "masc_start created task %s but claim failed: %s"
                    task_id
                    (Masc_domain.to_string error)))
          | Ok _claim_msg ->
            match Planning_eio.set_current_task active_config ~task_id with
            | Error msg ->
              (* [Planning_eio.set_current_task] internal store failure. *)
              Some
                (Tool_result.make_err
                   ~tool_name
                   ~class_:Tool_result.Runtime_failure
                   ~start_time
                   ~data:
                     (`Assoc
                       [ ("task_id", `String task_id)
                       ; ("primary_result", `String add_result)
                       ; ( "effect_disposition"
                         , `String
                             (Tool_result.failure_effect_disposition_to_string
                                Tool_result.Proven_post_effect) )
                       ; ("error", `String msg)
                       ])
                   (Printf.sprintf
                      "masc_start created and claimed task %s, but setting it current failed: %s"
                      task_id
                      msg))
            | Ok () ->
                Some
                  (runtime_ok ~tool_name ~start_time
                     (Printf.sprintf
                        "masc_start complete: project scope set, session bound as %s, task %s created+claimed+set as current."
                        agent_name task_id))
      end
