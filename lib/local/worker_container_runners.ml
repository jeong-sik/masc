(** Worker_container_runners — run_worker_oas, continue_worker, run_worker. *)

open Printf
open Result_syntax

include Worker_container

let resolve_net ?net () =
  match net with
  | Some net -> Ok net
  | None -> (
      match Eio_context.get_net_opt () with
      | Some net -> Ok net
      | None -> Error "Eio net not initialized")

let default_shell_tool_names execution_scope =
  match execution_scope with
  | Some Worker_types.Observe_only ->
      [ "file_read"; "shell_exec" ]
  | _ ->
      [ "file_read"; "file_write"; "shell_exec" ]

let build_execution_spec ~base_path ~worker_name ~model_label ~team_session_id
    ?working_dir ?worker_class ?execution_scope
    ?thinking_enabled ~max_turns ?worker_run_id
    ?allowed_shell_tools ~role ~selection_note
    ~(prompt : string) ~(allowed_tools : string list) ~(timeout_sec : int) () =
  {
    Worker_execution_spec.base_path;
    worker_name;
    model_label;
    team_session_id;
    working_dir;
    worker_class;
    execution_scope;
    thinking_enabled;
    max_turns;
    worker_run_id;
    role;
    selection_note;
    prompt;
    allowed_tools;
    allowed_shell_tools =
      Option.value ~default:(default_shell_tool_names execution_scope)
        allowed_shell_tools;
    timeout_sec;
  }

let run_worker_oas ~sw ?net ~room_config
    (spec : Worker_execution_spec.t) : unit -> (run_result, string) result =
  fun () ->
    (* Worker_run_once removed — return error *)
    ignore (sw, net, room_config, spec);
    Error "Worker_run_once removed (team session layer)"

