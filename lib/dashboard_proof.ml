(** Evidence-first collaboration proof projection. *)

module U = Yojson.Safe.Util

type actor_acc = {
  actor : string;
  role : string option;
  mutable turn_count : int;
  mutable spawn_count : int;
  mutable tool_evidence_count : int;
  mutable interaction_count : int;
  mutable recent_input_preview : string option;
  mutable recent_output_preview : string option;
  mutable recent_event_summary : string option;
  mutable recent_tool_names : string list;
  mutable last_active_at : string option;
}

let option_or_else fallback opt =
  match opt with Some _ -> opt | None -> fallback ()

let option_first_some left right =
  match left with Some _ -> left | None -> right

let option_non_empty_trimmed = function
  | Some value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | None -> None

let truncate_preview ?(max_len = 160) text =
  let text =
    text
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.filter (fun chunk -> chunk <> "")
    |> String.concat " "
  in
  if String.length text <= max_len then text else String.sub text 0 (max_len - 1) ^ "…"

let string_field key json =
  match U.member key json with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let list_of_strings key json =
  match U.member key json with
  | `List items ->
      items
      |> List.filter_map (function
           | `String value ->
               let trimmed = String.trim value in
               if trimmed = "" then None else Some trimmed
           | _ -> None)
  | _ -> []

let detail_of_event json =
  match U.member "detail" json with
  | `Assoc _ as detail -> detail
  | _ -> `Assoc []

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
          turn_count = 0;
          spawn_count = 0;
          tool_evidence_count = 0;
          interaction_count = 0;
          recent_input_preview = None;
          recent_output_preview = None;
          recent_event_summary = None;
          recent_tool_names = [];
          last_active_at = None;
        }
      in
      Hashtbl.replace table actor acc;
      acc

let tool_name_union xs ys =
  Team_session_types.dedup_strings (xs @ ys)

let actor_contributions_json session events =
  let table = Hashtbl.create 16 in
  List.iter
    (fun json ->
      match event_actor json with
      | None -> ()
      | Some actor ->
          let acc = get_or_create_actor table session actor in
          let event_type = string_field "event_type" json |> Option.value ~default:"event" in
          if String.equal event_type "team_turn" then acc.turn_count <- acc.turn_count + 1;
          if String.equal event_type "team_step_spawn" then acc.spawn_count <- acc.spawn_count + 1;
          let tool_names = event_tool_names json in
          if tool_names <> [] then acc.tool_evidence_count <- acc.tool_evidence_count + 1;
          if Option.is_some (event_related_actor json) then
            acc.interaction_count <- acc.interaction_count + 1;
          acc.recent_tool_names <- tool_name_union acc.recent_tool_names tool_names;
          acc.recent_input_preview <-
            option_first_some (event_input_preview json) acc.recent_input_preview;
          acc.recent_output_preview <-
            option_first_some (event_output_preview json) acc.recent_output_preview;
          acc.recent_event_summary <- Some (event_summary json);
          acc.last_active_at <- option_first_some (string_field "ts_iso" json) acc.last_active_at)
    events;
  Hashtbl.to_seq_values table
  |> List.of_seq
  |> List.sort (fun a b ->
         match a.last_active_at, b.last_active_at with
         | Some x, Some y -> String.compare y x
         | Some _, None -> -1
         | None, Some _ -> 1
         | None, None -> String.compare a.actor b.actor)
  |> List.map (fun acc ->
         `Assoc
           [
             ("actor", `String acc.actor);
             ("role", match acc.role with Some value -> `String value | None -> `Null);
             ("turn_count", `Int acc.turn_count);
             ("spawn_count", `Int acc.spawn_count);
             ("tool_evidence_count", `Int acc.tool_evidence_count);
             ("interaction_count", `Int acc.interaction_count);
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

let proof_verdict ~actor_count ~interaction_present ~evidence_present ~artifact_present =
  if actor_count >= 2 && interaction_present && evidence_present && artifact_present then
    "proven"
  else if actor_count >= 2 || interaction_present || evidence_present || artifact_present then
    "partial"
  else
    "insufficient"

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

let session_summary_json session verdict actor_count interaction_count evidence_count cp_trace_count =
  match session with
  | None ->
      `Assoc
        [
          ("headline", `String "No collaboration session evidence is currently selected.");
          ("detail", `String "Provide session_id or start a team session to build proof.");
          ("verdict", `String verdict);
          ("actors_count", `Int actor_count);
          ("interaction_count", `Int interaction_count);
          ("evidence_count", `Int evidence_count);
          ("cp_trace_count", `Int cp_trace_count);
        ]
  | Some session ->
      `Assoc
        [
          ( "headline",
            `String
              (Printf.sprintf "%d actors contributed to '%s'."
                 actor_count (truncate_preview ~max_len:100 session.Team_session_types.goal)) );
          ( "detail",
            `String
              (Printf.sprintf "Interaction evidence=%d, backing traces=%d, verdict=%s."
                 interaction_count cp_trace_count verdict) );
          ("session_id", `String session.session_id);
          ("goal", `String session.goal);
          ("verdict", `String verdict);
          ("actors_count", `Int actor_count);
          ("interaction_count", `Int interaction_count);
          ("evidence_count", `Int evidence_count);
          ("cp_trace_count", `Int cp_trace_count);
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
  let actor_names =
    let from_session =
      match session with
      | Some s -> Team_session_types.planned_participant_names s
      | None -> []
    in
    let from_events =
      events |> List.filter_map event_actor |> Team_session_types.dedup_strings
    in
    Team_session_types.dedup_strings (from_session @ from_events)
  in
  let interaction_count =
    events
    |> List.fold_left (fun acc json ->
           if Option.is_some (event_related_actor json) then acc + 1 else acc)
         0
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
  let verdict =
    proof_verdict ~actor_count:(List.length actor_names)
      ~interaction_present:(interaction_count > 0)
      ~evidence_present ~artifact_present
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
      ("session_id", match session_id with Some value -> `String value | None -> `Null);
      ("operation_id", match operation_id with Some value -> `String value | None -> `Null);
      ("proof_verdict", `String verdict);
      ( "summary",
        session_summary_json session verdict (List.length actor_names)
          interaction_count
          (tool_evidence_count + deliverable_count + checkpoints_count)
          cp_trace_count );
      ("timeline", timeline_json ?session_id ?operation_id events cp_traces);
      ("actor_contributions", `List (actor_contributions_json session events));
      ("goal_binding", goal_binding);
      ("tool_evidence", tool_evidence);
      ("cp_backing_evidence", match cp_backing with Some value -> value | None -> `Null);
      ("artifacts", `List artifact_paths);
      ("raw_proof", match proof_doc with Some value -> value | None -> `Null);
    ]
