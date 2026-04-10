(** Worker_container_runners — run_worker_oas, run_worker. *)

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

let build_execution_spec ~base_path ~worker_name ~model_label
    ?working_dir ?worker_class ?execution_scope
    ?thinking_enabled ~max_turns ?worker_run_id
    ?allowed_shell_tools ~role ~selection_note
    ~(prompt : string) ~(allowed_tools : string list) ~(timeout_sec : int) () =
  {
    Worker_execution_spec.base_path;
    worker_name;
    model_label;
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
    ~room_config ?working_dir ?worker_class
    ?execution_scope ?thinking_enabled ?allowed_shell_tools ?max_turns
    ?worker_run_id ~role ~selection_note
    ~(prompt : string) ~(allowed_tools : string list) ~(timeout_sec : int) :
    unit -> (run_result, string) result =
  let max_turns = Option.value ~default:10 max_turns in
  let spec =
    build_execution_spec ~base_path ~worker_name ~model_label
      ?working_dir ?worker_class
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
