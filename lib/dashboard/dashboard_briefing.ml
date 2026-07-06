include Dashboard_utils

(* Types from Dashboard_briefing_assembly, re-exported for backward compat. *)
type session_context = Dashboard_briefing_assembly.session_context = {
  session_id : string;
  goal : string;
  created_by : string option;
  origin_kind : string;
  namespace : string option;
  status : Dashboard_utils.session_lifecycle;
  health : Dashboard_utils.health_level;
  member_names : string list;
  started_at : string option;
  elapsed_sec : int option;
  operation_id : string option;
  blocker_summary : string option;
  last_event_at : string option;
  last_event_ts : float;
  last_event_summary : string;
  communication_summary : string;
  active_count : int;
  seen_count : int;
  planned_count : int;
  required_count : int;
  counts_basis : string;
  top_attention : Yojson.Safe.t option;
  top_recommendation : Yojson.Safe.t option;
}

type attention_context = Dashboard_briefing_assembly.attention_context = {
  severity : string;
  has_action : bool;
  last_seen_ts : float;
  related_session_ids : string list;
  related_agent_names : string list;
  json : Yojson.Safe.t;
}

let top_item items =
  match items with
  | item :: _ -> item
  | [] -> `Null

(* session_payload_json, session_meta_json, session_summary_json,
   session_team_health_json, session_communication_json,
   session_status_opt, session_recent_events, event_detail_json
   are provided by Dashboard_utils (included above). *)

let event_summary event_json =
  let detail = event_detail_json event_json in
  let event_type =
    String_util.trim_to_option (string_field "event_type" event_json)
    |> Option.value ~default:"event"
  in
  let actor =
    match String_util.trim_to_option (string_field "actor" detail) with
    | Some value -> Some value
    | None -> String_util.trim_to_option (string_field "agent" detail)
  in
  let task_title =
    match String_util.trim_to_option (string_field "task_title" detail) with
    | Some value -> Some value
    | None -> String_util.trim_to_option (string_field "title" detail)
  in
  let result = String_util.trim_to_option (compact_text (string_field "result" detail)) in
  let reason = String_util.trim_to_option (compact_text (string_field "reason" detail)) in
  let output_preview =
    String_util.trim_to_option (compact_text (string_field "output_preview" detail))
  in
  match task_title, result, reason, output_preview with
  | Some title, _, _, _ ->
      compact_text
        (Printf.sprintf "%s%s" (match actor with Some value -> value ^ " · " | None -> "") title)
  | None, Some value, _, _ -> value
  | None, None, Some value, _ -> value
  | None, None, None, Some value -> value
  | None, None, None, None ->
      String.map (fun ch -> if ch = '_' then ' ' else ch) event_type

let system_session_creator_prefixes =
  [ "keeper"; "dashboard"; "operator"; "system"; "keeper-system"; "ecosystem" ]

let creator_looks_system created_by =
  let normalized = String.lowercase_ascii (String.trim created_by) in
  normalized <> ""
  && List.exists
       (fun prefix ->
         String.equal normalized prefix
         || String.starts_with ~prefix:(prefix ^ "-") normalized
         || String_util.contains_substring normalized ("-" ^ prefix ^ "-"))
       system_session_creator_prefixes

let session_origin_kind session_meta =
  let created_by =
    String_util.trim_to_option (string_field "created_by" session_meta)
    |> Option.value ~default:"<missing created_by field>"
  in
  String_util.trim_to_option (string_field "origin_kind" session_meta)
  |> Option.value
       ~default:
         (match
            String_util.trim_to_option (string_field "orchestration_mode" session_meta)
            |> Option.map String.lowercase_ascii
          with
         | Some "auto" -> "system"
         | _ -> if creator_looks_system created_by then "system" else "human")


let matching_action target_type target_id actions =
  List.find_opt
    (fun action ->
      let action_target_type = string_field "target_type" action in
      let action_target_id = String_util.trim_to_option (string_field "target_id" action) in
      String.equal action_target_type target_type
      &&
      match target_id, action_target_id with
      | Some left, Some right -> String.equal left right
      | None, None -> true
      | _ -> false)
    actions

let incident_action_types kind =
  match kind with
  | "spawn_failure_present" -> [ "task_inject" ]
  | "detached_actor_present"
  | "empty_note_turn_present"
  | "low_confidence_routing"
  | "routing_escalation_present" ->
      [ "broadcast" ]
  | "planned_worker_without_turn" -> [ "task_inject"; "broadcast" ]
  | "local64_role_gap" -> [ "task_inject" ]
  | "stalled_session" -> [ "namespace_pause" ]
  | "command_issue_pressure"
  | "command_routing_confidence"
  | "command_quality_per_token"
  | "command_verification_gate_failures"
  | "command_rework_rate"
  | "command_artifact_scope_drift"
  | "command_cache_contention"
  | "command_speculative_posture"
  | "intent_blocked"
  | "intent_handoff_ready" ->
      [ "broadcast" ]
  | _ -> []

let action_matches_incident incident action =
  let target_type = string_field "target_type" incident in
  let target_id = String_util.trim_to_option (string_field "target_id" incident) in
  let action_target_type = string_field "target_type" action in
  let action_target_id = String_util.trim_to_option (string_field "target_id" action) in
  let same_target =
    String.equal action_target_type target_type
    &&
    match target_id, action_target_id with
    | Some left, Some right -> String.equal left right
    | None, None -> true
    | _ -> false
  in
  if not same_target then false
  else
    let incident_summary = normalized_text_key (string_field "summary" incident) in
    let action_reason = normalized_text_key (string_field "reason" action) in
    let reason_matches =
      incident_summary <> "" && action_reason <> ""
      && String.equal incident_summary action_reason
    in
    if reason_matches then true
    else
      let action_type = string_field "action_type" action in
      List.mem action_type (incident_action_types (string_field "kind" incident))

let matching_action_for_incident incident actions =
  let target_type = string_field "target_type" incident in
  let target_id = String_util.trim_to_option (string_field "target_id" incident) in
  let candidates =
    actions
    |> List.filter (fun action ->
           let action_target_type = string_field "target_type" action in
           let action_target_id = String_util.trim_to_option (string_field "target_id" action) in
           String.equal action_target_type target_type
           &&
           match target_id, action_target_id with
           | Some left, Some right -> String.equal left right
           | None, None -> true
           | _ -> false)
  in
  match List.find_opt (action_matches_incident incident) candidates with
  | Some action -> Some action
  | None -> (match candidates with action :: _ -> Some action | [] -> None)

let rec evidence_preview_strings json =
  match json with
  | `String value ->
      let compact = compact_text value in
      if compact = "" then [] else [ compact ]
  | `List items ->
      items |> List.concat_map evidence_preview_strings |> dedup_strings |> take 4
  | `Assoc fields ->
      fields |> List.map snd |> List.concat_map evidence_preview_strings |> dedup_strings |> take 4
  | _ -> []

