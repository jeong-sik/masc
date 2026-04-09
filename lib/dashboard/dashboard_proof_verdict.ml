(** Dashboard proof verdict — verdict computation, timeline assembly, and
    session summary for evidence-first collaboration proof projection. *)

include Dashboard_proof_helpers

let timeline_json ?session_id ?operation_id events cp_events =
  let session_items =
    events
    |> List.mapi (fun idx json ->
           let event_type = string_field "event_type" json |> Option.value ~default:"event" in
           let timestamp = string_field "ts_iso" json |> Option.value ~default:(Types.now_iso ()) in
           let actor = Dashboard_proof_events.event_actor json in
           `Assoc
             [
               ("id", `String (Printf.sprintf "session-%04d" (idx + 1)));
               ("seq", `Int (idx + 1));
               ("source", `String "team_session");
               ("session_id", Json_util.string_opt_to_json session_id);
               ("operation_id", Json_util.string_opt_to_json operation_id);
               ("event_type", `String event_type);
               ("timestamp", `String timestamp);
               ("actor", Json_util.string_opt_to_json actor);
               ("summary", `String (Dashboard_proof_events.event_summary json));
               ("detail", detail_of_event json);
             ])
  in
  let cp_items =
    match U.member "events" cp_events with
    | `List items ->
        items
        |> List.mapi (fun idx event ->
               let event_type = string_field "event_type" event |> Option.value ~default:"trace" in
               let timestamp = string_field "timestamp" event |> Option.value ~default:(Types.now_iso ()) in
               `Assoc
                 [
                   ("id", `String (Printf.sprintf "cp-%04d" (idx + 1)));
                   ("seq", `Int (List.length events + idx + 1));
                   ("source", `String "command_plane");
                   ("session_id", Json_util.string_opt_to_json session_id);
                   ( "operation_id",
                     Json_util.string_opt_to_json
                       (string_field "operation_id" event |> option_or_else (fun () -> operation_id)) );
                   ("event_type", `String event_type);
                   ("timestamp", `String timestamp);
                   ("actor", Json_util.string_opt_to_json (string_field "actor" event));
                   ("summary", `String (Dashboard_proof_events.event_summary event));
                   ("detail", match U.member "detail" event with `Assoc _ as detail -> detail | _ -> `Assoc []);
                 ])
    | _ -> []
  in
  let timestamp_of_item json =
    match string_field "timestamp" json with
    | Some value -> Room.parse_iso_time_opt value
    | None -> None
  in
  let seq_of_item ~fallback json =
    match U.member "seq" json with
    | `Int value -> value
    | `Intlit value -> (match int_of_string_opt value with Some v -> v | None -> fallback)
    | _ -> fallback
  in
  let compare_items (left_idx, left) (right_idx, right) =
    match timestamp_of_item left, timestamp_of_item right with
    | Some left_ts, Some right_ts ->
        let cmp = Float.compare left_ts right_ts in
        if cmp <> 0 then cmp
        else compare (seq_of_item ~fallback:left_idx left) (seq_of_item ~fallback:right_idx right)
    | Some _, None -> -1
    | None, Some _ -> 1
    | None, None ->
        compare (seq_of_item ~fallback:left_idx left) (seq_of_item ~fallback:right_idx right)
  in
  session_items @ cp_items
  |> List.mapi (fun idx item -> (idx, item))
  |> List.sort compare_items
  |> List.map snd
  |> fun items -> `List items

let artifact_ref_json kind path =
  `Assoc
    [
      ("kind", `String kind);
      ("path", `String path);
      ("exists", `Bool (Sys.file_exists path));
    ]

let proof_verdict ~active_actor_count ~interaction_present ~evidence_present
    ~artifact_present ~validated_worker_run_count =
  if active_actor_count >= 2 && interaction_present && evidence_present
     && artifact_present && validated_worker_run_count > 0
  then
    "proven"
  else if active_actor_count >= 1
          && (interaction_present || evidence_present || artifact_present)
  then
    "partial"
  else
    "insufficient"

let canonicalize_historical_verdict = function
  | "proved" | "proved_strong" -> Some "proven"
  | "insufficient_evidence" | "insufficient_evidence_strong" -> Some "insufficient"
  | "partial" -> Some "partial"
  | _ -> None

let historical_verdict_of_proof_doc proof_doc =
  match string_field "verdict" proof_doc with
  | Some value -> canonicalize_historical_verdict value
  | None -> None

let combine_verdicts ~live_verdict ~historical_verdict =
  match live_verdict, historical_verdict with
  | "proven", Some "proven" -> ("proven", "live_and_historical")
  | "proven", _ -> ("proven", "live")
  | "partial", _ -> ("partial", "live")
  | "insufficient", Some "proven" -> ("partial", "historical_only")
  | "insufficient", _ -> ("insufficient", "live")
  | other, _ -> (other, "live")

