(** Team_session_swarm_callbacks — MASC supervision logic as OAS Swarm callbacks.

    Phase C-2b: Maps MASC checkpoint/event/broadcast into OAS Swarm lifecycle.

    @since 2.125.0 *)

module Swarm = Agent_sdk_swarm

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
    let ok_count =
      List.fold_left (fun acc (_name, status) ->
        match (status : Swarm.Swarm_types.agent_status) with
        | Done_ok _ -> acc + 1
        | _ -> acc)
        0 record.agent_results
    in
    Team_session_store.append_event config session_id
      ~event_type:"swarm_iteration_end"
      ~detail:(`Assoc [
        ("iteration", `Int record.iteration);
        ("agent_count", `Int agent_count);
        ("ok_count", `Int ok_count);
        ("metric", match record.metric_value with
          | Some m -> `Float m | None -> `Null);
      ])
  in
  let on_agent_start agent_name =
    Team_session_store.append_event config session_id
      ~event_type:"swarm_agent_start"
      ~detail:(`Assoc [("agent", `String agent_name)])
  in
  let on_agent_done agent_name (status : Swarm.Swarm_types.agent_status) =
    let status_str, elapsed, output_preview =
      match status with
      | Done_ok { elapsed; text; _ } ->
        ("ok", elapsed, String.sub text 0 (min 200 (String.length text)))
      | Done_error { elapsed; error; _ } ->
        ("error", elapsed, String.sub error 0 (min 200 (String.length error)))
      | Working -> ("working", 0.0, "")
      | Idle -> ("idle", 0.0, "")
    in
    Team_session_store.append_event config session_id
      ~event_type:"swarm_agent_done"
      ~detail:(`Assoc [
        ("agent", `String agent_name);
        ("status", `String status_str);
        ("elapsed", `Float elapsed);
        ("output_preview", `String output_preview);
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
