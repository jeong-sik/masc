module Agent = Agent_core.Agent
open Result.Syntax

type t =
  { runtime : Agent.execution_runtime
  ; fs : Eio.Fs.dir_ty Eio.Path.t
  ; directory : string
  ; call_id : string
  }

let call_id t = t.call_id

let reopen ~base_path ~keeper_name ~call_id =
  let* keeper = Keeper_id.Keeper_name.of_string keeper_name in
  let* call = Keeper_id.Trace_id.of_string call_id in
  let* runtime = match Runtime_agent_execution_runtime.get () with
    | Some runtime -> Ok runtime
    | None -> Error "native request journal runtime is unavailable" in
  let* fs = match Fs_compat.get_fs_opt () with
    | Some fs -> Ok fs
    | None -> Error "native request journal filesystem is unavailable" in
  let directory = Filename.concat
      (Filename.concat
        (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path)
          (Keeper_id.Keeper_name.to_string keeper)) "request-executions")
      (Keeper_id.Trace_id.to_string call) in
  Ok { runtime; fs; directory; call_id }

let locator_path t = Filename.concat t.directory "locator.json"
let journal_dir t = Eio.Path.(t.fs / t.directory / "journal")

let prepare ?on_scope_ready:owner_scope_ready ~base_path ~keeper_name ~(config : Runtime_agent.config) () =
  let* () = match config.execution_store with
    | None -> Ok ()
    | Some _ -> Error "native request journal cannot replace an execution store" in
  let* t = reopen ~base_path ~keeper_name ~call_id:(Random_id.uuid_v7 ()) in
  let* () =
    try
      Eio.Path.mkdirs ~exists_ok:true ~perm:0o700
        Eio.Path.(t.fs / Filename.dirname t.directory);
      Eio.Path.mkdir ~perm:0o700 Eio.Path.(t.fs / t.directory);
      Eio.Path.mkdir ~perm:0o700 (journal_dir t);
      Ok ()
    with Eio.Io _ as exn -> Error (Format.asprintf "%a" Eio.Exn.pp exn) in
  let on_scope_ready locator =
    let* () = Agent.execution_locator_to_yojson locator
    |> Keeper_fs.save_json_durable_atomic ~ownership_root:base_path ~pretty:false (locator_path t)
    |> Result.map_error Keeper_fs.durable_write_error_to_string in
    match owner_scope_ready with None -> Ok () | Some ready -> ready ~call_id:t.call_id in
  let execution_store = Agent.execution_store ~runtime:t.runtime
      ~dir:(journal_dir t) ~on_scope_ready () in
  Ok (t, { config with execution_store=Some execution_store })

let projection t =
    let* bytes =
      try Ok (Eio.Path.load Eio.Path.(t.fs / locator_path t)) with
      | Eio.Io _ as exn -> Error (Format.asprintf "%a" Eio.Exn.pp exn) in
    let* json = try Ok (Yojson.Safe.from_string bytes)
      with Yojson.Json_error detail -> Error detail in
    let* locator = Agent.execution_locator_of_yojson json in
    Agent.open_execution_projection ~runtime:t.runtime
        ~dir:(journal_dir t) locator
      |> Result.map_error Agent.Execution_projection.error_to_string

let request_evidence t =
  let read () =
    let* projection = projection t in
    let* requests = Agent.Execution_projection.provider_requests projection ()
      |> Result.map_error Agent.Execution_projection.error_to_string in
    let requests = List.map (fun (request : Agent.Execution_projection.provider_request) ->
      { Request_observation.node_id=Agent.Execution_projection.Node_id.to_string request.node_id
      ; turn=request.turn; ordinal=request.ordinal; provenance=request.provenance }) requests in
    Ok (Request_observation.Recorded { call_id=t.call_id; requests }) in
  match read () with
  | Ok evidence -> evidence
  | Error detail -> Request_observation.Read_failed detail
