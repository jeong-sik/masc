open Tool_command_plane_support
open Tool_command_plane_chain_common

let history_timestamp_iso json =
  match U.member "timestamp" json with
  | `String value -> Some value
  | `Float value -> Some (Command_plane_v2.iso_of_unix value)
  | `Int value -> Some (Command_plane_v2.iso_of_unix (float_of_int value))
  | `Intlit value -> (try Some (Command_plane_v2.iso_of_unix (float_of_string value)) with Failure _ -> None)
  | _ -> None

let history_tokens json =
  match U.member "tokens" json with
  | `Int value -> Some value
  | `Intlit value -> (try Some (int_of_string value) with Failure _ -> None)
  | `Assoc fields -> (
      match List.assoc_opt "total_tokens" fields with
      | Some (`Int value) -> Some value
      | Some (`Intlit value) -> (try Some (int_of_string value) with Failure _ -> None)
      | _ ->
          let prompt =
            match List.assoc_opt "prompt_tokens" fields with
            | Some (`Int value) -> value
            | Some (`Intlit value) -> (try int_of_string value with Failure _ -> 0)
            | _ -> 0
          in
          let completion =
            match List.assoc_opt "completion_tokens" fields with
            | Some (`Int value) -> value
            | Some (`Intlit value) -> (try int_of_string value with Failure _ -> 0)
            | _ -> 0
          in
          if prompt + completion > 0 then Some (prompt + completion) else None)
  | _ -> None

let history_event_json json =
  `Assoc
    [
      ( "event",
        match U.member "event" json with
        | `String value -> `String value
        | _ -> `String "unknown" );
      ( "chain_id",
        match U.member "chain_id" json with
        | `String value -> `String value
        | _ -> `Null );
      ( "timestamp",
        match history_timestamp_iso json with Some value -> `String value | None -> `Null );
      ( "duration_ms",
        match U.member "duration_ms" json with
        | `Int value -> `Int value
        | `Intlit value -> (try `Int (int_of_string value) with Failure _ -> `Null)
        | _ -> `Null );
      ("message", match U.member "message" json with `String value -> `String value | _ -> `Null);
      ("tokens", match history_tokens json with Some value -> `Int value | None -> `Null);
    ]

let run_store_history_json run_json =
  let chain_id =
    match U.member "chain_id" run_json with
    | `String value -> `String value
    | _ -> `Null
  in
  let duration_ms =
    match U.member "duration_ms" run_json with
    | `Int value -> `Int value
    | `Intlit value -> (try `Int (int_of_string value) with Failure _ -> `Null)
    | _ -> `Null
  in
  let started_at =
    match U.member "started_at" run_json with
    | `Float value -> Some value
    | `Int value -> Some (float_of_int value)
    | `Intlit value -> (try Some (float_of_string value) with Failure _ -> None)
    | _ -> None
  in
  let completed_at =
    match started_at, duration_ms with
    | Some started, `Int duration ->
        Some (Command_plane_v2.iso_of_unix (started +. (float_of_int duration /. 1000.0)))
    | Some started, _ -> Some (Command_plane_v2.iso_of_unix started)
    | None, _ -> None
  in
  let event_name =
    match U.member "success" run_json with
    | `Bool true -> "chain_complete"
    | `Bool false -> "chain_failed"
    | _ -> "chain_complete"
  in
  `Assoc
    [
      ("event", `String event_name);
      ("chain_id", chain_id);
      ( "timestamp",
        match completed_at with Some value -> `String value | None -> `Null );
      ("duration_ms", duration_ms);
      ("message", `Null);
      ("tokens", `Null);
    ]

let legacy_history_event_for_operation
    (operation : Command_plane_v2.operation_record)
    (chain : Command_plane_v2.chain_record) =
  let event =
    if String.equal chain.status "failed" || operation.status = Command_plane_v2.Failed then
      "chain_failed"
    else "chain_complete"
  in
  fallback_history_event_json ~event ~chain_id:chain.chain_id
    ?timestamp:(Some operation.updated_at) ()

let backfill_chain_overlays config =
  let actor = "system/chain-backfill" in
  Command_plane_v2.read_operations config
  |> List.iter (fun (operation : Command_plane_v2.operation_record) ->
         match operation.chain with
         | None -> ()
         | Some chain ->
             let run_json_opt =
               match chain.run_id with
               | Some run_id -> Chain_native_eio.run_json ~run_id
               | None -> None
             in
             let next_history_event =
               match chain.history_event with
               | Some _ as existing -> existing
               | None -> (
                   match run_json_opt with
                   | Some run_json -> Some (run_store_history_json run_json)
                   | None
                     when String.equal chain.status "completed"
                          || String.equal chain.status "failed" ->
                       Some (legacy_history_event_for_operation operation chain)
                   | None -> None)
             in
             let next_mermaid =
               match chain.mermaid with
               | Some _ as existing -> existing
               | None -> (
                   match mermaid_from_run_json run_json_opt with
                   | Some _ as value -> value
                   | None -> (
                       match chain.chain_id with
                       | Some chain_id ->
                           Chain_native_eio.registered_chain_mermaid ~config ~chain_id
                       | None -> None))
             in
             let next_preview_run =
               match chain.preview_run with
               | Some _ as existing -> existing
               | None -> (
                   match run_json_opt with
                   | Some run_json -> Some run_json
                   | None -> (
                       match chain.chain_id, next_mermaid with
                       | Some chain_id, _ ->
                           preview_run_json_of_source ~config ~chain_id ()
                       | None, Some mermaid ->
                           preview_run_json_of_source ~config ~mermaid ()
                       | None, None -> None))
             in
             let next_checkpoint_ref =
               match operation.checkpoint_ref, chain.run_id with
               | Some _ as current, _ -> current
               | None, Some run_id -> Some run_id
               | None, None -> None
             in
             if next_history_event <> chain.history_event
                || next_mermaid <> chain.mermaid
                || next_preview_run <> chain.preview_run
                || next_checkpoint_ref <> operation.checkpoint_ref
             then
               ignore
                 (Command_plane_v2.update_operation config ~actor
                    ~operation_id:operation.operation_id
                    ~event_type:"chain_backfilled"
                    ~detail:
                      (`Assoc
                        [
                          ("history_event", `Bool (next_history_event <> chain.history_event));
                          ("mermaid", `Bool (next_mermaid <> chain.mermaid));
                          ("preview_run", `Bool (next_preview_run <> chain.preview_run));
                          ("checkpoint_ref", `Bool (next_checkpoint_ref <> operation.checkpoint_ref));
                        ])
                    (fun current ->
                      let updated_chain =
                        match current.chain with
                        | Some current_chain ->
                            {
                              current_chain with
                              history_event = next_history_event;
                              mermaid = next_mermaid;
                              preview_run = next_preview_run;
                            }
                        | None ->
                            {
                              chain with
                              history_event = next_history_event;
                              mermaid = next_mermaid;
                              preview_run = next_preview_run;
                            }
                      in
                      { current with chain = Some updated_chain; checkpoint_ref = next_checkpoint_ref })))

let chain_summary_json (ctx : (_, _) context) =
  let backend = chain_backend () in
  let backend_name = chain_backend_to_string backend in
  let build_summary ~connection ~status_rows ~recent_history =
    let running_index : (string, Yojson.Safe.t) Hashtbl.t = Hashtbl.create 16 in
    List.iter
      (fun row ->
        match U.member "chain_id" row with
        | `String chain_id -> Hashtbl.replace running_index chain_id row
        | _ -> ())
      status_rows;
    let mermaid_index : (string, string) Hashtbl.t = Hashtbl.create 16 in
    let latest_history : (string, Yojson.Safe.t) Hashtbl.t = Hashtbl.create 16 in
    List.iter
      (fun row ->
        match U.member "chain_id" row with
        | `String chain_id ->
            if not (Hashtbl.mem latest_history chain_id) then
              Hashtbl.replace latest_history chain_id row;
            (match U.member "event" row, U.member "mermaid_dsl" row with
            | `String "chain_start", `String mermaid
              when not (Hashtbl.mem mermaid_index chain_id) ->
                Hashtbl.replace mermaid_index chain_id mermaid
            | _ -> ())
        | _ -> ())
      recent_history;
    let linked_operations =
      Command_plane_v2.read_operations ctx.config
      |> List.filter (fun (operation : Command_plane_v2.operation_record) ->
             Option.is_some operation.chain)
    in
    let overlays =
      linked_operations
      |> List.map (fun (operation : Command_plane_v2.operation_record) ->
             let persisted_history_json =
               match operation.chain with
               | Some chain -> Option.value ~default:`Null chain.history_event
               | None -> `Null
             in
             let persisted_mermaid_json =
               match operation.chain with
               | Some chain ->
                   Option.fold ~none:`Null ~some:(fun value -> `String value) chain.mermaid
               | None -> `Null
             in
             let persisted_preview_json =
               match operation.chain with
               | Some chain -> Option.value ~default:`Null chain.preview_run
               | None -> `Null
             in
             let run_json_opt =
               match operation.chain with
               | Some chain -> (
                   match chain.run_id with
                   | Some run_id -> Chain_native_eio.run_json ~run_id
                   | None -> None)
               | None -> None
             in
             let runtime_json =
               match operation.chain with
               | Some chain
                 when String.equal chain.status "running" || String.equal chain.status "pending" -> (
                   match chain.chain_id with
                   | Some chain_id ->
                       Hashtbl.find_opt running_index chain_id
                       |> Option.value ~default:`Null
                   | None -> `Null)
               | _ -> `Null
             in
             let history_json =
               match run_json_opt with
               | Some run_json -> run_store_history_json run_json
               | None when persisted_history_json <> `Null -> persisted_history_json
               | None -> (
                   match operation.chain with
                   | Some chain
                     when String.equal chain.status "running" || String.equal chain.status "pending" -> (
                       match chain.chain_id with
                       | Some chain_id ->
                           Hashtbl.find_opt latest_history chain_id
                           |> Option.map history_event_json |> Option.value ~default:`Null
                       | None -> `Null)
                   | _ -> `Null)
             in
             let mermaid_from_run =
               match run_json_opt with
               | Some run_json -> (
                   match U.member "mermaid" run_json with
                   | `String value -> Some value
                   | _ -> None)
               | None -> None
             in
             let mermaid_json =
               match mermaid_from_run with
               | Some value -> `String value
               | None when persisted_mermaid_json <> `Null -> persisted_mermaid_json
               | None -> (
                   match operation.chain with
                   | Some chain
                     when String.equal chain.status "running" || String.equal chain.status "pending" -> (
                       match chain.chain_id with
                       | Some chain_id ->
                           Hashtbl.find_opt mermaid_index chain_id
                           |> Option.map (fun value -> `String value)
                           |> Option.value ~default:`Null
                       | None -> `Null)
                   | _ -> `Null)
             in
             let preview_json =
               match run_json_opt with
               | Some run_json -> run_json
               | None when persisted_preview_json <> `Null -> persisted_preview_json
               | None -> `Null
             in
             `Assoc
               [
                 ("operation", Command_plane_v2.operation_to_json operation);
                 ("runtime", runtime_json);
                 ("history", history_json);
                 ("mermaid", mermaid_json);
                 ("preview_run", preview_json);
               ])
    in
    let recent_failures =
      recent_history
      |> List.filter (fun row ->
             match U.member "event" row with
             | `String "chain_error" -> true
             | _ -> false)
      |> List.length
    in
    let last_history_event_at =
      match recent_history with
      | head :: _ -> history_timestamp_iso head
      | [] -> None
    in
    Ok
      (`Assoc
        [
          ("schema_version", `Int 1);
          ("version", `String "chain-plane-v1");
          ("backend", `String backend_name);
          ("generated_at", `String (Types.now_iso ()));
          ("connection", connection);
          ( "summary",
            `Assoc
              [
                ("linked_operations", `Int (List.length linked_operations));
                ("active_chains", `Int (List.length status_rows));
                ( "running_operations",
                  `Int
                    (List.length
                       (List.filter
                          (fun (operation : Command_plane_v2.operation_record) ->
                            match operation.chain with
                            | Some chain -> String.equal chain.status "running"
                            | None -> false)
                          linked_operations)) );
                ("recent_failures", `Int recent_failures);
                ( "last_history_event_at",
                  match last_history_event_at with
                  | Some value -> `String value
                  | None -> `Null );
              ] );
          ("operations", `List overlays);
          ("recent_history", `List (List.map history_event_json recent_history));
        ])
  in
  let connection =
    `Assoc
      [
        ("status", `String "connected");
        ("base_url", `String "native://masc");
        ("message", `String "Chain summary is served from the native MASC chain plane.");
        ("backend", `String backend_name);
      ]
  in
  build_summary ~connection ~status_rows:(Chain_native_eio.running_chains_json ())
    ~recent_history:(Chain_native_eio.read_history_events ~limit:100)

let chain_run_get_json (_ctx : (_, _) context) ~run_id =
  match validate_run_id run_id with
  | Error _ as err -> err
  | Ok run_id -> (
      match Chain_native_eio.run_json ~run_id with
      | Some json ->
          Ok
            (`Assoc
              [
                ("schema_version", `Int 1);
                ("version", `String "chain-run-v1");
                ("backend", `String "native");
                ("run", json);
              ])
      | None -> Error (Printf.sprintf "chain run not found: %s" run_id))

let handle_chain_snapshot (ctx : (_, _) context) : result =
  json_result (chain_summary_json ctx)

let handle_chain_run_get (ctx : (_, _) context) args : result =
  match get_string_opt args "run_id" with
  | Some run_id -> json_result (chain_run_get_json ctx ~run_id)
  | None -> (false, json_error "run_id is required")

let handle_operation_status (ctx : (_, _) context) args : result =
  let operation_id = get_string_opt args "operation_id" in
  ( true,
    Yojson.Safe.to_string
      (Command_plane_v2.operation_status_json ctx.config ?operation_id ()) )

let handle_intent_create (ctx : (_, _) context) args : result =
  (match Command_plane_v2.create_intent_json ctx.config ~actor:ctx.agent_name args with
  | Ok intent -> (true, json_ok [ ("result", Command_plane_v2.intent_to_json intent) ])
  | Error message -> (false, json_error message))

let handle_intent_status (ctx : (_, _) context) args : result =
  let intent_id = get_string_opt args "intent_id" in
  (true, Yojson.Safe.to_string (Command_plane_v2.list_intents_json ?intent_id ctx.config))

let handle_intent_update (ctx : (_, _) context) args : result =
  (match Command_plane_v2.update_intent_json ctx.config ~actor:ctx.agent_name args with
  | Ok intent -> (true, json_ok [ ("result", Command_plane_v2.intent_to_json intent) ])
  | Error message -> (false, json_error message))

let handle_intent_forecast (ctx : (_, _) context) args : result =
  let intent_id =
    match get_string_opt args "intent_id" with
    | Some value -> value
    | None -> invalid_arg "intent_id is required"
  in
  let limit =
    match Yojson.Safe.Util.member "limit" args with
    | `Int value -> value
    | _ -> 3
  in
  json_result (Command_plane_v2.intent_forecast_json ctx.config intent_id ~limit ())

let handle_operation_checkpoint (ctx : (_, _) context) args : result =
  try
    match Command_plane_v2.checkpoint_operation ctx.config ~actor:ctx.agent_name args with
    | Ok operation ->
        ( true,
          json_ok
            [
              ("result", Command_plane_v2.operation_to_json operation);
              ("traces", Command_plane_v2.list_traces_json ctx.config ~operation_id:operation.operation_id ());
            ] )
    | Error message -> (false, json_error message)
  with Invalid_argument message -> (false, json_error message)

let handle_observe_topology (ctx : (_, _) context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.topology_json ctx.config))

let handle_observe_alerts (ctx : (_, _) context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.list_alerts_json ctx.config))

let handle_observe_operations (ctx : (_, _) context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.observe_operations_json ctx.config))

let handle_observe_swarm (_ctx : (_, _) context) _args : result =
  (true, Yojson.Safe.to_string (`Assoc []))

let handle_observe_capacity (ctx : (_, _) context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.observe_capacity_json ctx.config))

let handle_observe_traces (ctx : (_, _) context) args : result =
  let operation_id = get_string_opt args "operation_id" in
  let limit =
    match Yojson.Safe.Util.member "limit" args with
    | `Int value -> value
    | _ -> 25
  in
  ( true,
    Yojson.Safe.to_string
      (Command_plane_v2.list_traces_json ctx.config ?operation_id ~limit ()))
