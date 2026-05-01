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

let default_shell_tool_names () =
  [ "file_read"; "file_write"; "shell_exec" ]

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

let effective_model_of_resume ~existing_meta spec =
  match existing_meta with
  | Some meta when String.trim meta.effective_model <> "" ->
      Ok meta.effective_model
  | _ ->
      resolve_oas_provider_of_label spec.Worker_execution_spec.model_label
      |> Result.map snd

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

let run_worker_oas ~sw ?net ~room_config
    (spec : Worker_execution_spec.t) : unit -> (run_result, string) result =
  fun () ->
    let* net = resolve_net ?net () in
    let worker_name = spec.worker_name in
    let base_path = spec.base_path in
    let workspace_path = workspace_path_of_spec spec in
    let mcp_session_id =
      resolved_mcp_session_id ~base_path ~worker_name
    in
    let existing_meta = load_worker_meta ~base_path ~worker_name in
    let checkpoint = load_worker_checkpoint ~base_path ~worker_name in
    let* effective_model =
      match checkpoint with
      | Some _ -> effective_model_of_resume ~existing_meta spec
      | None ->
          resolve_oas_provider_of_label spec.model_label
          |> Result.map snd
    in
    let meta =
      make_worker_meta ~base_path ~workspace_path ~worker_name
        ~mcp_session_id ~role:spec.role
        ~selection_note:spec.selection_note
        ~runtime_backend:spec.runtime_backend
        ~effective_model ~thinking_enabled:spec.thinking_enabled
        ~timeout_seconds:(Some spec.timeout_sec)
    in
    let* auth_token =
      worker_auth_token ~base_path ~worker_name
    in
    let* masc_tools =
      build_oas_mcp_tools ~sw ~auth_token ~session_id:mcp_session_id
        ~worker_name
    in
    let* shell_tools =
      build_local_shell_tools ~room_config ~worker_name ~workdir:workspace_path
    in
    let tools = dedupe_tools_by_name (masc_tools @ shell_tools) in
    let* raw_trace = create_raw_trace ~base_path ~worker_name in
    match checkpoint with
    | Some checkpoint ->
        Worker_oas.resume_worker_via_oas ~sw ~net ~base_path ~auth_token
          ~meta ~checkpoint ~prompt:spec.prompt ~tools ~raw_trace
          ?worker_run_id:spec.worker_run_id ()
    | None ->
        let* provider, model_id =
          resolve_oas_provider_of_label spec.model_label
        in
        let system_prompt =
          default_system_prompt ~worker_name ~model_id
            ?role:spec.role
            ?selection_note:spec.selection_note ()
        in
        let gate_config = Worker_oas.default_gate_config () in
        Worker_oas.run_worker_via_oas ~sw ~net ~base_path ~auth_token
          ~meta:{ meta with effective_model = model_id }
          ~provider ~system_prompt ~prompt:spec.prompt ~tools
          ~raw_trace ~gate_config
          ?worker_run_id:spec.worker_run_id ()


let preflight_spawn_batch ?clock_opt specs =
  match Worker_runtime_config.backend () with
  | Worker_execution_backend.Local_playground -> Ok ()
  | Worker_execution_backend.Docker ->
      let docker_specs =
        specs
        |> List.filter (fun (spec : Worker_execution_spec.t) ->
               spec.runtime_backend = Worker_execution_backend.Docker)
        |> List.map (fun (spec : Worker_execution_spec.t) ->
               {
                 Worker_runtime_docker.worker_name = spec.worker_name;
                 model_label = spec.model_label;
               })
      in
      Worker_runtime_docker.preflight_batch ?clock_opt docker_specs

let run_worker ~sw ?net ~runtime_backend ~base_path ~worker_name ~model_label
    ~room_config ?working_dir
    ?thinking_enabled
    ?worker_run_id ~role ~selection_note
    ~(prompt : string) ~(timeout_sec : int) :
    unit -> (run_result, string) result =
  let spec =
    build_execution_spec ~base_path ~worker_name ~model_label
      ~runtime_backend ?working_dir
      ?thinking_enabled ?worker_run_id ~role ~selection_note ~prompt
      ~timeout_sec ()
  in
  match runtime_backend with
  | Worker_execution_backend.Local_playground ->
      run_worker_oas ~sw ?net ~room_config spec
  | Worker_execution_backend.Docker ->
      let spec = Worker_runtime_docker.rewrite_spec_for_container spec in
      let clock_opt = Eio_context.get_clock_opt () in
      fun () -> Worker_runtime_docker.run_worker_spec ?clock_opt spec
