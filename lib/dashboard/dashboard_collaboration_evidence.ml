let string_member_opt key json =
  match Yojson.Safe.Util.member key json with
  | `String value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let count_event_type events event_type =
  List.fold_left
    (fun acc json ->
      match Yojson.Safe.Util.member "event_type" json with
      | `String value when String.equal value event_type -> acc + 1
      | _ -> acc)
    0 events

let actor_of_session_event json =
  string_member_opt "actor" (Yojson.Safe.Util.member "detail" json)

let summary_of_session_event json =
  let detail = Yojson.Safe.Util.member "detail" json in
  match
    ( string_member_opt "message" detail,
      string_member_opt "result" detail,
      string_member_opt "task_title" detail,
      string_member_opt "kind" detail )
  with
  | Some value, _, _, _ -> value
  | None, Some value, _, _ -> value
  | None, None, Some value, _ -> value
  | None, None, None, Some value -> value
  | _ -> "session event"

let relation_backend_status () =
  match Sys.getenv_opt "GRAPHQL_URL" with
  | None | Some "" -> "disabled"
  | Some value when String.ends_with ~suffix:":9/graphql" value -> "disabled"
  | Some _ -> "configured"

let artifact_ref_json ~kind path =
  `Assoc
    [
      ("kind", `String kind);
      ("path", `String path);
      ("exists", `Bool (Sys.file_exists path));
    ]

let route_ref_json ~label value =
  `Assoc [ ("kind", `String "route"); ("label", `String label); ("value", `String value) ]

let unique_non_empty values =
  values
  |> List.filter (fun value -> String.trim value <> "")
  |> List.sort_uniq String.compare

let current_time_ms () = int_of_float (Time_compat.now () *. 1000.0)

let take_last n items =
  let total = List.length items in
  if n <= 0 || total <= n then
    items
  else
    let rec drop remaining xs =
      if remaining <= 0 then xs
      else
        match xs with
        | [] -> []
        | _ :: rest -> drop (remaining - 1) rest
    in
    drop (total - n) items

let activity_events_for_room_window config ~room_id ~started_ms ~ended_ms =
  Activity_graph.list_events config ~room_id ~after_seq:0 ~limit:2000 ()
  |> List.filter (fun (event : Activity_graph.event) ->
         event.ts_ms >= started_ms && event.ts_ms <= ended_ms)

