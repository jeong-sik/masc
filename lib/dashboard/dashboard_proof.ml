(** Evidence-first collaboration proof projection.

    Delegates to sub-modules:
    - {!Dashboard_proof_events} — event parsing
    - {!Dashboard_proof_actors} — actor contribution analysis
    - {!Dashboard_proof_verdict} — verdict, timeline, session summary

    @since 2.80.0 *)

include Dashboard_proof_helpers
module U = Yojson.Safe.Util

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
    match session_id, session with
    | Some current, Some s ->
        let path = Team_session_store.proof_json_path config current in
        let existing = Room_utils.read_json_opt config path in
        (* M-16 fix: auto-generate proof if it doesn't exist yet *)
        (match existing with
         | Some _ -> existing
         | None ->
            (try
               match Team_session_report_proof.generate_proof config s with
               | Ok (proof_json, proof_markdown) ->
                   Room_utils.write_json config path proof_json;
                   let md_path = Team_session_store.proof_md_path config current in
                   Team_session_store.write_artifact_text config md_path
                     proof_markdown;
                   Some proof_json
               | Error e ->
                   Log.Misc.error "dashboard proof auto-gen failed: %s" e;
                   None
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
               Log.Misc.error "dashboard proof auto-gen exception: %s" (Printexc.to_string exn);
               None))
    | _ -> None
  in
  let events =
    match session_id with
    | Some current -> Team_session_store.read_events ~max_events:200 config current
    | None -> []
  in
  let contributions = Dashboard_proof_actors.build_actor_contributions session events in
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
    match operation_id, session with
    | Some value, _ -> Some value
    | None, Some current ->
        option_or_else
          (fun () -> Some ("detachment-" ^ current.session_id))
          current.Team_session_types.operation_id
    | None, None -> None
  in
  let cp_backing =
    match operation_id with
    | Some current -> Some (Dashboard_proof_verdict.cp_backing_json config current)
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
           if Dashboard_proof_events.event_tool_names json <> [] then acc + 1 else acc)
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
          Dashboard_proof_verdict.artifact_ref_json "session_json" (Team_session_store.session_json_path config current);
          Dashboard_proof_verdict.artifact_ref_json "report_json" (Team_session_store.report_json_path config current);
          Dashboard_proof_verdict.artifact_ref_json "report_md" (Team_session_store.report_md_path config current);
          Dashboard_proof_verdict.artifact_ref_json "proof_json" (Team_session_store.proof_json_path config current);
          Dashboard_proof_verdict.artifact_ref_json "proof_md" (Team_session_store.proof_md_path config current);
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
  let worker_run_meta = Dashboard_proof_actors.worker_run_meta_jsons config session_id in
  let worker_run_evidence_count =
    worker_run_meta
    |> List.fold_left
         (fun acc json ->
           match Dashboard_proof_actors.worker_run_trace_capability json with
           | Some "raw" | Some "summary_only" -> acc + 1
           | _ -> acc)
         0
  in
  let evidence_present =
    tool_evidence_count > 0 || deliverable_count > 0 || checkpoints_count > 0
    || Option.is_some proof_doc || worker_run_evidence_count > 0
  in
  let raw_trace_run_count =
    worker_run_meta
    |> List.fold_left
         (fun acc json ->
           match Dashboard_proof_actors.worker_run_trace_capability json with
           | Some "raw" -> acc + 1
           | _ -> acc)
         0
  in
  let validated_worker_run_count =
    worker_run_meta
    |> List.fold_left
         (fun acc json ->
           match Dashboard_proof_actors.worker_run_trace_validated json with
           | Some true -> acc + 1
           | _ -> acc)
         0
  in
  let live_verdict =
    Dashboard_proof_verdict.proof_verdict ~active_actor_count ~interaction_present:(interaction_count > 0)
      ~evidence_present ~artifact_present ~validated_worker_run_count
  in
  let historical_verdict =
    Option.bind proof_doc Dashboard_proof_verdict.historical_verdict_of_proof_doc
  in
  let verdict, verdict_basis =
    Dashboard_proof_verdict.combine_verdicts ~live_verdict ~historical_verdict
  in
  let goal_binding =
    match session with
    | None ->
        `Assoc
          [
            ("session_goal", `Null);
            ("operation_id", Json_util.string_opt_to_json operation_id);
          ]
    | Some current ->
        `Assoc
          [
            ("session_id", `String current.session_id);
            ("session_goal", `String current.goal);
            ("status", `String (Team_session_types.status_to_string current.status));
            ("operation_id", Json_util.string_opt_to_json operation_id);
            ("broadcast_count", `Int current.broadcast_count);
            ("portal_count", `Int current.portal_count);
            ("planned_workers", `Int (List.length current.planned_workers));
          ]
  in
  let tool_evidence =
    `List
      (events
      |> List.filter (fun json -> Dashboard_proof_events.event_tool_names json <> [])
      |> List.rev
      |> List.fold_left
           (fun acc json ->
             if List.length acc >= 12 then acc
             else
               (`Assoc
                  [
                    ("actor", Json_util.string_opt_to_json (Dashboard_proof_events.event_actor json));
                    ("event_type", Json_util.string_opt_to_json (string_field "event_type" json));
                    ("tool_names", `List (List.map (fun value -> `String value) (Dashboard_proof_events.event_tool_names json)));
                    ("summary", `String (Dashboard_proof_events.event_summary json));
                    ("timestamp", Json_util.string_opt_to_json (string_field "ts_iso" json));
                  ])
               :: acc)
           []
      |> List.rev)
  in
  `Assoc
    [
      ("schema_version", `String "1.0.0");
      ("generated_at", `String (Types.now_iso ()));
      ("namespace", Dashboard_proof_verdict.namespace_json config);
      ("room", Dashboard_proof_verdict.room_json config);
      ( "selection",
        Dashboard_proof_verdict.selection_json ~requested_session_id
          ~requested_operation_id ~session
          ~operation_id ~session_count:(List.length sessions) );
      ("session_id", Json_util.string_opt_to_json session_id);
      ("operation_id", Json_util.string_opt_to_json operation_id);
      ("proof_verdict", `String verdict);
      ( "summary",
        Dashboard_proof_verdict.session_summary_json session verdict ~planned_actor_count
          ~active_actor_count ~mentioned_actor_count ~unanswered_actor_count
          ~interaction_count
          ~evidence_count:
            (tool_evidence_count + deliverable_count + checkpoints_count
           + worker_run_evidence_count)
          ~cp_trace_count ~raw_trace_run_count ~validated_worker_run_count
          ~live_verdict ~historical_verdict ~verdict_basis );
      ("timeline", Dashboard_proof_verdict.timeline_json ?session_id ?operation_id events cp_traces);
      ("actor_contributions", `List (Dashboard_proof_actors.actor_contributions_json contributions));
      ("goal_binding", goal_binding);
      ("tool_evidence", tool_evidence);
      ( "worker_proof_evidence",
        `List
          (worker_run_meta
          |> List.filter (fun json -> U.member "proof_present" json = `Bool true)
          |> List.fold_left
               (fun acc json ->
                 if List.length acc >= 12 then acc
                 else Dashboard_proof_actors.worker_run_summary_json json :: acc)
               []
          |> List.rev) );
      ( "worker_run_evidence",
        `List
          (worker_run_meta
          |> List.filter (fun json ->
                 match Dashboard_proof_actors.worker_run_trace_capability json with
                 | Some "raw" | Some "summary_only" -> true
                 | _ -> false)
          |> List.fold_left
               (fun acc json ->
                 if List.length acc >= 12 then acc
                 else Dashboard_proof_actors.worker_run_summary_json json :: acc)
               []
          |> List.rev) );
      ("cp_backing_evidence", match cp_backing with Some value -> value | None -> `Null);
      ("artifacts", `List artifact_paths);
      ("raw_proof", match proof_doc with Some value -> value | None -> `Null);
    ]