let continue_worker ?worker_run_id ?contract ~sw ?net ~base_path ~room_config ~worker_name
    ~(team_session_id : string) ~(prompt : string) :
    unit -> (run_result, string) result =
  fun () ->
  let team_session_id = Some team_session_id in
  match worker_container_state ~base_path ~team_session_id ~worker_name with
  | Worker_missing ->
      Error
        (sprintf
           "target worker '%s' was not found. Use status.worker_runs or the \
            latest team_step_spawn event to find a ready worker name."
           worker_name)
  | Worker_pending ->
      Error
        (sprintf
           "target worker '%s' has been accepted but is not ready for \
            delegation yet. Wait for a successful team_step_spawn event or a \
            ready worker in status.worker_runs."
           worker_name)
  | Worker_ready ->
      let meta =
        load_worker_meta ~base_path ~team_session_id ~worker_name
      in
      let checkpoint =
        load_worker_checkpoint ~base_path ~team_session_id ~worker_name
      in
      (match meta, checkpoint with
      | None, _ ->
          Error
            (sprintf "worker container metadata disappeared: %s" worker_name)
      | _, None ->
          Error
            (sprintf
               "worker checkpoint is not available for '%s'; wait for the \
                worker to finish its first run before delegating."
               worker_name)
      | Some meta, Some checkpoint -> (
      let workspace_path =
        if String.trim meta.workspace_path <> "" then meta.workspace_path
        else base_path
      in
      match worker_auth_token ~base_path ~worker_name with
      | Error e -> Error e
          | Ok auth_token ->
              let allowed_tools =
                match meta.shell_profile with
                | Shell_dev ->
                    [
                      "mcp__masc__masc_heartbeat";
                      "mcp__masc__masc_relay_status";
                      "mcp__masc__masc_relay_checkpoint";
                      "mcp__masc__masc_relay_now";
                    ]
                | _ ->
                    session_min_tool_names
                    |> List.map (fun name -> "mcp__masc__" ^ name)
              in
              let* mcp_tools =
                build_oas_mcp_tools ~sw ~auth_token
                  ~session_id:meta.mcp_session_id ~worker_name ~prompt
                  ~allowed_tools
              in
              let mcp_tools =
                List.map (Oas.Tool.with_defaults
                  [("agent_name", `String worker_name)]) mcp_tools
              in
              let shell_tools =
                match meta.shell_profile with
                | Shell_none -> Ok []
                | Shell_readonly ->
                    build_local_shell_tools
                      ~room_config ~worker_name
                      ~execution_scope:Worker_types.Observe_only
                      ~workdir:workspace_path
                | Shell_dev ->
                    build_local_shell_tools
                      ~room_config ~worker_name
                      ~execution_scope:Worker_types.Limited_code_change
                      ~workdir:workspace_path
              in
              let* shell_tools = shell_tools in
              let* raw_trace =
                match evidence_session_id_of_worker_run worker_run_id with
                | Some trace_session_id ->
                    Oas.Raw_trace.create_for_session
                      ~session_root:(oas_trace_session_root ~base_path)
                      ~session_id:trace_session_id ~agent_name:worker_name ()
                    |> Result.map_error Oas.Error.to_string
                | None -> (
                    match meta.team_session_id with
                    | Some trace_session_id ->
                        Oas.Raw_trace.create_for_session
                          ~session_root:(oas_trace_session_root ~base_path)
                          ~session_id:trace_session_id ~agent_name:worker_name ()
                        |> Result.map_error Oas.Error.to_string
                    | None ->
                        Oas.Raw_trace.create ~session_id:meta.mcp_session_id
                          ~path:
                            (worker_raw_trace_path ~base_path ~team_session_id
                               ~worker_name)
                          ()
                        |> Result.map_error Oas.Error.to_string)
              in
              let tools = mcp_tools @ shell_tools in
              let prompt =
                let tool_contract =
                  "Tool contract reminder: if you call masc_team_session_step \
                   with turn_kind=\"note\", you must include a non-empty \
                   message field. Calls missing message fail."
                in
                let workflow_contract =
                  match meta.execution_scope with
                  | Worker_types.Limited_code_change ->
                      "Coding worker protocol: you must use tools before \
                       answering. If the task requires a code change, the \
                       expected loop is file_read -> shell_exec -> file_write \
                       -> shell_exec, and you should not finish until \
                       verification succeeds. If the task is inspection-only, \
                       do not modify files."
                  | Worker_types.Observe_only ->
                      "Readonly worker protocol: use file_read and shell_exec \
                       for inspection, but do not modify files."
                  | Worker_types.Autonomous ->
                      "You have full read and write access. Choose the approach \
                       that best accomplishes your task. Use tools to verify \
                       your work."
                in
                String.concat "\n\n" [ tool_contract; workflow_contract; prompt ]
              in
              let* net = resolve_net ?net () in
              Worker_oas.resume_worker_via_oas ~sw ~net ~base_path ~meta ~checkpoint
                ~prompt ~tools ~raw_trace ?contract ?worker_run_id ()))

let preflight_spawn_batch ?clock_opt specs =
  let docker_specs =
    specs
    |> List.filter (fun (spec : Worker_execution_spec.t) ->
           match spec.execution_scope with
           | Some scope ->
               Worker_runtime_config.backend_for_scope scope
               = Worker_execution_backend.Docker
           | None -> false)
    |> List.map (fun (spec : Worker_execution_spec.t) ->
           {
             Worker_runtime_docker.worker_name = spec.worker_name;
             model_label = spec.model_label;
           })
  in
  match docker_specs with
  | [] -> Ok ()
  | _ -> Worker_runtime_docker.preflight_batch ?clock_opt docker_specs

let run_worker ~sw ?net ~backend ~base_path ~worker_name ~model_label
    ~team_session_id ~room_config ?working_dir ?worker_class
    ?execution_scope ?thinking_enabled ?allowed_shell_tools ?max_turns
    ?worker_run_id ~role ~selection_note
    ~(prompt : string) ~(allowed_tools : string list) ~(timeout_sec : int) :
    unit -> (run_result, string) result =
  let max_turns = Option.value ~default:10 max_turns in
  let spec =
    build_execution_spec ~base_path ~worker_name ~model_label
      ~team_session_id ?working_dir ?worker_class
      ?execution_scope ?thinking_enabled ~max_turns ?worker_run_id
      ?allowed_shell_tools ~role ~selection_note ~prompt
      ~allowed_tools ~timeout_sec ()
  in
  match backend with
  | Worker_execution_backend.Local ->
      run_worker_oas ~sw ?net ~room_config spec
  | Worker_execution_backend.Docker ->
      let spec = Worker_runtime_docker.rewrite_spec_for_container spec in
      let clock_opt = Eio_context.get_clock_opt () in
      fun () -> Worker_runtime_docker.run_worker_spec ?clock_opt spec
