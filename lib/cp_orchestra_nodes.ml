(** Cp_orchestra_nodes — Entity node renderers for CP orchestra graph.

    Each function renders a specific CP entity (namespace, session, operation,
    worker, keeper, etc.) as a graph node with facts and edges.

    @since God file decomposition — extracted from command_plane_orchestra.ml *)

open Cp_orchestra_helpers

let namespace_json config =
  if not (Room.is_initialized config) then
    `Assoc
      [
        ("namespace_id", `String "default");
        ("namespace", `String "default");
        ("namespace_mode", `String "flattened");
        ("project", `String (Filename.basename config.base_path));
        ("cluster", `String (Env_config_core.cluster_name ()));
        ("paused", `Bool false);
        ("pause_reason", `Null);
        ("agent_count", `Int 0);
        ("task_count", `Int 0);
        ("message_count", `Int 0);
      ]
  else
    let state = Room.read_state config in
    let agents = Room.get_agents_raw config in
    let tasks = Room.get_tasks_raw config in
    `Assoc
      [
        ("namespace_id", `String "default");
        ("namespace", `String "default");
        ("namespace_mode", `String "flattened");
        ("project", `String state.project);
        ("cluster", `String (Env_config_core.cluster_name ()));
        ("paused", `Bool state.paused);
        ("pause_reason", json_string_option state.pause_reason);
        ("agent_count", `Int (List.length agents));
        ("task_count", `Int (List.length tasks));
        ("message_count", `Int state.message_seq);
      ]

let namespace_node namespace_json session_count operation_count worker_count keeper_count
    alert_count pending_confirm_count =
  let namespace_id =
    first_some (string_opt namespace_json "namespace_id")
      (string_opt namespace_json "namespace")
    |> Option.value ~default:"default"
  in
  let paused = bool_opt namespace_json "paused" |> Option.value ~default:false in
  let tone = if paused || pending_confirm_count > 0 || alert_count > 0 then "warn" else "ok" in
  node ~id:("namespace:" ^ namespace_id) ~kind:"namespace" ~label:namespace_id
    ?subtitle:(string_opt namespace_json "project")
    ~tone ~provenance:"truth" ~visual_class:"namespace-core" ~glyph:"◎"
    ?pulse:(pulse_of_tone tone)
    ~facts:
      [
        fact "project"
          (string_opt namespace_json "project" |> Option.value ~default:"n/a");
        fact "cluster"
          (string_opt namespace_json "cluster" |> Option.value ~default:"default");
        fact "sessions" (string_of_int session_count);
        fact "operations" (string_of_int operation_count);
        fact "workers" (string_of_int worker_count);
        fact "keepers" (string_of_int keeper_count);
        fact "alerts" (string_of_int alert_count);
        fact "pending confirms" (string_of_int pending_confirm_count);
      ]
    ~link_tab:"command" ~link_surface:"summary" ()

let session_tone (session : Team_session_types.session) status_json =
  let status = Team_session_types.status_to_string session.status in
  match status with
  | "failed" | "cancelled" -> "bad"
  | "paused" | "interrupted" -> "warn"
  | _ ->
      let team_health = assoc_or_empty status_json "team_health" in
      let health_status = string_opt team_health "status" |> Option.value ~default:"ok" in
      if session.min_agents_violation_streak > 0 || session.policy_violations <> [] then "warn"
      else status_tone health_status

let session_node _config (session : Team_session_types.session) =
  let status_json = `Assoc [] in
  let summary = assoc_or_empty status_json "summary" in
  let command_plane = assoc_or_empty status_json "command_plane" in
  let tone = session_tone session status_json in
  let progress =
    float_opt summary "progress_pct"
    |> Option.map (fun value -> Printf.sprintf "%.0f%%" value)
    |> Option.value ~default:"n/a"
  in
  let active_agents =
    int_opt summary "active_agent_count"
    |> Option.map string_of_int
    |> Option.value ~default:(string_of_int (List.length session.agent_names))
  in
  node ~id:("session:" ^ session.session_id) ~kind:"session"
    ~label:session.session_id ~subtitle:session.goal
    ~status:(Team_session_types.status_to_string session.status)
    ~tone ~provenance:"truth" ~visual_class:"session-island" ~glyph:"◈"
    ?pulse:(pulse_of_tone tone)
    ~facts:
      [
        fact "goal" session.goal;
        fact "progress" progress;
        fact "agents" active_agents;
        fact "mode"
          (Team_session_types.orchestration_mode_to_string
             session.orchestration_mode);
        fact "scale"
          (Team_session_types.scale_profile_to_string session.scale_profile);
        fact "operation"
          (string_opt command_plane "operation_id" |> Option.value ~default:"none");
      ]
    ~link_tab:"intervene"
    ~link_params:
      (json_params
         [
           ("target_type", `String "team_session");
           ("target_id", `String session.session_id);
         ])
    ()

let operation_node op_json =
  let operation_id = string_opt op_json "operation_id" |> Option.value ~default:"operation" in
  let status = string_opt op_json "status" |> Option.value ~default:"unknown" in
  let tone = status_tone status in
  node ~id:("operation:" ^ operation_id) ~kind:"operation"
    ~label:operation_id
    ?subtitle:(string_opt op_json "objective")
    ~status ~tone ~provenance:"truth" ~visual_class:"operation-core" ~glyph:"▣"
    ?pulse:(pulse_of_tone tone)
    ~facts:
      [
        fact "unit"
          (string_opt op_json "assigned_unit_id" |> Option.value ~default:"n/a");
        fact "source"
          (string_opt op_json "source" |> Option.value ~default:"managed");
        fact "trace"
          (string_opt op_json "trace_id" |> Option.value ~default:"n/a");
      ]
    ~link_tab:"command" ~link_surface:"operations"
    ~link_params:(json_params [ ("operation_id", `String operation_id) ]) ()

let detachment_node det_json =
  let detachment_id = string_opt det_json "detachment_id" |> Option.value ~default:"detachment" in
  let status = string_opt det_json "status" |> Option.value ~default:"unknown" in
  let tone = status_tone status in
  let roster_count = list_member det_json "roster" |> List.length in
  node ~id:("detachment:" ^ detachment_id) ~kind:"detachment"
    ~label:detachment_id
    ?subtitle:(string_opt det_json "runtime_kind")
    ~status ~tone ~provenance:"truth" ~visual_class:"detachment-shell" ~glyph:"◇"
    ?pulse:(pulse_of_tone tone)
    ~facts:
      [
        fact "operation"
          (string_opt det_json "operation_id" |> Option.value ~default:"n/a");
        fact "session"
          (string_opt det_json "session_id" |> Option.value ~default:"none");
        fact "runtime"
          (string_opt det_json "runtime_kind" |> Option.value ~default:"n/a");
        fact "roster" (string_of_int roster_count);
      ]
    ~link_tab:"command" ~link_surface:"operations"
    ~link_params:(json_params [ ("detachment_id", `String detachment_id) ]) ()

let lane_group_tone workers =
  let joined = ref false in
  let stale = ref false in
  let live = ref false in
  List.iter
    (fun worker_json ->
      if bool_opt worker_json "joined" |> Option.value ~default:false then joined := true;
      if bool_opt worker_json "live_presence" |> Option.value ~default:false then live := true;
      if not (bool_opt worker_json "heartbeat_fresh" |> Option.value ~default:false)
         && not (bool_opt worker_json "completed" |> Option.value ~default:false)
      then stale := true)
    workers;
  if !stale then "warn" else if !joined || !live then "ok" else "warn"

let lane_group_node lane_name workers =
  let tone = lane_group_tone workers in
  let completed =
    List.fold_left
      (fun acc worker_json ->
        if bool_opt worker_json "completed" |> Option.value ~default:false then acc + 1
        else acc)
      0 workers
  in
  node ~id:("lane:" ^ lane_name) ~kind:"lane" ~label:lane_name
    ~subtitle:(Printf.sprintf "%d worker(s)" (List.length workers))
    ~status:"live" ~tone ~provenance:"truth" ~visual_class:"worker-lane"
    ~glyph:"═"
    ?pulse:(Some (if tone = "warn" then "pulse" else "flow"))
    ~facts:
      [
        fact "workers" (string_of_int (List.length workers));
        fact "completed" (string_of_int completed);
      ]
    ~link_tab:"command" ~link_surface:"swarm" ()

let control_lane_node lane_json =
  let lane_id = string_opt lane_json "lane_id" |> Option.value ~default:"lane" in
  let label = string_opt lane_json "label" |> Option.value ~default:lane_id in
  let motion_state = string_opt lane_json "motion_state" |> Option.value ~default:"waiting" in
  let tone =
    if motion_state = "stalled" then "bad"
    else if motion_state = "waiting" then "warn"
    else "ok"
  in
  let counts = assoc_or_empty lane_json "counts" in
  node ~id:("lane:" ^ lane_id) ~kind:"lane" ~label
    ?subtitle:(string_opt lane_json "phase")
    ~status:motion_state ~tone ~provenance:"derived"
    ~visual_class:"control-lane" ~glyph:"═"
    ?pulse:(Some
              (match motion_state with
              | "moving" -> "flow"
              | "stalled" -> "blink"
              | _ -> "pulse"))
    ~facts:
      [
        fact "step"
          (string_opt lane_json "current_step" |> Option.value ~default:"n/a");
        fact "source"
          (string_opt lane_json "source_of_truth" |> Option.value ~default:"derived");
        fact "workers"
          (int_opt counts "workers" |> Option.value ~default:0 |> string_of_int);
        fact "operations"
          (int_opt counts "operations" |> Option.value ~default:0 |> string_of_int);
      ]
    ~link_tab:"command" ~link_surface:"swarm" ()

let actual_worker_node worker_json =
  let name = string_opt worker_json "name" |> Option.value ~default:"worker" in
  let status = string_opt worker_json "status" |> Option.value ~default:"unknown" in
  let tone =
    if not (bool_opt worker_json "joined" |> Option.value ~default:false) then "bad"
    else if not (bool_opt worker_json "heartbeat_fresh" |> Option.value ~default:false)
            && not (bool_opt worker_json "completed" |> Option.value ~default:false)
    then "warn"
    else "ok"
  in
  let lane = string_opt worker_json "lane" in
  node ~id:("worker:" ^ name) ~kind:"worker" ~label:name
    ?subtitle:(string_opt worker_json "role")
    ~status ~tone ~provenance:"truth" ~visual_class:"worker-unit" ~glyph:"●"
    ?pulse:(Some
              (match tone with
              | "bad" -> "blink"
              | "warn" -> "pulse"
              | _ -> "steady"))
    ?lane_id:lane
    ~facts:
      [
        fact "lane" (Option.value ~default:"n/a" lane);
        fact "task"
          (string_opt worker_json "current_task"
           |> first_some (string_opt worker_json "bound_task_title")
           |> first_some (string_opt worker_json "bound_task_id")
           |> Option.value ~default:"none");
        fact "heartbeat"
          (match float_opt worker_json "heartbeat_age_sec" with
          | Some value -> Printf.sprintf "%.0fs" value
          | None ->
              if bool_opt worker_json "heartbeat_fresh" |> Option.value ~default:false then
                "fresh"
              else
                "n/a");
        fact "markers"
          (String.concat "/"
             [
               (if bool_opt worker_json "claim_marker_seen" |> Option.value ~default:false then "claim" else "no-claim");
               (if bool_opt worker_json "done_marker_seen" |> Option.value ~default:false then "done" else "no-done");
               (if bool_opt worker_json "final_marker_seen" |> Option.value ~default:false then "final" else "no-final");
             ]);
      ]
    ~link_tab:"command" ~link_surface:"swarm" ()

let ghost_worker_id session_id label =
  let digest = Digestif.SHA1.(to_hex (digest_string label)) in
  "ghost:" ^ session_id ^ ":" ^ String.sub digest 0 (min 40 (String.length digest))

let ghost_worker_node ~session_id ~label ~subtitle ?lane_id () =
  node ~id:(ghost_worker_id session_id label) ~kind:"worker" ~label
    ~subtitle ~status:"planned" ~tone:"warn" ~provenance:"derived"
    ~visual_class:"worker-ghost" ~glyph:"◌" ?lane_id
    ~parent_id:("session:" ^ session_id)
    ?pulse:(Some "pulse")
    ~facts:[ fact "session" session_id; fact "state" "planned" ]
    ~link_tab:"intervene"
    ~link_params:
      (json_params
         [ ("target_type", `String "team_session"); ("target_id", `String session_id) ])
    ()

let keeper_node row =
  let name = string_opt row "name" |> Option.value ~default:"keeper" in
  let runtime_class = string_opt row "runtime_class" in
  let status = string_opt row "status" |> Option.value ~default:"unknown" in
  let tone =
    if status = "offline" || status = "inactive" || status = "error" then "bad"
    else
      match float_opt row "context_ratio" with
      | Some ratio when ratio >= 0.8 -> "warn"
      | _ -> status_tone status
  in
  node ~id:("keeper:" ^ name) ~kind:"keeper" ~label:name
    ?subtitle:runtime_class ~status ~tone ~provenance:"truth"
    ~visual_class:"continuity-keeper" ~glyph:"✦"
    ?pulse:(pulse_of_tone tone)
    ~facts:
      [
        fact "agent"
          (string_opt row "agent_name" |> Option.value ~default:"n/a");
        fact "context"
          (match float_opt row "context_ratio" with
          | Some value -> Printf.sprintf "%.0f%%" (value *. 100.)
          | None -> "n/a");
      ]
    ~link_tab:"intervene"
    ~link_params:
      (json_params [ ("target_type", `String "keeper"); ("target_id", `String name) ])
    ()

let signal_for_pending_confirms summary room_id =
  let total = int_opt summary "total_count" |> Option.value ~default:0 in
  if total <= 0 then
    None
  else
    let visible = int_opt summary "visible_count" |> Option.value ~default:total in
    let hidden = int_opt summary "hidden_count" |> Option.value ~default:0 in
    let detail =
      if hidden > 0 then
        Printf.sprintf "%d visible / %d total pending confirms" visible total
      else
        Printf.sprintf "%d pending confirms require operator action" total
    in
    Some
      (signal ~id:"signal:pending-confirms" ~kind:"pending_confirm"
         ~label:"승인 대기" ~detail ~tone:"warn" ~source_id:room_id
         ~suggested_surface:"intervene" ())

let signal_for_runtime_blocker swarm_json room_id =
  let provider = assoc_or_empty swarm_json "provider" in
  match string_opt provider "runtime_blocker" with
  | Some blocker ->
      Some
        (signal ~id:"signal:runtime-blocker" ~kind:"runtime_blocker"
           ~label:"런타임 막힘" ~detail:blocker ~tone:"bad" ~source_id:room_id
           ~suggested_surface:"swarm" ())
  | None -> None

let signal_for_hot_proof summary_json room_id =
  let proof = assoc_or_empty summary_json "swarm_proof" in
  match string_opt proof "status" with
  | Some "present" when bool_opt proof "pass" = Some true -> None
  | Some status ->
      let tone =
        match bool_opt proof "pass" with
        | Some false -> "bad"
        | _ -> if status = "missing" then "warn" else "warn"
      in
      let detail =
        string_opt proof "missing_reason"
        |> Option.value ~default:
             (Printf.sprintf "proof status=%s" status)
      in
      Some
        (signal ~id:"signal:hot-proof" ~kind:"hot_proof" ~label:"Hot proof"
           ~detail ~tone ~source_id:room_id ~suggested_surface:"swarm" ())
  | None -> None

let signals_for_alerts alerts room_id =
  alerts
  |> List.filter_map (fun row ->
         let severity = string_opt row "severity" |> Option.value ~default:"warn" in
         let title = string_opt row "title" |> Option.value ~default:"Alert" in
         let detail = string_opt row "detail" in
         let alert_id = string_opt row "alert_id" |> Option.value ~default:title in
         Some
           (signal ~id:("signal:alert:" ^ alert_id) ~kind:"alert" ~label:title
              ?detail ~tone:(status_tone severity) ~source_id:room_id
              ~suggested_surface:"alerts" ()))

let string_assoc_list json =
  match json with
  | `Assoc fields -> fields
  | _ -> []

let json_assoc_of_fields fields = `Assoc fields
