
open Swarm_status_types
open Swarm_status_json

let operation_of_json row =
  let json = U.member "operation" row in
  {
    operation_id = get_string_default json "operation_id" "";
    objective = get_string_default json "objective" "";
    source = get_string_default json "source" "managed";
    status = get_string_default json "status" "active";
    trace_id = get_string_default json "trace_id" "";
    detachment_session_id = get_string_opt json "detachment_session_id";
    note = get_string_opt json "note";
    updated_at = get_string_opt json "updated_at";
  }

let detachment_of_json row =
  let json = U.member "detachment" row in
  {
    detachment_id = get_string_default json "detachment_id" "";
    operation_id = get_string_default json "operation_id" "";
    source = get_string_default json "source" "managed";
    status = get_string_default json "status" "active";
    runtime_kind = get_string_opt json "runtime_kind";
    session_id = get_string_opt json "session_id";
    roster =
      list_member json "roster"
      |> List.filter_map (function
           | `String value ->
               let trimmed = String.trim value in
               if trimmed = "" then None else Some trimmed
           | _ -> None);
    leader_id = get_string_opt json "leader_id";
    last_event_at = get_string_opt json "last_event_at";
    last_progress_at = get_string_opt json "last_progress_at";
    updated_at = get_string_opt json "updated_at";
  }

let alert_of_json json =
  {
    alert_id = get_string_default json "alert_id" "";
    severity = get_string_default json "severity" "warn";
    scope_type = get_string_opt json "scope_type";
    scope_id = get_string_opt json "scope_id";
    title = get_string_opt json "title";
    detail = get_string_opt json "detail";
    timestamp = get_string_opt json "timestamp";
  }

let decision_of_json json =
  {
    decision_id = get_string_default json "decision_id" "";
    source = get_string_default json "source" "managed";
    status = get_string_default json "status" "pending";
    scope_type = get_string_opt json "scope_type";
    scope_id = get_string_opt json "scope_id";
    operation_id = get_string_opt json "operation_id";
    requested_action = get_string_opt json "requested_action";
    created_at = get_string_opt json "created_at";
  }

let trace_of_json json =
  {
    event_id = get_string_default json "event_id" "";
    event_type = get_string_default json "event_type" "trace";
    source = get_string_default json "source" "command_plane";
    trace_id = get_string_default json "trace_id" "";
    operation_id = get_string_opt json "operation_id";
    actor = get_string_opt json "actor";
    timestamp = get_string_opt json "timestamp";
    detail =
      match U.member "detail" json with
      | `Assoc _ as detail -> detail
      | `List _ as detail -> detail
      | `Null -> `Assoc []
      | value -> value;
  }

let session_worker_names (session : Team_session_types.session) =
  let actor_names =
    session.agent_names
    @ List.filter_map
        (fun (worker : Team_session_types.planned_worker) -> worker.runtime_actor)
        session.planned_workers
  in
  Team_session_types.dedup_strings actor_names

let session_info_of_session (session : Team_session_types.session) =
  {
    session_id = session.session_id;
    goal = session.goal;
    status = Team_session_types.status_to_string session.status;
    started_at = session.started_at;
    updated_at_iso = session.updated_at_iso;
    last_event_at = Option.map Command_plane_v2.iso_of_unix session.last_event_at;
    last_turn_at = Option.map Command_plane_v2.iso_of_unix session.last_turn_at;
    worker_names = session_worker_names session;
    min_agents_violation_streak = session.min_agents_violation_streak;
    policy_violation_count = List.length session.policy_violations;
  }

