module U = Yojson.Safe.Util

let trim_to_option = Dashboard_utils.trim_to_option

let first_some = Dashboard_utils.first_some

let string_opt json key =
  match U.member key json with
  | `String value -> trim_to_option value
  | _ -> None

let int_opt json key =
  match U.member key json with
  | `Int value -> Some value
  | `Intlit value -> (try Some (int_of_string value) with Failure _ -> None)
  | `Float value -> Some (int_of_float value)
  | _ -> None

let float_opt json key =
  match U.member key json with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | `Intlit value -> (try Some (float_of_string value) with Failure _ -> None)
  | _ -> None

let bool_opt json key =
  match U.member key json with
  | `Bool value -> Some value
  | _ -> None

let list_member json key =
  match U.member key json with
  | `List rows -> rows
  | _ -> []

let assoc_or_empty json key =
  match U.member key json with
  | `Assoc _ as value -> value
  | _ -> `Assoc []

let json_string_option = function
  | Some value -> `String value
  | None -> `Null

let json_int_option = function
  | Some value -> `Int value
  | None -> `Null

let json_float_option = function
  | Some value -> `Float value
  | None -> `Null

let json_params fields = `Assoc fields

let fact label value =
  `Assoc [ ("label", `String label); ("value", `String value) ]

let node ?subtitle ?status ?pulse ?parent_id ?lane_id ?link_tab ?link_surface
    ?(link_params = `Assoc []) ~id ~kind ~label ~tone ~provenance ~visual_class
    ~glyph ~facts () =
  `Assoc
    [
      ("id", `String id);
      ("kind", `String kind);
      ("label", `String label);
      ("subtitle", json_string_option subtitle);
      ("status", json_string_option status);
      ("tone", `String tone);
      ("pulse", json_string_option pulse);
      ("provenance", `String provenance);
      ("visual_class", `String visual_class);
      ("glyph", `String glyph);
      ("parent_id", json_string_option parent_id);
      ("lane_id", json_string_option lane_id);
      ("link_tab", json_string_option link_tab);
      ("link_surface", json_string_option link_surface);
      ("link_params", link_params);
      ("facts", `List facts);
    ]

let edge ?label ?(tone = "ok") ?(provenance = "derived") ?(animated = false)
    ~id ~source ~target ~kind () =
  `Assoc
    [
      ("id", `String id);
      ("source", `String source);
      ("target", `String target);
      ("kind", `String kind);
      ("label", json_string_option label);
      ("tone", `String tone);
      ("provenance", `String provenance);
      ("animated", `Bool animated);
    ]

let signal ?detail ?source_id ?target_id ?suggested_surface
    ?(suggested_params = `Assoc []) ?(provenance = "derived") ~id ~kind ~label
    ~tone () =
  `Assoc
    [
      ("id", `String id);
      ("kind", `String kind);
      ("label", `String label);
      ("detail", json_string_option detail);
      ("tone", `String tone);
      ("provenance", `String provenance);
      ("source_id", json_string_option source_id);
      ("target_id", json_string_option target_id);
      ("suggested_surface", json_string_option suggested_surface);
      ("suggested_params", suggested_params);
    ]

let status_tone = function
  | "failed" | "error" | "cancelled" | "offline" | "stalled" | "bad" -> "bad"
  | "paused" | "interrupted" | "warn" | "waiting" | "degraded" -> "warn"
  | _ -> "ok"

let pulse_of_tone = function
  | "bad" -> Some "blink"
  | "warn" -> Some "pulse"
  | _ -> Some "steady"

