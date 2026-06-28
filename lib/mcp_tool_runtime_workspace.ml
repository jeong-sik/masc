module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Mcp_tool_runtime_workspace — project startup tool handler.

    Handles: masc_start.

    Extracted from mcp_tool_runtime.ml to keep the runtime router small. *)

module Planning_eio = Task.Planning_eio

open Mcp_tool_runtime_types

(* RFC-0189 PR-2: lifecycle handlers return [Tool_result.result option]
   directly, matching the shared MCP runtime alias. *)

let runtime_ok ~tool_name ~start_time body : Tool_result.result =
  let data =
    match Tool_result.structured_payload_of_message body with
    | Some json -> json
    | None -> `String body
  in
  Tool_result.make_ok ~tool_name ~start_time ~data ()
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

let arg_get_string_list ctx key =
  Safe_ops.json_string_list key ctx.arguments

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
        Error "path is required when no project scope is set. Provide the project directory path."
    end else begin
      match expand_start_path ~config path with
      | Error _ as err -> err
      | Ok expanded ->
        if not (Sys.file_exists expanded && Sys.is_directory expanded) then
          Error (Printf.sprintf "Directory not found: %s" expanded)
        else begin
          let cfg = Workspace.default_config expanded in
          if Workspace.is_initialized cfg then begin
            Mcp_server.set_workspace_config state cfg;
            Ok cfg
          end else begin
            let _msg = Workspace.init cfg ~agent_name:None in
            Mcp_server.set_workspace_config state cfg;
            Ok cfg
          end
        end
    end
  in
  match workspace_result with
  | Error e ->
      (* workspace_result Error sources are all caller-input rejections:
         missing [path] argument or non-existent directory. *)
      Some
        (runtime_err_workflow ~tool_name ~start_time
           (Printf.sprintf "masc_start failed while setting project scope: %s" e))
  | Ok active_config ->
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
        (* RFC-0034.v2: per-goal cap guard. masc_start does not pass a
           [goal_id], so the guard is a no-op for orphan tasks. Wired so
           a future goal-aware variant inherits the cap automatically. *)
        let add_result =
          Workspace_task.add_task
            ~reject_if:(Workspace_task_capacity.rejection_for_add_task ?goal_id:None)
            active_config ~title:task_title ~priority:3 ~description:""
        in
        (* Extract task ID from result like "Added task-001: title" *)
        let task_id =
          try
            let prefix = "Added " in
            let idx = ref 0 in
            while !idx < String.length add_result - String.length prefix &&
                  not (String.equal (Stdlib.String.sub add_result !idx (String.length prefix)) prefix) do
              Stdlib.incr idx
            done;
            let start = !idx + String.length prefix in
            let end_idx = match String.index_from_opt add_result start ':' with
              | Some idx -> idx
              | None -> String.length add_result
            in
            String.sub add_result start (end_idx - start)
          with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ""
        in
        if String.equal task_id "" then
          Some
            (runtime_ok ~tool_name ~start_time
               (Printf.sprintf
                  "masc_start partial: session bound as %s, but task creation failed: %s"
                  agent_name add_result))
        else begin
          let _claim_msg = Workspace_task.claim_task active_config ~agent_name ~task_id in
          match Planning_eio.set_current_task active_config ~task_id with
          | Error msg ->
            (* [Planning_eio.set_current_task] internal store failure. *)
            Some (runtime_err_runtime ~tool_name ~start_time msg)
          | Ok () ->
              Some
                (runtime_ok ~tool_name ~start_time
                   (Printf.sprintf
                      "masc_start complete: project scope set, session bound as %s, task %s created+claimed+set as current."
                      agent_name task_id))
        end
      end