let build_recent_session_events events =
  let recent = take_last 8 events in
  `List
    (List.map
       (fun json ->
         `Assoc
           [
             ( "ts_iso",
               match string_member_opt "ts_iso" json with
               | Some value -> `String value
               | None -> `Null );
             ( "event_type",
               match string_member_opt "event_type" json with
               | Some value -> `String value
               | None -> `String "unknown" );
             ( "actor",
               match actor_of_session_event json with
               | Some value -> `String value
               | None -> `Null );
             ("summary", `String (summary_of_session_event json));
           ])
       recent)

let json ?session_id ?room_id ~(config : Room.config) () =
  let selected_session =
    match session_id with
    | Some value -> Team_session_store.load_session config value
    | None -> (
        match Team_session_store.list_sessions ~limit:1 config with
        | session :: _ -> Some session
        | [] -> None)
  in
  let selected_room_id =
    match selected_session, room_id with
    | Some session, _ -> session.room_id
    | None, Some value when String.trim value <> "" -> String.trim value
    | _ -> "default"
  in
  let session_events =
    match selected_session with
    | Some session -> Team_session_store.read_events config session.session_id
    | None -> []
  in
  let started_ms, ended_ms =
    match selected_session with
    | Some session ->
        let ended_at =
          Option.value session.stopped_at ~default:(Time_compat.now ())
        in
        ( int_of_float (session.started_at *. 1000.0),
          int_of_float (ended_at *. 1000.0) )
    | None ->
        let now_ms = current_time_ms () in
        (now_ms - (24 * 60 * 60 * 1000), now_ms)
  in
  let activity_events =
    activity_events_for_room_window config ~room_id:selected_room_id ~started_ms
      ~ended_ms
  in
  let team_turn_count = count_event_type session_events "team_turn" in
  let session_broadcast_count =
    match selected_session with Some session -> session.broadcast_count | None -> 0
  in
  let portal_count =
    match selected_session with Some session -> session.portal_count | None -> 0
  in
  let mention_count =
    List.length
      (List.filter
         (fun (event : Activity_graph.event) ->
           String.equal event.kind "message.mentioned")
         activity_events)
  in
  let message_broadcast_count =
    List.length
      (List.filter
         (fun (event : Activity_graph.event) ->
           String.equal event.kind "message.broadcast")
         activity_events)
  in
  let board_interaction_count =
    List.length
      (List.filter
         (fun (event : Activity_graph.event) ->
           List.mem event.kind [ "board.posted"; "board.commented"; "board.voted" ])
         activity_events)
  in
  let unique_actor_count =
    unique_non_empty
      (List.filter_map actor_of_session_event session_events
      @ List.filter_map
          (fun (event : Activity_graph.event) ->
            Option.map
              (fun (actor : Activity_graph.entity_ref) -> actor.id)
              event.actor)
          activity_events)
    |> List.length
  in
  let proof_json =
    match selected_session with
    | Some session -> Some (Dashboard_proof.json ~config ~session_id:session.session_id ())
    | None -> None
  in
  let proof_verdict =
    match proof_json with
    | Some json -> string_member_opt "proof_verdict" json
    | None -> None
  in
  let proof_available =
    match proof_json with
    | Some json -> (
        match Yojson.Safe.Util.member "summary" json with
        | `Assoc _ -> true
        | _ -> false)
    | None -> false
  in
  let interaction_event_count =
    team_turn_count + session_broadcast_count + portal_count + mention_count
    + board_interaction_count
  in
  let evidence_status, headline, detail =
    if proof_available && interaction_event_count > 0 then
      ( "strong",
        "세션 기준 협업 근거가 있습니다.",
        "team_turn, broadcast/portal, activity 이벤트, proof 경로를 함께 확인할 수 있습니다." )
    else if interaction_event_count > 0 || message_broadcast_count > 0 then
      ( "partial",
        "상호작용 흔적은 있지만 증거가 분산돼 있습니다.",
        "세션 이벤트나 room activity는 보이지만 proof 또는 관계 근거가 충분히 묶이지 않았습니다." )
    else
      ( "missing",
        "기록된 협업 근거가 아직 약합니다.",
        "session turns, mentions, board interaction, proof 문서 중 확인 가능한 항목이 거의 없습니다." )
  in
  let session_json =
    match selected_session with
    | Some session ->
        `Assoc
          [
            ("session_id", `String session.session_id);
            ("goal", `String session.goal);
            ("status", `String (Team_session_types.status_to_string session.status));
            ("room_id", `String session.room_id);
            ("communication_mode", `String (Team_session_types.communication_mode_to_string session.communication_mode));
          ]
    | None -> `Null
  in
  let artifact_refs =
    match selected_session with
    | Some session ->
        `List
          [
            artifact_ref_json ~kind:"report_json" (Team_session_store.report_json_path config session.session_id);
            artifact_ref_json ~kind:"report_md" (Team_session_store.report_md_path config session.session_id);
            artifact_ref_json ~kind:"proof_json" (Team_session_store.proof_json_path config session.session_id);
            artifact_ref_json ~kind:"proof_md" (Team_session_store.proof_md_path config session.session_id);
          ]
    | None -> `List []
  in
  let refs_json =
    `List
      (([
          route_ref_json ~label:"dashboard_collaboration_evidence"
            "/api/v1/dashboard/collaboration-evidence";
          route_ref_json ~label:"dashboard_logs" "/api/v1/dashboard/logs";
          route_ref_json ~label:"prometheus_metrics" "/metrics";
        ]
       @
       match selected_session with
       | Some session ->
           [
             route_ref_json ~label:"dashboard_proof"
               ("/api/v1/dashboard/proof?session_id=" ^ session.session_id);
           ]
       | None -> []))
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("evidence_status", `String evidence_status);
      ("headline", `String headline);
      ("detail", `String detail);
      ("session", session_json);
      ("room_id", `String selected_room_id);
      ( "counts",
        `Assoc
          [
            ("team_turn_count", `Int team_turn_count);
            ("session_broadcast_count", `Int session_broadcast_count);
            ("portal_count", `Int portal_count);
            ("message_broadcast_count", `Int message_broadcast_count);
            ("mention_count", `Int mention_count);
            ("board_interaction_count", `Int board_interaction_count);
            ("interaction_event_count", `Int interaction_event_count);
            ("unique_actor_count", `Int unique_actor_count);
          ] );
      ( "proof",
        `Assoc
          [
            ("available", `Bool proof_available);
            ("verdict", Json_util.string_opt_to_json proof_verdict);
          ] );
      ( "relation_backend",
        `Assoc
          [
            ("source", `String "graphql_proxy");
            ("status", `String (relation_backend_status ()));
          ] );
      ("refs", refs_json);
      ("artifacts", artifact_refs);
      ("recent_events", build_recent_session_events session_events);
    ]
