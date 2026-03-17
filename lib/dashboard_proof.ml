(** Evidence-first collaboration proof projection. *)

include Dashboard_proof_helpers

let event_actor json =
  let detail = detail_of_event json in
  match string_field "actor" detail with
  | Some actor -> Some actor
  | None -> string_field "runtime_actor" detail

let event_related_actor json =
  let detail = detail_of_event json in
  string_field "runtime_actor" detail
  |> option_or_else (fun () -> string_field "supervisor_actor" detail)
  |> option_or_else (fun () -> string_field "target_actor" detail)

let event_summary json =
  let detail = detail_of_event json in
  let candidates =
    [
      string_field "message" detail;
      string_field "summary" detail;
      string_field "title" detail;
      string_field "reason" detail;
      string_field "result" detail;
      string_field "content" detail;
      string_field "task_description" detail;
      string_field "goal" detail;
      string_field "vote_topic" detail;
    ]
  in
  match List.find_opt Option.is_some candidates with
  | Some (Some value) -> truncate_preview value
  | _ ->
      string_field "event_type" json
      |> Option.value ~default:"event"

let event_input_preview json =
  let detail = detail_of_event json in
  let candidates =
    [
      string_field "task_description" detail;
      string_field "goal" detail;
      string_field "vote_topic" detail;
      string_field "reason" detail;
      string_field "title" detail;
    ]
  in
  match List.find_opt Option.is_some candidates with
  | Some (Some value) -> Some (truncate_preview value)
  | _ -> None

let event_output_preview json =
  let detail = detail_of_event json in
  let candidates =
    [
      string_field "message" detail;
      string_field "summary" detail;
      string_field "content" detail;
      string_field "result" detail;
    ]
  in
  match List.find_opt Option.is_some candidates with
  | Some (Some value) -> Some (truncate_preview value)
  | _ -> None

let event_tool_names json =
  let detail = detail_of_event json in
  let plural = list_of_strings "tool_names" detail in
  if plural <> [] then plural
  else
    match string_field "tool_name" detail with
    | Some value -> [ value ]
    | None -> []

let is_mention_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> true
  | _ -> false

let mention_names_of_text text =
  let len = String.length text in
  let rec scan idx acc =
    if idx >= len then
      List.rev acc
    else if Char.equal text.[idx] '@' then
      let start = idx + 1 in
      let rec advance j =
        if j < len && is_mention_char text.[j] then advance (j + 1) else j
      in
      let stop = advance start in
      if stop > start then
        scan stop (String.sub text start (stop - start) :: acc)
      else
        scan (idx + 1) acc
    else
      scan (idx + 1) acc
  in
  scan 0 [] |> unique_non_empty_strings

let mentioned_actors_of_event json =
  let detail = detail_of_event json in
  let texts =
    [
      string_field "message" detail;
      string_field "summary" detail;
      string_field "content" detail;
      string_field "title" detail;
      string_field "task_description" detail;
    ]
  in
  texts
  |> List.filter_map Fun.id
  |> List.concat_map mention_names_of_text
  |> unique_non_empty_strings

let known_session_actor_names = function
  | Some session -> Team_session_types.planned_participant_names session
  | None -> []

let actor_role_lookup (session : Team_session_types.session option) actor =
  match session with
  | None -> None
  | Some session when String.equal actor session.created_by -> Some "supervisor"
  | Some session -> (
      session.Team_session_types.planned_workers
      |> List.find_map (fun worker ->
             match worker.Team_session_types.runtime_actor with
             | Some runtime_actor when String.equal runtime_actor actor ->
                 worker.spawn_role
                 |> Option.map String.trim
                 |> option_non_empty_trimmed
             | _ -> None)
      |> option_or_else (fun () ->
             if List.exists (String.equal actor) session.agent_names then
               Some "participant"
             else None))

let get_or_create_actor table session actor =
  match Hashtbl.find_opt table actor with
  | Some acc -> acc
  | None ->
      let acc =
        {
          actor;
          role = actor_role_lookup session actor;
          observed_event_count = 0;
          turn_count = 0;
          spawn_count = 0;
          tool_evidence_count = 0;
          interaction_count = 0;
          mention_count = 0;
          recent_input_preview = None;
          recent_output_preview = None;
          recent_event_summary = None;
          recent_tool_names = [];
          last_active_at = None;
          requested_by = None;
          recent_request_preview = None;
          recent_request_at = None;
        }
      in
      Hashtbl.replace table actor acc;
      acc