let cp_backing_json config operation_id =
  let traces = Cp_snapshot.list_traces_json config ~operation_id ~limit:20 () in
  let detachments = Cp_snapshot.list_detachments_json ~operation_id config in
  let summary = Cp_snapshot.summary_json config in
  `Assoc
    [
      ("operation_id", `String operation_id);
      ("detachment_id", `String operation_id);
      ("traces", traces);
      ("detachments", detachments);
      ("summary", summary);
      ("swarm_proof", U.member "swarm_proof" summary);
    ]

let session_summary_json session verdict ~planned_actor_count ~active_actor_count
    ~mentioned_actor_count ~unanswered_actor_count ~interaction_count
    ~evidence_count ~cp_trace_count ~raw_trace_run_count
    ~validated_worker_run_count ~live_verdict ~historical_verdict
    ~verdict_basis =
  let detail_with_history base_detail =
    match historical_verdict, live_verdict, verdict_basis with
    | Some "proven", "insufficient", "historical_only" ->
        base_detail
        ^ " 과거 proof 기록은 proved였으나 현재 live evidence가 부족하거나 오래됨."
    | Some "proven", "partial", _ ->
        base_detail
        ^ " 과거 proof가 현재 live evidence보다 강해서 partial로 유지."
    | Some historical, _, _ when not (String.equal historical live_verdict) ->
        base_detail
        ^ Printf.sprintf " 과거 proof=%s, 현재 live verdict=%s." historical
          live_verdict
    | _ -> base_detail
  in
  match session with
  | None ->
      `Assoc
        [
          ("headline", `String "선택된 협업 세션이 없습니다.");
          ("detail", `String "session_id를 제공하거나 team session을 시작해서 근거를 쌓으세요.");
          ("verdict", `String verdict);
          ("live_verdict", `String live_verdict);
          ("historical_verdict", Json_util.string_opt_to_json historical_verdict);
          ("verdict_basis", `String verdict_basis);
          ("actors_count", `Int active_actor_count);
          ("planned_actor_count", `Int planned_actor_count);
          ("mentioned_actor_count", `Int mentioned_actor_count);
          ("unanswered_actor_count", `Int unanswered_actor_count);
          ("interaction_count", `Int interaction_count);
          ("evidence_count", `Int evidence_count);
          ("cp_trace_count", `Int cp_trace_count);
          ("raw_trace_run_count", `Int raw_trace_run_count);
          ("validated_worker_run_count", `Int validated_worker_run_count);
        ]
  | Some session ->
      let headline =
        Printf.sprintf "'%s'에서 %d명이 실제 흔적을 남겼습니다."
          (truncate_preview ~max_len:100 session.Team_session_types.goal)
          active_actor_count
      in
      let detail =
        if unanswered_actor_count > 0 then
          Printf.sprintf
            "%d명이 호출되었으나 아직 응답/도구 증거 없음. 상호작용=%d, backing trace=%d."
            unanswered_actor_count interaction_count cp_trace_count
        else if active_actor_count >= 2 && interaction_count = 0 then
          Printf.sprintf
            "여러 참여자가 활동했으나 직접 상호작용 증거가 아직 없음. Backing trace=%d."
            cp_trace_count
        else
          Printf.sprintf "상호작용=%d, 증거=%d, backing trace=%d."
            interaction_count evidence_count cp_trace_count
      in
      `Assoc
        [
          ("headline", `String headline);
          ("detail", `String (detail_with_history detail));
          ("session_id", `String session.session_id);
          ("goal", `String session.goal);
          ("verdict", `String verdict);
          ("live_verdict", `String live_verdict);
          ("historical_verdict", Json_util.string_opt_to_json historical_verdict);
          ("verdict_basis", `String verdict_basis);
          ("actors_count", `Int active_actor_count);
          ("planned_actor_count", `Int planned_actor_count);
          ("mentioned_actor_count", `Int mentioned_actor_count);
          ("unanswered_actor_count", `Int unanswered_actor_count);
          ("interaction_count", `Int interaction_count);
          ("evidence_count", `Int evidence_count);
          ("cp_trace_count", `Int cp_trace_count);
          ("raw_trace_run_count", `Int raw_trace_run_count);
          ("validated_worker_run_count", `Int validated_worker_run_count);
        ]

let selection_json ~requested_session_id ~requested_operation_id ~session ~operation_id
    ~session_count =
  let mode, reason =
    match requested_session_id, session with
    | Some requested, Some current when String.equal requested current.Team_session_types.session_id ->
        ("explicit", "요청한 session_id가 기록된 협업 세션과 일치.")
    | Some requested, None ->
        ( "requested_not_found",
          Printf.sprintf
            "요청한 session_id '%s'을(를) 찾지 못했습니다. 근거 컨텍스트가 선택되지 않았습니다."
            requested )
    | None, Some _ ->
        ("latest_auto_selected", "session_id가 없어서 가장 최근 세션을 자동 선택.")
    | None, None ->
        ("none", "기록된 협업 세션이 아직 없습니다.")
    | Some _, Some _ ->
        ("explicit", "요청한 session_id가 기록된 협업 세션과 일치.")
  in
  `Assoc
    [
      ("mode", `String mode);
      ("reason", `String reason);
      ("requested_session_id", Json_util.string_opt_to_json requested_session_id);
      ("requested_operation_id", Json_util.string_opt_to_json requested_operation_id);
      ( "selected_session_id",
        Json_util.string_opt_to_json
          (Option.map (fun c -> c.Team_session_types.session_id) session) );
      ( "selected_goal",
        Json_util.string_opt_to_json (Option.map (fun c -> c.Team_session_types.goal) session) );
      ( "selected_created_by",
        Json_util.string_opt_to_json (Option.map (fun c -> c.Team_session_types.created_by) session) );
      ("selected_operation_id", Json_util.string_opt_to_json operation_id);
      ("available_session_count", `Int session_count);
    ]

let namespace_json config =
  let state = Room.read_state config in
  `Assoc
    [
      ("project", `String state.project);
      ("namespace_id", `String "default");
      ("namespace", `String "default");
      ("current_namespace", `String "default");
      ("namespace_mode", `String "flattened");
      ("paused", `Bool state.paused);
      ("message_seq", `Int state.message_seq);
    ]

let room_json config =
  let state = Room.read_state config in
  `Assoc
    [
      ("project", `String state.project);
      ("current_namespace", `String "default");
      ("current_room", `String "default");
      ("namespace_id", `String "default");
      ("namespace", `String "default");
      ("namespace_mode", `String "flattened");
      ("paused", `Bool state.paused);
      ("message_seq", `Int state.message_seq);
    ]
