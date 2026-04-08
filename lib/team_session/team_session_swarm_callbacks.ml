(** Team_session_swarm_callbacks — MASC supervision logic as OAS Swarm callbacks.

    Phase C-2b: Maps MASC checkpoint/event/broadcast into OAS Swarm lifecycle.

    @since 2.125.0 *)

let preview_text text =
  String.sub text 0 (min 200 (String.length text))

let usage_to_json (usage : Agent_sdk.Types.usage_stats) =
  `Assoc
    [
      ("input_tokens", `Int usage.total_input_tokens);
      ("output_tokens", `Int usage.total_output_tokens);
      ( "cache_creation_input_tokens",
        `Int usage.total_cache_creation_input_tokens );
      ("cache_read_input_tokens", `Int usage.total_cache_read_input_tokens);
      ("api_calls", `Int usage.api_calls);
      ("estimated_cost_usd", `Float usage.estimated_cost_usd);
    ]

let trace_ref_to_json (trace_ref : Agent_sdk.Raw_trace.run_ref) =
  `Assoc
    [
      ("worker_run_id", `String trace_ref.worker_run_id);
      ("start_seq", `Int trace_ref.start_seq);
      ("end_seq", `Int trace_ref.end_seq);
      ("agent_name", `String trace_ref.agent_name);
      ( "session_id",
        match trace_ref.session_id with
        | Some session_id -> `String session_id
        | None -> `Null );
    ]

let telemetry_to_json (telemetry : Swarm.Swarm_types.agent_telemetry) =
  `Assoc
    [
      ( "trace_ref",
        match telemetry.trace_ref with
        | Some trace_ref -> trace_ref_to_json trace_ref
        | None -> `Null );
      ( "usage",
        match telemetry.usage with
        | Some usage -> usage_to_json usage
        | None -> `Null );
      ("turn_count", `Int telemetry.turn_count);
    ]

let make_callbacks ~(config : Room.config) ~(session_id : string)
  : Swarm.Swarm_types.swarm_callbacks =
  let on_iteration_start iteration_num =
    Team_session_store.append_event config session_id
      ~event_type:"swarm_iteration_start"
      ~detail:(`Assoc [("iteration", `Int iteration_num)]);
    match Team_session_store.load_session config session_id with
    | Some session ->
      Team_session_engine_policy.write_checkpoint config session
    | None -> ()
  in
  let on_iteration_end (record : Swarm.Swarm_types.iteration_record) =
    let agent_count = List.length record.agent_results in
    let ok_count, error_count =
      List.fold_left
        (fun (ok_acc, err_acc) (_name, status) ->
          match (status : Swarm.Swarm_types.agent_status) with
          | Done_ok _ -> (ok_acc + 1, err_acc)
          | Done_error _ -> (ok_acc, err_acc + 1)
          | Working | Idle -> (ok_acc, err_acc))
        (0, 0) record.agent_results
    in
    Team_session_store.append_event config session_id
      ~event_type:"swarm_iteration_end"
      ~detail:(`Assoc [
        ("iteration", `Int record.iteration);
        ("agent_count", `Int agent_count);
        ("ok_count", `Int ok_count);
        ("error_count", `Int error_count);
        ("metric", match record.metric_value with
          | Some m -> `Float m | None -> `Null);
        ( "trace_refs",
          `List (List.map trace_ref_to_json record.trace_refs) );
      ])
  in
  let on_agent_start agent_name =
    Team_session_store.append_event config session_id
      ~event_type:"swarm_agent_start"
      ~detail:(`Assoc [("agent", `String agent_name)])
  in
  let on_agent_done agent_name (status : Swarm.Swarm_types.agent_status) =
    let status_str, elapsed, output_preview, telemetry =
      match status with
      | Done_ok { elapsed; text; telemetry } ->
        ("ok", elapsed, preview_text text, telemetry)
      | Done_error { elapsed; error; telemetry } ->
        ("error", elapsed, preview_text error, telemetry)
      | Working -> ("working", 0.0, "", Swarm.Swarm_types.empty_telemetry)
      | Idle -> ("idle", 0.0, "", Swarm.Swarm_types.empty_telemetry)
    in
    let trace_ref =
      match telemetry.trace_ref with
      | Some trace_ref -> trace_ref_to_json trace_ref
      | None -> `Null
    in
    let worker_run_id =
      match telemetry.trace_ref with
      | Some trace_ref -> `String trace_ref.worker_run_id
      | None -> `Null
    in
    let evidence_refs =
      match telemetry.trace_ref with
      | Some trace_ref -> `List [ `String ("worker-run:" ^ trace_ref.worker_run_id) ]
      | None -> `List []
    in
    Team_session_store.append_event config session_id
      ~event_type:"swarm_agent_done"
      ~detail:(`Assoc [
        ("agent", `String agent_name);
        ("status", `String status_str);
        ("elapsed", `Float elapsed);
        ("output_preview", `String output_preview);
        ("worker_run_id", worker_run_id);
        ("trace_ref", trace_ref);
        ("evidence_refs", evidence_refs);
        ("telemetry", telemetry_to_json telemetry);
      ])
  in
  let on_converged (_state : Swarm.Swarm_types.swarm_state) =
    Team_session_store.append_event config session_id
      ~event_type:"swarm_converged"
      ~detail:(`Assoc [("session_id", `String session_id)])
  in
  let on_error msg =
    Team_session_store.append_event config session_id
      ~event_type:"swarm_error"
      ~detail:(`Assoc [
        ("error", `String msg);
        ("session_id", `String session_id);
      ])
  in
  { on_iteration_start = Some on_iteration_start;
    on_iteration_end = Some on_iteration_end;
    on_agent_start = Some on_agent_start;
    on_agent_done = Some on_agent_done;
    on_converged = Some on_converged;
    on_error = Some on_error }