let tool_name_union xs ys =
  Team_session_types.dedup_strings (xs @ ys)

let worker_run_meta_jsons config = function
  | None -> []
  | Some session_id ->
      Team_session_store.list_worker_run_ids config session_id
      |> List.sort String.compare
      |> List.rev
      |> List.filter_map (fun worker_run_id ->
             let path =
               Team_session_store.worker_run_meta_path config session_id
                 worker_run_id
             in
             if Room_utils.path_exists config path then
               Some (Room_utils.read_json config path)
             else None)

let worker_run_trace_capability json =
  match U.member "trace_capability" json with
  | `String value -> Some value
  | _ -> None

let worker_run_trace_validated json =
  match U.member "validated" json with
  | `Bool value -> Some value
  | _ -> (
      match U.member "trace_validation" json |> U.member "ok" with
      | `Bool value -> Some value
      | _ -> None)

let session_conformance_failures json =
  match U.member "session_conformance" json |> U.member "checks" with
  | `List items ->
      items
      |> List.filter_map (fun item ->
             match U.member "name" item, U.member "passed" item with
             | `String name, `Bool false -> Some name
             | _ -> None)
  | _ -> []

let worker_run_validation_failures json =
  let trace_failures =
    match U.member "trace_validation" json |> U.member "checks" with
    | `List items ->
        items
        |> List.filter_map (fun item ->
               match U.member "name" item, U.member "passed" item with
               | `String name, `Bool false -> Some name
               | _ -> None)
    | _ -> []
  in
  Team_session_types.dedup_strings
    (trace_failures @ session_conformance_failures json)

let worker_run_summary_json json =
  let summary = U.member "trace_summary" json in
  `Assoc
    [
      ("worker_run_id", U.member "worker_run_id" json);
      ("worker_name", U.member "worker_name" json);
      ("status", U.member "status" json);
      ("mode", U.member "mode" json);
      ("wait_mode", U.member "wait_mode" json);
      ( "trace_capability",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          (worker_run_trace_capability json) );
      ( "trace_validated",
        Option.fold ~none:`Null ~some:(fun v -> `Bool v)
          (worker_run_trace_validated json) );
      ( "validation_failures",
        `List
          (List.map (fun item -> `String item)
             (worker_run_validation_failures json)) );
      ("success", U.member "success" json);
      ("execution_scope", U.member "execution_scope" json);
      ("requested_worker_class", U.member "requested_worker_class" json);
      ("requested_worker_size", U.member "requested_worker_size" json);
      ("resolved_runtime", U.member "resolved_runtime" json);
      ("resolved_model", U.member "resolved_model" json);
      ("routing_reason", U.member "routing_reason" json);
      ("tool_names", U.member "tool_names" json);
      ("tool_call_count", U.member "tool_call_count" json);
      ("output_preview", U.member "output_preview" json);
      ("record_count", U.member "record_count" summary);
      ("assistant_block_count", U.member "assistant_block_count" summary);
      ("final_text", if U.member "final_text" json <> `Null then U.member "final_text" json else U.member "final_text" summary);
      ("stop_reason", if U.member "stop_reason" json <> `Null then U.member "stop_reason" json else U.member "stop_reason" summary);
      ("failure_reason", U.member "failure_reason" json);
      ("error", if U.member "error" json <> `Null then U.member "error" json else U.member "error" summary);
      ("session_conformance", U.member "session_conformance" json);
      ("ts_iso", U.member "ts_iso" json);
    ]

let actor_activity_state (acc : actor_acc) =
  if acc.observed_event_count > 0 then
    "acted"
  else if acc.mention_count > 0 then
    "mentioned_only"
  else
    "planned_only"

let actor_status_detail (acc : actor_acc) =
  match actor_activity_state acc with
  | "acted" ->
      if acc.interaction_count > 0 then
        "실제 이벤트와 상호작용 흔적이 있습니다."
      else
        "실제 이벤트는 있으나 직접 응답/호출 연결은 약합니다."
  | "mentioned_only" ->
      if acc.mention_count = 1 then
        "호출되었지만 응답, 도구, 산출물 근거는 아직 없습니다."
      else
        Printf.sprintf "%d번 호출되었지만 응답, 도구, 산출물 근거는 아직 없습니다."
          acc.mention_count
  | _ -> "계획된 참여자로 보이지만 아직 남겨진 흔적이 없습니다."

let build_actor_contributions session events =
  let table = Hashtbl.create 16 in
  let known_names = known_session_actor_names session in
  let is_known_name actor =
    List.exists (String.equal actor) known_names
  in
  (match session with
  | Some current ->
      Team_session_types.planned_participant_names current
      |> List.iter (fun actor -> ignore (get_or_create_actor table session actor))
  | None -> ());
  List.iter
    (fun json ->
      match event_actor json with
      | None -> ()
      | Some actor ->
          let acc = get_or_create_actor table session actor in
          acc.observed_event_count <- acc.observed_event_count + 1;
          let event_type = string_field "event_type" json |> Option.value ~default:"event" in
          if String.equal event_type "team_turn" then acc.turn_count <- acc.turn_count + 1;
          if String.equal event_type "team_step_spawn" then acc.spawn_count <- acc.spawn_count + 1;
          let tool_names = event_tool_names json in
          if tool_names <> [] then acc.tool_evidence_count <- acc.tool_evidence_count + 1;
          if Option.is_some (event_related_actor json) then
            acc.interaction_count <- acc.interaction_count + 1;
          acc.recent_tool_names <- tool_name_union acc.recent_tool_names tool_names;
          acc.recent_input_preview <-
            option_prefer_new acc.recent_input_preview (event_input_preview json);
          acc.recent_output_preview <-
            option_prefer_new acc.recent_output_preview (event_output_preview json);
          acc.recent_event_summary <- Some (event_summary json);
          acc.last_active_at <- option_prefer_new acc.last_active_at (string_field "ts_iso" json);
          let request_preview =
            option_first_some (event_output_preview json) (Some (event_summary json))
          in
          let request_at = string_field "ts_iso" json in
          mentioned_actors_of_event json
          |> List.iter (fun target ->
                 if not (String.equal target actor) && is_known_name target then
                   let target_acc = get_or_create_actor table session target in
                   target_acc.mention_count <- target_acc.mention_count + 1;
                   target_acc.requested_by <-
                     option_prefer_new target_acc.requested_by (Some actor);
                   target_acc.recent_request_preview <-
                     option_prefer_new target_acc.recent_request_preview request_preview;
                   target_acc.recent_request_at <-
                     option_prefer_new target_acc.recent_request_at request_at))
    events;
  Hashtbl.to_seq_values table
  |> List.of_seq
  |> List.sort (fun a b ->
         let activity_rank acc =
           match actor_activity_state acc with
           | "acted" -> 0
           | "mentioned_only" -> 1
           | _ -> 2
         in
         let by_rank = Int.compare (activity_rank a) (activity_rank b) in
         if by_rank <> 0 then
           by_rank
         else
           match
             option_first_some a.last_active_at a.recent_request_at,
             option_first_some b.last_active_at b.recent_request_at
           with
           | Some x, Some y -> String.compare y x
           | Some _, None -> -1
           | None, Some _ -> 1
           | None, None -> String.compare a.actor b.actor)

let actor_contributions_json contributions =
  contributions
  |> List.map (fun acc ->
         `Assoc
           [
             ("actor", `String acc.actor);
             ("role", match acc.role with Some value -> `String value | None -> `Null);
             ("activity_state", `String (actor_activity_state acc));
             ("activity_detail", `String (actor_status_detail acc));
             ("observed_event_count", `Int acc.observed_event_count);
             ("turn_count", `Int acc.turn_count);
             ("spawn_count", `Int acc.spawn_count);
             ("tool_evidence_count", `Int acc.tool_evidence_count);
             ("interaction_count", `Int acc.interaction_count);
             ("mention_count", `Int acc.mention_count);
             ( "recent_input_preview",
               match acc.recent_input_preview with
               | Some value -> `String value
               | None -> `Null );
             ( "recent_output_preview",
               match acc.recent_output_preview with
               | Some value -> `String value
               | None -> `Null );
             ( "recent_event_summary",
               match acc.recent_event_summary with
               | Some value -> `String value
               | None -> `Null );
             ( "requested_by",
               match acc.requested_by with
               | Some value -> `String value
               | None -> `Null );
             ( "recent_request_preview",
               match acc.recent_request_preview with
               | Some value -> `String value
               | None -> `Null );
             ( "recent_request_at",
               match acc.recent_request_at with
               | Some value -> `String value
               | None -> `Null );
             ("recent_tool_names", `List (List.map (fun value -> `String value) acc.recent_tool_names));
             ("last_active_at", match acc.last_active_at with Some value -> `String value | None -> `Null);
           ])

let timeline_json ?session_id ?operation_id events cp_events =
  let session_items =
    events
    |> List.mapi (fun idx json ->
           let event_type = string_field "event_type" json |> Option.value ~default:"event" in
           let timestamp = string_field "ts_iso" json |> Option.value ~default:(Types.now_iso ()) in
           let actor = event_actor json in
           `Assoc
             [
               ("id", `String (Printf.sprintf "session-%04d" (idx + 1)));
               ("seq", `Int (idx + 1));
               ("source", `String "team_session");
               ("session_id", match session_id with Some value -> `String value | None -> `Null);
               ("operation_id", match operation_id with Some value -> `String value | None -> `Null);
               ("event_type", `String event_type);
               ("timestamp", `String timestamp);
               ("actor", match actor with Some value -> `String value | None -> `Null);
               ("summary", `String (event_summary json));
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
                   ("session_id", match session_id with Some value -> `String value | None -> `Null);
                   ( "operation_id",
                     match string_field "operation_id" event |> option_or_else (fun () -> operation_id) with
                     | Some value -> `String value
                     | None -> `Null );
                   ("event_type", `String event_type);
                   ("timestamp", `String timestamp);
                   ("actor", match string_field "actor" event with Some value -> `String value | None -> `Null);
                   ("summary", `String (event_summary event));
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
    ~artifact_present =
  if active_actor_count >= 2 && interaction_present && evidence_present
     && artifact_present
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
        ^ " Historical proof says this session was proved, but current live evidence is missing or stale."
    | Some "proven", "partial", _ ->
        base_detail
        ^ " Historical proof is stronger than the current live evidence, so the dashboard keeps this as partial."
    | Some historical, _, _ when not (String.equal historical live_verdict) ->
        base_detail
        ^ Printf.sprintf " Historical proof=%s, live verdict=%s." historical
          live_verdict
    | _ -> base_detail
  in
  match session with
  | None ->
      `Assoc
        [
          ("headline", `String "No collaboration session evidence is currently selected.");
          ("detail", `String "Provide session_id or start a team session to build proof.");
          ("verdict", `String verdict);
          ("live_verdict", `String live_verdict);
          ( "historical_verdict",
            match historical_verdict with Some value -> `String value | None -> `Null );
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
        Printf.sprintf "%d actors left real traces in '%s'."
          active_actor_count
          (truncate_preview ~max_len:100 session.Team_session_types.goal)
      in
      let detail =
        if unanswered_actor_count > 0 then
          Printf.sprintf
            "%d actors were invited or mentioned but still have no reply/tool evidence. Interaction=%d, backing traces=%d."
            unanswered_actor_count interaction_count cp_trace_count
        else if active_actor_count >= 2 && interaction_count = 0 then
          Printf.sprintf
            "Multiple actors were active, but direct cross-actor interaction is still missing. Backing traces=%d."
            cp_trace_count
        else
          Printf.sprintf "Interaction=%d, evidence=%d, backing traces=%d."
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
          ( "historical_verdict",
            match historical_verdict with Some value -> `String value | None -> `Null );
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
        ("explicit", "Requested session_id matched a recorded collaboration session.")
    | Some requested, None ->
        ( "requested_not_found",
          Printf.sprintf
            "Requested session_id '%s' was not found. No proof context is selected."
            requested )
    | None, Some _ ->
        ("latest_auto_selected", "No session_id was supplied, so the most recent session was selected automatically.")
    | None, None ->
        ("none", "No recorded collaboration session is available yet.")
    | Some _, Some _ ->
        ("explicit", "Requested session_id matched a recorded collaboration session.")
  in
  `Assoc
    [
      ("mode", `String mode);
      ("reason", `String reason);
      ( "requested_session_id",
        match requested_session_id with Some value -> `String value | None -> `Null );
      ( "requested_operation_id",
        match requested_operation_id with Some value -> `String value | None -> `Null );
      ( "selected_session_id",
        match session with
        | Some current -> `String current.Team_session_types.session_id
        | None -> `Null );
      ( "selected_goal",
        match session with
        | Some current -> `String current.goal
        | None -> `Null );
      ( "selected_created_by",
        match session with
        | Some current -> `String current.created_by
        | None -> `Null );
      ("selected_operation_id", match operation_id with Some value -> `String value | None -> `Null);
      ("available_session_count", `Int session_count);
    ]

let room_json config =
  let state = Room.read_state config in
  `Assoc
    [
      ("project", `String state.project);
      ("current_room", match Room.read_current_room config with Some value -> `String value | None -> `Null);
      ("paused", `Bool state.paused);
      ("message_seq", `Int state.message_seq);
    ]

let json ?actor:_ ?session_id ?operation_id ~config () =
  let requested_session_id = session_id in
  let requested_operation_id = operation_id in
  let sessions =
    Team_session_store.list_sessions config
    |> List.sort (fun (a : Team_session_types.session) (b : Team_session_types.session) ->
           compare b.started_at a.started_at)
  in
  let session =
    match session_id with
    | Some target ->
        List.find_opt (fun (candidate : Team_session_types.session) ->
            String.equal candidate.session_id target)
          sessions
    | None -> (
        match sessions with
        | x :: _ -> Some x
        | [] -> None)
  in
  let session_id = Option.map (fun (s : Team_session_types.session) -> s.session_id) session in
  let proof_doc =
    match session_id with
    | Some current ->
        let path = Team_session_store.proof_json_path config current in
        Room_utils.read_json_opt config path
    | None -> None
  in
  let events =
    match session_id with
    | Some current -> Team_session_store.read_events ~max_events:200 config current
    | None -> []
  in
  let contributions = build_actor_contributions session events in
  let planned_actor_count =
    match session with
    | Some current -> List.length (Team_session_types.planned_participant_names current)
    | None -> 0
  in
  let active_actor_count =
    contributions
    |> List.filter (fun acc -> acc.observed_event_count > 0)
    |> List.length
  in
  let mentioned_actor_count =
    contributions
    |> List.filter (fun acc -> acc.mention_count > 0)
    |> List.length
  in
  let unanswered_actor_count =
    contributions
    |> List.filter (fun acc ->
           acc.observed_event_count = 0 && acc.mention_count > 0)
    |> List.length
  in
  let interaction_count =
    contributions
    |> List.fold_left (fun acc item -> acc + item.interaction_count) 0
  in
  let checkpoints_count =
    match session_id with
    | Some current -> Team_session_store.list_checkpoint_paths config current |> List.length
    | None -> 0
  in
  let operation_id =
    match operation_id, session_id with
    | Some value, _ -> Some value
    | None, Some current -> Some ("detachment-" ^ current)
    | None, None -> None
  in
  let cp_backing =
    match operation_id with
    | Some current -> Some (cp_backing_json config current)
    | None -> None
  in
  let cp_traces =
    match cp_backing with
    | Some backing -> backing |> U.member "traces"
    | None -> `Assoc [ ("events", `List []) ]
  in
  let cp_trace_count =
    match cp_traces |> U.member "events" with
    | `List items -> List.length items
    | _ -> 0
  in
  let tool_evidence_count =
    events
    |> List.fold_left (fun acc json ->
           if event_tool_names json <> [] then acc + 1 else acc)
         0
  in
  let deliverable_count =
    events
    |> List.fold_left (fun acc json ->
           match string_field "event_type" json with
           | Some "team_run_deliverable" -> acc + 1
           | _ -> acc)
         0
  in
  let artifact_paths =
    match session_id with
    | Some current ->
        [
          artifact_ref_json "session_json" (Team_session_store.session_json_path config current);
          artifact_ref_json "report_json" (Team_session_store.report_json_path config current);
          artifact_ref_json "report_md" (Team_session_store.report_md_path config current);
          artifact_ref_json "proof_json" (Team_session_store.proof_json_path config current);
          artifact_ref_json "proof_md" (Team_session_store.proof_md_path config current);
        ]
    | None -> []
  in
  let artifact_present =
    List.exists
      (fun json ->
        match U.member "exists" json with
        | `Bool value -> value
        | _ -> false)
      artifact_paths
    || checkpoints_count > 0
  in
  let evidence_present =
    tool_evidence_count > 0 || deliverable_count > 0 || checkpoints_count > 0
    || Option.is_some proof_doc
  in
  let worker_run_meta = worker_run_meta_jsons config session_id in
  let raw_trace_run_count =
    worker_run_meta
    |> List.fold_left
         (fun acc json ->
           match worker_run_trace_capability json with
           | Some "raw" -> acc + 1
           | _ -> acc)
         0
  in
  let validated_worker_run_count =
    worker_run_meta
    |> List.fold_left
         (fun acc json ->
           match worker_run_trace_validated json with
           | Some true -> acc + 1
           | _ -> acc)
         0
  in
  let live_verdict =
    proof_verdict ~active_actor_count ~interaction_present:(interaction_count > 0)
      ~evidence_present ~artifact_present
  in
  let historical_verdict =
    Option.bind proof_doc historical_verdict_of_proof_doc
  in
  let verdict, verdict_basis =
    combine_verdicts ~live_verdict ~historical_verdict
  in
  let goal_binding =
    match session with
    | None ->
        `Assoc
          [
            ("session_goal", `Null);
            ("operation_id", match operation_id with Some value -> `String value | None -> `Null);
          ]
    | Some current ->
        `Assoc
          [
            ("session_id", `String current.session_id);
            ("session_goal", `String current.goal);
            ("status", `String (Team_session_types.status_to_string current.status));
            ("operation_id", match operation_id with Some value -> `String value | None -> `Null);
            ("broadcast_count", `Int current.broadcast_count);
            ("portal_count", `Int current.portal_count);
            ("planned_workers", `Int (List.length current.planned_workers));
          ]
  in
  let tool_evidence =
    `List
      (events
      |> List.filter (fun json -> event_tool_names json <> [])
      |> List.rev
      |> List.fold_left
           (fun acc json ->
             if List.length acc >= 12 then acc
             else
               (`Assoc
                  [
                    ("actor", match event_actor json with Some value -> `String value | None -> `Null);
                    ("event_type", match string_field "event_type" json with Some value -> `String value | None -> `Null);
                    ("tool_names", `List (List.map (fun value -> `String value) (event_tool_names json)));
                    ("summary", `String (event_summary json));
                    ("timestamp", match string_field "ts_iso" json with Some value -> `String value | None -> `Null);
                  ])
               :: acc)
           []
      |> List.rev)
  in
  `Assoc
    [
      ("schema_version", `String "1.0.0");
      ("generated_at", `String (Types.now_iso ()));
      ("room", room_json config);
      ( "selection",
        selection_json ~requested_session_id
          ~requested_operation_id ~session
          ~operation_id ~session_count:(List.length sessions) );
      ("session_id", match session_id with Some value -> `String value | None -> `Null);
      ("operation_id", match operation_id with Some value -> `String value | None -> `Null);
      ("proof_verdict", `String verdict);
      ( "summary",
        session_summary_json session verdict ~planned_actor_count
          ~active_actor_count ~mentioned_actor_count ~unanswered_actor_count
          ~interaction_count
          ~evidence_count:(tool_evidence_count + deliverable_count + checkpoints_count)
          ~cp_trace_count ~raw_trace_run_count ~validated_worker_run_count
          ~live_verdict ~historical_verdict ~verdict_basis );
      ("timeline", timeline_json ?session_id ?operation_id events cp_traces);
      ("actor_contributions", `List (actor_contributions_json contributions));
      ("goal_binding", goal_binding);
      ("tool_evidence", tool_evidence);
      ( "worker_run_evidence",
        `List
          (worker_run_meta
          |> List.filter (fun json ->
                 match worker_run_trace_capability json with
                 | Some "raw" | Some "summary_only" -> true
                 | _ -> false)
          |> List.fold_left
               (fun acc json ->
                 if List.length acc >= 12 then acc
                 else worker_run_summary_json json :: acc)
               []
          |> List.rev) );
      ("cp_backing_evidence", match cp_backing with Some value -> value | None -> `Null);
      ("artifacts", `List artifact_paths);
      ("raw_proof", match proof_doc with Some value -> value | None -> `Null);
    ]
