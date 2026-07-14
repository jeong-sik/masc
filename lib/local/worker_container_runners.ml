(** Worker_container_runners — run_worker_oas, run_worker. *)

include Worker_container

open Result.Syntax

let resolve_net ?net () =
  match net with
  | Some net -> Ok net
  | None -> (
      match Eio_context.get_net_opt () with
      | Some net -> Ok net
      | None -> Error "Eio net not initialized")

let build_execution_spec ~base_path ~worker_name ~model_label
    ~runtime_backend ?working_dir
    ?thinking_enabled ?worker_run_id ~role ~selection_note
    ~(prompt : string) ~(timeout_sec : int) () =
  {
    Worker_execution_spec.base_path;
    worker_name;
    model_label;
    working_dir;
    runtime_backend;
    thinking_enabled;
    worker_run_id;
    role;
    selection_note;
    prompt;
    timeout_sec;
  }

let workspace_path_of_spec (spec : Worker_execution_spec.t) =
  match spec.working_dir with
  | Some dir when String.trim dir <> "" -> dir
  | _ -> spec.base_path

let dedupe_tools_by_name (tools : Agent_sdk.Tool.t list) =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | ((tool : Agent_sdk.Tool.t) :: rest) ->
        if List.mem tool.schema.name seen then
          loop seen acc rest
        else
          loop (tool.schema.name :: seen) (tool :: acc) rest
  in
  loop [] [] tools

let create_raw_trace ~base_path ~worker_name =
  try
    ensure_worker_container_dirs ~base_path ~worker_name;
    match
      Agent_sdk.Raw_trace.create
        ~path:(worker_raw_trace_path ~base_path ~worker_name)
        ()
    with
    | Ok raw_trace -> Ok raw_trace
    | Error err -> Error (Agent_sdk.Error.to_string err)
  with Sys_error msg ->
    Error
      (Printf.sprintf "failed to create worker raw trace for %s: %s"
         worker_name msg)

let run_worker_oas ~sw ?net ~workspace_config:_
    (spec : Worker_execution_spec.t) : unit -> (run_result, string) result =
  fun () ->
    let* net = resolve_net ?net () in
    let worker_name = spec.worker_name in
    let base_path = spec.base_path in
    let workspace_path = workspace_path_of_spec spec in
    let mcp_session_id =
      resolved_mcp_session_id ~base_path ~worker_name
    in
    let checkpoint = load_worker_checkpoint ~base_path ~worker_name in
    let* provider_config = oas_provider_of_label spec.model_label in
    let model_id = provider_config.Llm_provider.Provider_config.model_id in
    let meta =
      make_worker_meta ~base_path ~workspace_path ~worker_name
        ~mcp_session_id ~role:spec.role
        ~selection_note:spec.selection_note
        ~runtime_backend:spec.runtime_backend
        ~effective_model:model_id ~thinking_enabled:spec.thinking_enabled
        ~timeout_seconds:(Some spec.timeout_sec)
    in
    let* auth_token =
      worker_auth_token ~base_path ~worker_name
    in
    let* masc_tools =
      build_oas_mcp_tools ~sw ~auth_token ~session_id:mcp_session_id
        ~worker_name
    in
    let tools = dedupe_tools_by_name masc_tools in
    let* raw_trace = create_raw_trace ~base_path ~worker_name in
    match checkpoint with
    | Some checkpoint ->
        Worker_oas.resume_worker_via_oas ~sw ~net ~base_path ~auth_token
          ~meta ~provider_config ~checkpoint ~prompt:spec.prompt ~tools ~raw_trace
          ?worker_run_id:spec.worker_run_id ()
    | None ->
        let system_prompt =
          default_system_prompt ~worker_name ~model_id
            ?role:spec.role
            ?selection_note:spec.selection_note ()
        in
        Worker_oas.run_worker_via_oas ~sw ~net ~base_path ~auth_token
          ~meta ~provider_config ~system_prompt ~prompt:spec.prompt ~tools
          ~raw_trace
          ?worker_run_id:spec.worker_run_id ()