let room_json config =
  if not (Room.is_initialized config) then
    `Assoc
      [
        ("room_id", `String "default");
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
        ("room_id", `String (Option.value ~default:"default" (Room.read_current_room config)));
        ("project", `String state.project);
        ("cluster", `String (Env_config_core.cluster_name ()));
        ("paused", `Bool state.paused);
        ("pause_reason", json_string_option state.pause_reason);
        ("agent_count", `Int (List.length agents));
        ("task_count", `Int (List.length tasks));
        ("message_count", `Int state.message_seq);
      ]

let room_node room_json session_count operation_count worker_count keeper_count
    alert_count pending_confirm_count =
  let room_id = string_opt room_json "room_id" |> Option.value ~default:"default" in
  let paused = bool_opt room_json "paused" |> Option.value ~default:false in
  let tone = if paused || pending_confirm_count > 0 || alert_count > 0 then "warn" else "ok" in
  node ~id:("room:" ^ room_id) ~kind:"room" ~label:room_id
    ?subtitle:(string_opt room_json "project")
    ~tone ~provenance:"truth" ~visual_class:"room-core" ~glyph:"◎"
    ?pulse:(pulse_of_tone tone)
    ~facts:
      [
        fact "project"
          (string_opt room_json "project" |> Option.value ~default:"n/a");
        fact "cluster"
          (string_opt room_json "cluster" |> Option.value ~default:"default");
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

let session_node config (session : Team_session_types.session) =
  let status_json = Team_session_engine_eio.session_status_json config session in
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

let by_id rows key_field =
  rows
  |> List.filter_map (fun row ->
         match string_opt row key_field with
         | Some key -> Some (key, row)
         | None -> None)

let json ?run_id:_ ?operation_id:_ (ctx : _ Operator_control.context) =
  let config = ctx.config in
  let actor = ctx.agent_name in
  let room = room_json config in
  let room_id = "room:" ^ (string_opt room "room_id" |> Option.value ~default:"default") in
  let operator_snapshot = Operator_control.snapshot_json ~actor ctx in
  let pending_summary =
    assoc_or_empty operator_snapshot "pending_confirm_summary"
  in
  let keepers =
    list_member (assoc_or_empty operator_snapshot "keepers") "items"
    @ list_member (assoc_or_empty operator_snapshot "persistent_agents") "items"
  in
  let sessions = Team_session_store.list_sessions config in
  let summary_json = Command_plane_v2.summary_json config in
  let alerts_json = Command_plane_v2.list_alerts_json config in
  let alerts = list_member alerts_json "alerts" in
  let swarm_status_json =
    if Room.is_initialized config then
      Swarm_status.build_json config
    else
      Swarm_status.empty_json
  in
  let swarm_json = `Assoc [] in
  let operations_json = Command_plane_v2.operation_status_json config () in
  let operation_rows =
    list_member operations_json "operations"
    |> List.filter_map (fun row ->
           match U.member "operation" row with
           | `Assoc _ as op -> Some op
           | _ -> None)
  in
  let active_operation_rows =
    operation_rows
    |> List.filter (fun op ->
           let status = string_opt op "status" |> Option.value ~default:"active" in
           not (Dashboard_utils.is_session_terminal status))
  in
  let detachments_json = Command_plane_v2.list_detachments_json config in
  let detachment_rows =
    list_member detachments_json "detachments"
    |> List.filter_map (fun row ->
           match U.member "detachment" row with
           | `Assoc _ as det -> Some det
           | _ -> None)
  in
  let active_detachment_rows =
    detachment_rows
    |> List.filter (fun det ->
           let status = string_opt det "status" |> Option.value ~default:"active" in
           not (Dashboard_utils.is_session_terminal status
                || status = "stopped"))
  in
  let swarm_workers = list_member swarm_json "workers" in
  let actual_worker_names =
    swarm_workers
    |> List.filter_map (fun row -> string_opt row "name")
  in
  let actual_worker_name_set = actual_worker_names |> List.sort_uniq String.compare in
  let worker_lanes =
    swarm_workers
    |> List.fold_left
         (fun acc row ->
           let lane = string_opt row "lane" |> Option.value ~default:"swarm" in
           let existing = List.assoc_opt lane acc |> Option.value ~default:[] in
           (lane, row :: existing) :: List.remove_assoc lane acc)
         []
    |> List.map (fun (lane, rows) -> (lane, List.rev rows))
    |> List.sort (fun (left, _) (right, _) -> String.compare left right)
  in
  let session_nodes = List.map (session_node config) sessions in
  let operation_nodes = List.map operation_node active_operation_rows in
  let detachment_nodes = List.map detachment_node active_detachment_rows in
  let lane_nodes =
    if worker_lanes <> [] then
      List.map (fun (lane_name, rows) -> lane_group_node lane_name rows) worker_lanes
    else
      list_member swarm_status_json "lanes"
      |> List.filter (fun row -> bool_opt row "present" |> Option.value ~default:false)
      |> List.map control_lane_node
  in
  let actual_worker_nodes = List.map actual_worker_node swarm_workers in
  let ghost_worker_nodes =
    sessions
    |> List.concat_map (fun (session : Team_session_types.session) ->
           let planned =
             if session.planned_workers <> [] then
               session.planned_workers
               |> List.map (fun (worker : Team_session_types.planned_worker) ->
                      let label =
                        match worker.runtime_actor, worker.spawn_role with
                        | Some actor, _ when String.trim actor <> "" -> String.trim actor
                        | _, Some role when String.trim role <> "" -> String.trim role
                        | _ -> worker.spawn_agent
                      in
                      ( label,
                        Option.value ~default:"planned" worker.spawn_role,
                        worker.lane_id ) )
             else
               session.agent_names
               |> List.map (fun name -> (name, "participant", None))
           in
           planned
           |> List.filter (fun (label, _, _) -> not (List.mem label actual_worker_name_set))
           |> List.map (fun (label, subtitle, lane_id) ->
                  ghost_worker_node ~session_id:session.session_id ~label
                    ~subtitle ?lane_id ()))
  in
  let keeper_nodes = List.map keeper_node keepers in
  let nodes =
    room_node room (List.length sessions) (List.length active_operation_rows)
      (List.length actual_worker_nodes + List.length ghost_worker_nodes)
      (List.length keeper_nodes) (List.length alerts)
      (int_opt pending_summary "total_count" |> Option.value ~default:0)
    :: session_nodes @ operation_nodes @ detachment_nodes @ lane_nodes
       @ actual_worker_nodes @ ghost_worker_nodes @ keeper_nodes
  in
  let operation_rows_by_id = by_id active_operation_rows "operation_id" in
  let detachment_rows_by_id = by_id active_detachment_rows "detachment_id" in
  let edges =
    (sessions
    |> List.map (fun (session : Team_session_types.session) ->
           edge ~id:("edge:room-session:" ^ session.session_id) ~source:room_id
             ~target:("session:" ^ session.session_id) ~kind:"contains"
             ~label:"session" ~provenance:"truth" ())
    )
    @ (sessions
      |> List.filter_map (fun (session : Team_session_types.session) ->
             match session.operation_id with
             | Some operation_id
               when List.mem_assoc operation_id operation_rows_by_id ->
                 Some
                   (edge
                      ~id:("edge:session-operation:" ^ session.session_id ^ ":" ^ operation_id)
                      ~source:("session:" ^ session.session_id)
                      ~target:("operation:" ^ operation_id) ~kind:"attached"
                      ~label:"operation" ~provenance:"truth" ())
             | _ -> None))
    @ (active_detachment_rows
      |> List.filter_map (fun det ->
             match string_opt det "operation_id" with
             | Some operation_id
               when List.mem_assoc operation_id operation_rows_by_id ->
                 let detachment_id =
                   string_opt det "detachment_id" |> Option.value ~default:"detachment"
                 in
                 Some
                   (edge
                      ~id:("edge:operation-detachment:" ^ operation_id ^ ":" ^ detachment_id)
                      ~source:("operation:" ^ operation_id)
                      ~target:("detachment:" ^ detachment_id) ~kind:"materializes"
                      ~label:"detachment" ~provenance:"truth" ())
             | _ -> None))
    @ (if worker_lanes <> [] then
         let lane_parent =
           match string_opt (assoc_or_empty swarm_json "detachment") "detachment_id" with
           | Some detachment_id when List.mem_assoc detachment_id detachment_rows_by_id ->
               "detachment:" ^ detachment_id
           | _ -> (
               match string_opt (assoc_or_empty swarm_json "operation") "operation_id" with
               | Some operation_id when List.mem_assoc operation_id operation_rows_by_id ->
                   "operation:" ^ operation_id
               | _ -> room_id)
         in
         (worker_lanes
         |> List.map (fun (lane_name, _rows) ->
                edge ~id:("edge:parent-lane:" ^ lane_name) ~source:lane_parent
                  ~target:("lane:" ^ lane_name) ~kind:"routes"
                  ~label:"lane" ~tone:"ok" ~animated:true ~provenance:"truth"
                  ()))
         @ (worker_lanes
           |> List.concat_map (fun (lane_name, rows) ->
                  rows
                  |> List.filter_map (fun row ->
                         match string_opt row "name" with
                         | Some name ->
                             Some
                               (edge
                                  ~id:("edge:lane-worker:" ^ lane_name ^ ":" ^ name)
                                  ~source:("lane:" ^ lane_name)
                                  ~target:("worker:" ^ name) ~kind:"feeds"
                                  ~label:"worker" ~animated:true
                                  ~provenance:"truth" ())
                         | None -> None)))
       else
         [])
    @ (ghost_worker_nodes
      |> List.filter_map (fun node_json ->
             match string_opt node_json "id", string_opt node_json "parent_id" with
             | Some worker_id, Some parent_id ->
                 Some
                   (edge ~id:("edge:session-ghost:" ^ worker_id) ~source:parent_id
                      ~target:worker_id ~kind:"planned" ~label:"planned worker"
                      ~tone:"warn" ~animated:false ~provenance:"derived" ())
             | _ -> None))
    @ (keeper_nodes
      |> List.filter_map (fun keeper_json ->
             match string_opt keeper_json "id" with
             | Some keeper_id ->
                 Some
                   (edge ~id:("edge:room-keeper:" ^ keeper_id) ~source:room_id
                      ~target:keeper_id ~kind:"continuity" ~label:"keeper"
                      ~provenance:"truth" ())
             | None -> None))
  in
  let signals =
    List.filter_map Fun.id
      [
        signal_for_pending_confirms pending_summary room_id;
        signal_for_runtime_blocker swarm_json room_id;
        signal_for_hot_proof summary_json room_id;
      ]
    @ signals_for_alerts alerts room_id
  in
  let focus =
    match List.find_opt (fun signal_json -> string_opt signal_json "tone" = Some "bad") signals with
    | Some signal_json ->
        `Assoc
          [
            ("target_kind", `String "signal");
            ( "target_id",
              `String
                (string_opt signal_json "id"
                |> Option.value ~default:"signal:unknown") );
            ( "label",
              `String
                (string_opt signal_json "label"
                |> Option.value ~default:"Signal") );
            ( "reason",
              `String
                (string_opt signal_json "detail"
                |> Option.value ~default:"Critical orchestra signal") );
            ( "suggested_surface",
              json_string_option (string_opt signal_json "suggested_surface") );
            ("suggested_params", assoc_or_empty signal_json "suggested_params");
          ]
    | None -> (
        match
          List.find_opt
            (fun node_json ->
              string_opt node_json "kind" = Some "session"
              && string_opt node_json "tone" <> Some "ok")
            nodes
        with
        | Some node_json ->
            `Assoc
              [
                ("target_kind", `String "node");
                ("target_id", `String (string_opt node_json "id" |> Option.value ~default:room_id));
                ("label", `String (string_opt node_json "label" |> Option.value ~default:"session"));
                ("reason", `String "A session needs supervision or is not fully healthy.");
                ("suggested_surface", `String "intervene");
                ("suggested_params", assoc_or_empty node_json "link_params");
              ]
        | None ->
            `Assoc
              [
                ("target_kind", `String "node");
                ("target_id", `String room_id);
                ("label", `String (string_opt room "room_id" |> Option.value ~default:"default"));
                ("reason", `String "Room-wide view is healthy enough; start from the command overview.");
                ("suggested_surface", `String "summary");
                ("suggested_params", `Assoc []);
              ])
  in
  `Assoc
    [
      ("version", `String "orchestra.v1");
      ("generated_at", `String (Types.now_iso ()));
      ("room", room);
      ( "summary",
        `Assoc
          [
            ("session_count", `Int (List.length sessions));
            ("operation_count", `Int (List.length active_operation_rows));
            ("detachment_count", `Int (List.length active_detachment_rows));
            ("lane_count", `Int (List.length lane_nodes));
            ( "worker_count",
              `Int (List.length actual_worker_nodes + List.length ghost_worker_nodes) );
            ("keeper_count", `Int (List.length keeper_nodes));
            ("signal_count", `Int (List.length signals));
            ("alert_count", `Int (List.length alerts));
          ] );
      ("nodes", `List nodes);
      ("edges", `List edges);
      ("signals", `List signals);
      ("focus", focus);
      ("swarm_status", swarm_status_json);
      ("swarm_proof", assoc_or_empty summary_json "swarm_proof");
      ("truth_notes", `List [ `String "room-wide orchestra map is composed from command-plane truth, swarm live state, and operator read models."; `String "provenance marks whether a node or signal is truth, derived, or fallback."; ]);
    ]
