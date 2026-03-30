(** Team_session_swarm_runner — OAS Swarm-based team session execution.

    Phase C-2a: Strangler Fig pattern — run Auto-mode sessions through
    OAS Swarm Runner while keeping the existing engine for Manual/Assist.

    @since 2.125.0 *)

module Swarm = Agent_sdk_swarm

let run_swarm ~sw ~(env : < clock : _ Eio.Time.clock ; process_mgr : _ Eio.Process.mgr ; .. >) ~(config : Room.config)
    ~(session_id : string)
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
  : (Team_session_types.session, string) result =
  match Team_session_store.load_session config session_id with
  | None -> Error (Printf.sprintf "session %s not found" session_id)
  | Some session -> (
      match Team_session_state.require_running session with
      | Error msg -> Error (Printf.sprintf "session %s: %s" session_id msg)
      | Ok running_session ->
      let session = Team_session_state.session running_session in
      let swarm_config =
        Team_session_oas_bridge.session_to_swarm_config
          ~config ~masc_tools ~dispatch session
      in
      if swarm_config.entries = [] then begin
        Team_session_store.append_event config session_id
          ~event_type:"swarm_deferred"
          ~detail:
            (`Assoc
              [
                ("reason", `String "no_planned_workers");
                ("ts_iso", `String (Types.now_iso ()));
              ]);
        Ok session
      end else
        let callbacks =
          Team_session_swarm_callbacks.make_callbacks ~config ~session_id
        in
        match Swarm.Runner.run ~sw ~env ~callbacks swarm_config with
        | Ok swarm_result ->
          let updated =
            Team_session_oas_bridge.apply_swarm_result session swarm_result
          in
          Team_session_store.save_session config updated;
          Team_session_store.append_event config session_id
            ~event_type:"swarm_completed"
            ~detail:(`Assoc [
              ("converged", `Bool swarm_result.converged);
              ("iterations", `Int (List.length swarm_result.iterations));
              ("total_elapsed", `Float swarm_result.total_elapsed);
              ("final_metric",
                match swarm_result.final_metric with
                | Some m -> `Float m | None -> `Null);
            ]);
          Ok updated
        | Error sdk_err ->
          let reason = Agent_sdk.Error.to_string sdk_err in
          Team_session_store.append_event config session_id
            ~event_type:"swarm_error"
            ~detail:(`Assoc [("error", `String reason)]);
          let final_status = Team_session_types.Failed in
          let now = Time_compat.now () in
          let updated =
            { session with
              status = final_status;
              stopped_at = Some now;
              stop_reason = Some reason;
              updated_at_iso = Types.now_iso () }
          in
          Team_session_store.save_session config updated;
          Error reason)