(* Issue #8395: root-level attention uses [target_type="workspace"].  This
   predicate previously compared only to the literal "workspace", so the
   canonical form fell through to the public queue.  Delegate to the
   shared canonical target check used by [Dashboard_briefing_assembly]. *)
let is_internal_attention incident =
  Operator_digest_types.is_root_target_type (string_field "target_type" incident)

let related_sessions_for_attention incident sessions =
  let direct_session =
    ignore incident;
    []
  in
  let actor = String_util.trim_to_option (string_field "actor" incident) in
  let by_actor =
    match actor with
    | None -> []
    | Some actor_name ->
        sessions
        |> List.filter_map (fun (session : session_context) ->
               if List.mem actor_name session.member_names then Some session.session_id
               else None)
  in
  dedup_strings (direct_session @ by_actor)

let session_by_id sessions session_id =
  List.find_opt (fun (session : session_context) -> String.equal session.session_id session_id) sessions

let build_attention_queue incidents actions sessions =
  let public_incidents =
    incidents
    |> List.filter (fun incident -> not (is_internal_attention incident))
  in
  public_incidents
  |> List.filter_map (fun incident ->
         let kind = string_field "kind" incident in
         let severity = string_field ~default:"warn" "severity" incident in
         let summary = string_field "summary" incident in
         if kind = "" || summary = "" then None
         else
           let target_type = string_field "target_type" incident in
           let target_id = String_util.trim_to_option (string_field "target_id" incident) in
           let related_session_ids = related_sessions_for_attention incident sessions in
           let related_agent_names =
             let from_sessions =
               related_session_ids
               |> List.filter_map (session_by_id sessions)
               |> List.concat_map (fun session -> session.member_names)
             in
             dedup_strings
               (from_sessions
               @
               match String_util.trim_to_option (string_field "actor" incident) with
               | Some actor -> [ actor ]
               | None -> [])
           in
           let top_action = matching_action_for_incident incident actions in
           let last_seen_at =
             related_session_ids
             |> List.filter_map (fun session_id ->
                    match session_by_id sessions session_id with
                    | Some session -> session.last_event_at
                    | None -> None)
             |> List.sort (fun left right ->
                    Float.compare
                      (Dashboard_utils.parse_iso_opt (Some right) |> Option.value ~default:0.0)
                      (Dashboard_utils.parse_iso_opt (Some left) |> Option.value ~default:0.0))
             |> function
             | value :: _ -> Some value
             | [] -> None
           in
           let id =
             Printf.sprintf "%s:%s:%s" kind target_type
               (match target_id with Some value -> value | None -> "none")
           in
           Some
             {
               severity;
               has_action = Option.is_some top_action;
               last_seen_ts =
                 Dashboard_utils.parse_iso_opt last_seen_at |> Option.value ~default:0.0;
               related_session_ids;
               related_agent_names;
               json =
                 `Assoc
                   [
                     ("id", `String id);
                     ("kind", `String kind);
                     ("severity", `String severity);
                     ("summary", `String summary);
                     ("target_type", `String target_type);
                     ("target_id", Json_util.string_opt_to_json target_id);
                     ("top_action", Json_util.option_to_yojson (fun value -> value) top_action);
                     ("related_session_ids", `List (List.map (fun value -> `String value) related_session_ids));
                     ("related_agent_names", `List (List.map (fun value -> `String value) related_agent_names));
                     ("evidence", member_assoc "evidence" incident);
                     ("evidence_preview", `List (List.map (fun value -> `String value) (evidence_preview_strings (member_assoc "evidence" incident))));
                     ("last_seen_at", Json_util.string_opt_to_json last_seen_at);
                   ];
             })
  |> List.sort (fun left right ->
         let by_severity = Int.compare (severity_rank right.severity) (severity_rank left.severity) in
         if by_severity <> 0 then by_severity
         else
           let by_action = Bool.compare right.has_action left.has_action in
           if by_action <> 0 then by_action
           else Float.compare right.last_seen_ts left.last_seen_ts)


type briefing_projection = {
  generated_at : string;
  snapshot_json : Yojson.Safe.t;
  digest_json : Yojson.Safe.t;
  namespace_json : Yojson.Safe.t;
  incidents : Yojson.Safe.t list;
  recommended_actions : Yojson.Safe.t list;
  attention_queue : attention_context list;
  sessions : session_context list;
  agent_briefs : Yojson.Safe.t list;
  keeper_briefs : Yojson.Safe.t list;
  internal_signals : Yojson.Safe.t list;
  read_errors : Yojson.Safe.t list;
}

let build_projection ?actor ~config ~sw ~clock
    ~proc_mgr () =
  let actor_name = Dashboard_projection_cache.normalize_actor_name actor in
  let ctx : _ Tool_operator.context =
    {
      config;
      agent_name = actor_name;
      sw;
      clock;
      proc_mgr;
      net = None;
      mcp_session_id = None;
    }
  in
  let snapshot_json =
    Dashboard_projection_cache.get_or_compute_snapshot_json
      ~config ~actor:(Some actor_name) (fun actor_name ->
        Dashboard_projection_cache.operator_snapshot_json
          ~actor:actor_name
          ~view:"summary"
          ~include_messages:false
          ~include_keepers:true
          ~include_summary_fields:false
          ~lightweight_summary:true
          ctx)
  in
  let digest_json =
    Dashboard_projection_cache.get_or_compute_digest_json
      ~config ~actor:(Some actor_name) (fun actor_name ->
        match Dashboard_projection_cache.operator_digest_json ~actor:actor_name ctx with
        | Ok json -> json
        | Error message ->
            `Assoc
              [
                ("health", `String "warn");
                ("attention_items", `List []);
                ("recommended_actions", `List []);
                ("error", `String message);
              ])
  in
  let namespace_json =
    match member_assoc "workspace" snapshot_json with
    | `Assoc _ as value -> value
    | _ -> member_assoc "workspace" snapshot_json
  in
  let incidents =
    list_field "attention_items" digest_json
    |> List.sort (fun left right ->
           Int.compare
             (severity_rank (string_field ~default:"ok" "severity" right))
             (severity_rank (string_field ~default:"ok" "severity" left)))
  in
  let recommended_actions = list_field "recommended_actions" digest_json in
  let sessions = [] in
  let attention_queue = build_attention_queue incidents recommended_actions sessions in
  let keeper_items =
    match member_assoc "keepers" snapshot_json |> member_assoc "items" with
    | `List items -> items
    | _ -> []
  in
  let agent_briefs, agent_brief_read_errors =
    Dashboard_briefing_assembly.build_agent_briefs_with_read_errors
      config
      sessions
      attention_queue
      namespace_json
      keeper_items
  in
  let keeper_briefs = Dashboard_briefing_assembly.build_keeper_briefs config keeper_items in
  let internal_signals = Dashboard_briefing_assembly.build_internal_signals incidents recommended_actions in
  {
    generated_at = Masc_domain.now_iso ();
    snapshot_json;
    digest_json;
    namespace_json;
    incidents;
    recommended_actions;
    attention_queue;
    sessions;
    agent_briefs;
    keeper_briefs;
    internal_signals;
    read_errors = agent_brief_read_errors;
}

let json ?actor ~config ~sw ~clock ~proc_mgr
    () =
  let projection =
    build_projection ?actor ~config ~sw
      ~clock ~proc_mgr ()
  in
  let summary_json =
    `Assoc
      [
        ("workspace_health", `String (string_field ~default:"ok" "health" projection.digest_json));
        ("cluster", Json_util.string_opt_to_json (Some (string_field "cluster" projection.namespace_json)));
        ("project", Json_util.string_opt_to_json (Some (string_field "project" projection.namespace_json)));
      ]
  in
  let command_focus_json =
    `Assoc
      [
        ("health", `String (string_field ~default:"ok" "health" projection.digest_json));
        ("active_operations", `Int 0);
        ("pending_approvals", `Int 0);
        ("top_attention", top_item projection.incidents);
        ("top_action", top_item projection.recommended_actions);
      ]
  in
  let operator_targets_json =
    `Assoc
      [
        ("keepers", `List projection.keeper_briefs);
        ("pending_confirms", member_assoc "pending_confirms" projection.snapshot_json);
        ("available_actions", member_assoc "available_actions" projection.snapshot_json);
      ]
  in
  `Assoc
    [
      ("generated_at", `String projection.generated_at);
      ("summary", summary_json);
      ("incidents", `List projection.incidents);
      ("recommended_actions", `List projection.recommended_actions);
      ("command_focus", command_focus_json);
      ("operator_targets", operator_targets_json);
      ( "attention_queue",
        `List (List.map (fun (item : attention_context) -> item.json) projection.attention_queue)
      );
      ("agent_briefs", `List projection.agent_briefs);
      ("keeper_briefs", `List projection.keeper_briefs);
      ("internal_signals", `List projection.internal_signals);
      ("read_error_count", `Int (List.length projection.read_errors));
      ("read_errors", `List projection.read_errors);
    ]

let session_json ?actor ~session_id ~config ~sw
    ~clock ~proc_mgr () =
  let projection =
    build_projection ?actor ~config ~sw
      ~clock ~proc_mgr ()
  in
  let tasks =
    if Workspace.is_initialized config then Workspace.get_tasks_safe config else []
  in
  let operation_contexts =
    Dashboard_briefing_assembly.build_operation_contexts ~tasks
  in
  let session_row_json =
    Dashboard_briefing_assembly.build_sessions
      ~operation_contexts
      projection.sessions projection.attention_queue projection.agent_briefs
      projection.keeper_briefs
    |> List.find_opt (fun json ->
           String.equal (string_field "session_id" json) session_id)
  in
  let session_source_json =
    member_assoc "sessions" projection.snapshot_json |> member_assoc "items"
    |> function
    | `List items ->
        List.find_opt
          (fun json -> String.equal (string_field "session_id" json) session_id)
          items
    | _ -> None
  in
  let session_context =
    List.find_opt
      (fun (session : session_context) -> String.equal session.session_id session_id)
      projection.sessions
  in
  let worker_runs_json =
    ignore (config, session_id);
    `Null
  in
  let operations_json =
    match session_context with
    | None -> []
    | Some session -> Dashboard_briefing_assembly.operation_badges_for_session session operation_contexts
  in
  let keepers_json =
    match session_context with
    | None -> []
    | Some session ->
        Dashboard_briefing_assembly.keeper_refs_for_session session.member_names projection.keeper_briefs
  in
  let participants_json =
    match session_context with
    | None -> []
    | Some session ->
        Dashboard_briefing_assembly.participant_preview_json session.session_id session.member_names projection.agent_briefs
  in
  `Assoc
    [
      ("generated_at", `String projection.generated_at);
      ("session_id", `String session_id);
      ("session", Json_util.option_to_yojson (fun value -> value) session_row_json);
      ( "timeline",
        `List
          (match session_source_json with
          | Some json -> Dashboard_briefing_assembly.session_timeline_json json
          | None -> []) );
      ("participants", `List participants_json);
      ("operations", `List operations_json);
      ("keepers", `List keepers_json);
      ("worker_runs", worker_runs_json);
      ("read_error_count", `Int (List.length projection.read_errors));
      ("read_errors", `List projection.read_errors);
      ( "error",
        match session_row_json with
        | Some _ -> `Null
        | None -> `String "session not found" );
    ]
