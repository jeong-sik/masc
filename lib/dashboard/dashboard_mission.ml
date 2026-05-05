module U = Yojson.Safe.Util
include Dashboard_utils

(* Types from Dashboard_mission_assembly, re-exported for backward compat. *)
type session_context = Dashboard_mission_assembly.session_context = {
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

type attention_context = Dashboard_mission_assembly.attention_context = {
  severity : string;
  has_action : bool;
  last_seen_ts : float;
  related_session_ids : string list;
  related_agent_names : string list;
  json : Yojson.Safe.t;
}

let dedup_strings items =
  List.sort_uniq String.compare
    (List.filter_map trim_to_option items)

let top_item items =
  match items with
  | item :: _ -> item
  | [] -> `Null

let session_payload_json session_json =
  match member_assoc "status" session_json with
  | `Assoc _ as payload -> payload
  | _ -> session_json

let session_meta_json session_json =
  session_payload_json session_json |> member_assoc "session"

let session_summary_json session_json =
  session_payload_json session_json |> member_assoc "summary"

let session_team_health_json session_json =
  session_payload_json session_json |> member_assoc "team_health"

let session_communication_json session_json =
  session_payload_json session_json |> member_assoc "communication_metrics"

let session_status_string session_json =
  let summary = session_summary_json session_json in
  let meta = session_meta_json session_json in
  match trim_to_option (string_field "status" summary) with
  | Some value -> value
  | None -> (
      match trim_to_option (string_field "status" meta) with
      | Some value -> value
      | None -> trim_to_option (string_field "status" session_json) |> Option.value ~default:"unknown")

let session_recent_events session_json =
  list_field "recent_events" session_json

let event_detail_json event_json =
  member_assoc "detail" event_json

let event_summary event_json =
  let detail = event_detail_json event_json in
  let event_type =
    trim_to_option (string_field "event_type" event_json)
    |> Option.value ~default:"event"
  in
  let actor =
    match trim_to_option (string_field "actor" detail) with
    | Some value -> Some value
    | None -> trim_to_option (string_field "agent" detail)
  in
  let task_title =
    match trim_to_option (string_field "task_title" detail) with
    | Some value -> Some value
    | None -> trim_to_option (string_field "title" detail)
  in
  let result = trim_to_option (compact_text (string_field "result" detail)) in
  let reason = trim_to_option (compact_text (string_field "reason" detail)) in
  let output_preview =
    trim_to_option (compact_text (string_field "output_preview" detail))
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
    trim_to_option (string_field "created_by" session_meta)
    |> Option.value ~default:"unknown"
  in
  trim_to_option (string_field "origin_kind" session_meta)
  |> Option.value
       ~default:
         (match
            trim_to_option (string_field "orchestration_mode" session_meta)
            |> Option.map String.lowercase_ascii
          with
         | Some "auto" -> "system"
         | _ -> if creator_looks_system created_by then "system" else "human")

let _build_session_context session_json _cards =
  let session_id = string_field "session_id" session_json in
  if session_id = "" then None
  else
    let meta = session_meta_json session_json in
    let summary = session_summary_json session_json in
    let team_health = session_team_health_json session_json in
    let communication = session_communication_json session_json in
    let recent_events = session_recent_events session_json in
    let last_event =
      recent_events
      |> List.sort (fun a b ->
             let left =
               parse_iso_opt (trim_to_option (string_field "ts_iso" b))
               |> Option.value ~default:0.0
             in
             let right =
               parse_iso_opt (trim_to_option (string_field "ts_iso" a))
               |> Option.value ~default:0.0
             in
             Float.compare left right)
      |> function
      | item :: _ -> Some item
      | [] -> None
    in
    let session_card = None in
    let top_attention =
      match session_card with
      | Some card -> (
          match member_assoc "top_attention" card with
          | `Null -> None
          | value -> Some value)
      | None -> None
    in
    let top_recommendation =
      match session_card with
      | Some card -> (
          match member_assoc "top_recommendation" card with
          | `Null -> None
          | value -> Some value)
      | None -> None
    in
    let operation_id = trim_to_option (string_field "operation_id" meta) in
    let mode =
      trim_to_option (string_field "mode" communication)
      |> Option.value ~default:"mode n/a"
    in
    let broadcast_count = int_field "broadcast_count" communication in
    let portal_count = int_field "portal_count" communication in
    let member_names =
      dedup_strings
        (string_list_of_json (member_assoc "agent_names" meta)
        @ string_list_of_json (member_assoc "active_agents" summary)
        @ string_list_of_json (member_assoc "planned_participants" summary))
    in
    let seen_count = int_field "seen_agents_count" summary in
    let planned_count =
      let planned = string_list_of_json (member_assoc "planned_participants" summary) in
      let explicit = List.length planned in
      if explicit > 0 then explicit else List.length member_names
    in
    let counts_basis =
      if string_list_of_json (member_assoc "planned_participants" summary) <> [] then
        "live=recent_turns · planned=planned_participants"
      else
        "live=recent_turns · planned=known_members"
    in
    let status =
      Dashboard_utils.session_lifecycle_of_string
        (session_status_string session_json)
    in
    let is_terminal = match status with
      | Dashboard_utils.SL_completed | SL_interrupted | SL_cancelled | SL_expired -> true
      | SL_active | SL_running | SL_paused | SL_failed | SL_stopped | SL_unknown -> false
    in
    let blocker_summary =
      if is_terminal then
        (* Terminal sessions cannot be blocked — suppress stale blockers *)
        None
      else
        match top_attention with
        | Some attention ->
            trim_to_option (string_field "summary" attention)
        | None ->
            if int_field "active_agents_count" team_health < int_field ~default:1 "required_agents" team_health
            then
              Some
                (Printf.sprintf "active %d / required %d"
                   (int_field "active_agents_count" team_health)
                   (int_field ~default:1 "required_agents" team_health))
            else
              Option.bind top_recommendation (fun action ->
                  trim_to_option (string_field "reason" action))
    in
    Some
      {
        session_id;
        goal =
          trim_to_option (string_field "goal" meta)
          |> Option.value ~default:session_id;
        created_by = trim_to_option (string_field "created_by" meta);
        origin_kind = session_origin_kind meta;
        namespace =
          (match trim_to_option (string_field "project" meta) with
           | Some _ as value -> value
           | None -> trim_to_option (string_field "room_id" meta));
        status;
        health =
          (if is_terminal then
             (* Terminal sessions get neutral health — no false alarms *)
             Dashboard_utils.HL_ok
           else
             let raw =
               match session_card with
               | Some card ->
                   trim_to_option (string_field "health" card)
                   |> Option.value ~default:"ok"
               | None ->
                   trim_to_option (string_field "status" team_health)
                   |> Option.value ~default:"ok"
             in
             Dashboard_utils.health_level_of_string raw);
        member_names;
        started_at = trim_to_option (string_field "created_at_iso" meta);
        elapsed_sec =
          (match member_assoc "elapsed_sec" summary with
          | `Int value -> Some value
          | `Float value -> Some (int_of_float value)
          | _ -> None);
        operation_id;
        blocker_summary;
        last_event_at =
          Option.bind last_event (fun json -> trim_to_option (string_field "ts_iso" json));
        last_event_ts =
          Option.bind last_event (fun json -> parse_iso_opt (trim_to_option (string_field "ts_iso" json)))
          |> Option.value ~default:0.0;
        last_event_summary =
          (match last_event with Some value -> event_summary value | None -> "최근 session event가 없습니다.");
        communication_summary =
          Printf.sprintf "%s · broadcast %d · portal %d" mode broadcast_count
            portal_count;
        active_count = int_field "active_agents_count" team_health;
        seen_count;
        planned_count;
        required_count = int_field ~default:1 "required_agents" team_health;
        counts_basis;
        top_attention;
        top_recommendation;
      }

let matching_action target_type target_id actions =
  List.find_opt
    (fun action ->
      let action_target_type = string_field "target_type" action in
      let action_target_id = trim_to_option (string_field "target_id" action) in
      String.equal action_target_type target_type
      &&
      match target_id, action_target_id with
      | Some left, Some right -> String.equal left right
      | None, None -> true
      | _ -> false)
    actions

let incident_action_types kind =
  match kind with
  | "spawn_failure_present" -> [ "team_task_inject" ]
  | "detached_actor_present"
  | "empty_note_turn_present"
  | "low_confidence_routing"
  | "routing_escalation_present" ->
      [ "team_note" ]
  | "planned_worker_without_turn" -> [ "team_worker_spawn_batch"; "team_note" ]
  | "local64_role_gap" -> [ "team_worker_spawn_batch" ]
  | "stalled_session" -> [ "team_stop" ]
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
  let target_id = trim_to_option (string_field "target_id" incident) in
  let action_target_type = string_field "target_type" action in
  let action_target_id = trim_to_option (string_field "target_id" action) in
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
  let target_id = trim_to_option (string_field "target_id" incident) in
  let candidates =
    actions
    |> List.filter (fun action ->
           let action_target_type = string_field "target_type" action in
           let action_target_id = trim_to_option (string_field "target_id" action) in
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

(* Issue #8395: [Operator_digest] canonicalizes root-level attention to
   [target_type="root"] but also accepts the aliases "namespace" and
   "room" via [Operator_digest_types.is_root_alias]. This predicate
   previously compared only to the literal "room", so root-level
   incidents (the canonical form) fell through to the public queue.
   Delegate to the shared alias check so every root variant is treated
   as internal attention — identical to [Dashboard_mission_assembly]. *)
let is_internal_attention incident =
  Operator_digest_types.is_root_alias (string_field "target_type" incident)

let related_sessions_for_attention incident sessions =
  let direct_session =
    ignore incident;
    []
  in
  let actor = trim_to_option (string_field "actor" incident) in
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
           let target_id = trim_to_option (string_field "target_id" incident) in
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
               match trim_to_option (string_field "actor" incident) with
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
                      (parse_iso_opt (Some right) |> Option.value ~default:0.0)
                      (parse_iso_opt (Some left) |> Option.value ~default:0.0))
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
                 parse_iso_opt last_seen_at |> Option.value ~default:0.0;
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
                     ("target_id", json_string_option target_id);
                     ("top_action", option_to_json (fun value -> value) top_action);
                     ("related_session_ids", `List (List.map (fun value -> `String value) related_session_ids));
                     ("related_agent_names", `List (List.map (fun value -> `String value) related_agent_names));
                     ("evidence_preview", `List (List.map (fun value -> `String value) (evidence_preview_strings (member_assoc "evidence" incident))));
                     ("last_seen_at", json_string_option last_seen_at);
                   ];
             })
  |> List.sort (fun left right ->
         let by_severity = Int.compare (severity_rank right.severity) (severity_rank left.severity) in
         if by_severity <> 0 then by_severity
         else
           let by_action = Bool.compare right.has_action left.has_action in
           if by_action <> 0 then by_action
           else Float.compare right.last_seen_ts left.last_seen_ts)

let _build_briefs_from_sessions sessions attention_queue actions =
  let attention_for_session session_id =
    attention_queue
    |> List.filter (fun attention -> List.mem session_id attention.related_session_ids)
  in
  sessions
  |> List.map (fun (session : session_context) ->
         let related_attentions = attention_for_session session.session_id in
         let top_attention_json =
           match related_attentions with
           | attention :: _ -> Some (member_assoc "severity" attention.json |> ignore; attention.json)
           | [] -> session.top_attention
         in
         let top_recommendation_json =
           match session.top_recommendation with
           | Some value -> Some value
           | None -> (
               match top_attention_json with
               | Some attention -> matching_action_for_incident attention actions
               | None -> matching_action "namespace" None actions)
         in
         let health_tone =
           match top_attention_json with
           | Some attention ->
               string_field
                 ~default:(Dashboard_utils.string_of_health_level session.health)
                 "severity" attention
           | None -> Dashboard_utils.string_of_health_level session.health
         in
         let related_attention_count = List.length related_attentions in
         let sort_severity = severity_rank health_tone in
         ( sort_severity,
           related_attention_count,
           session.last_event_ts,
           `Assoc
             [
               ("session_id", `String session.session_id);
               ("goal", `String session.goal);
               ("created_by", json_string_option session.created_by);
               ("namespace", json_string_option session.namespace);
               ("status", `String (Dashboard_utils.string_of_session_lifecycle session.status));
               ("health", `String (Dashboard_utils.string_of_health_level session.health));
               ("member_names", `List (List.map (fun value -> `String value) session.member_names));
               ("started_at", json_string_option session.started_at);
               ("elapsed_sec", option_to_json (fun value -> `Int value) session.elapsed_sec);
               ("operation_id", json_string_option session.operation_id);
               ("blocker_summary", json_string_option session.blocker_summary);
               ("last_event_at", json_string_option session.last_event_at);
               ("last_event_summary", `String session.last_event_summary);
               ("communication_summary", `String session.communication_summary);
               ("active_count", `Int session.active_count);
               ("seen_count", `Int session.seen_count);
               ("planned_count", `Int session.planned_count);
               ("required_count", `Int session.required_count);
               ("counts_basis", `String session.counts_basis);
               ("related_attention_count", `Int related_attention_count);
               ("top_attention", option_to_json (fun value -> value) top_attention_json);
               ("top_recommendation", option_to_json (fun value -> value) top_recommendation_json);
             ] ) )
  |> List.sort (fun (left_sev, left_count, left_ts, _) (right_sev, right_count, right_ts, _) ->
         let by_count = Int.compare right_count left_count in
         if by_count <> 0 then by_count
         else
           let by_severity = Int.compare right_sev left_sev in
           if by_severity <> 0 then by_severity else Float.compare right_ts left_ts)
  |> List.map (fun (_, _, _, json) -> json)

type mission_projection = {
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
}

let build_projection ?actor ~config ~sw ~clock
    ~proc_mgr () =
  let actor_name = Dashboard_projection_cache.normalize_actor_name actor in
  let ctx : _ Operator_control.context =
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
        Operator_control.snapshot_json
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
        match Operator_control.digest_json ~actor:actor_name ctx with
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
    match member_assoc "root" snapshot_json with
    | `Assoc _ as value -> value
    | _ -> member_assoc "room" snapshot_json
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
  let agent_briefs =
    Dashboard_mission_assembly.build_agent_briefs config sessions attention_queue namespace_json keeper_items
  in
  let keeper_briefs = Dashboard_mission_assembly.build_keeper_briefs config keeper_items in
  let internal_signals = Dashboard_mission_assembly.build_internal_signals incidents recommended_actions in
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
        ("room_health", `String (string_field ~default:"ok" "health" projection.digest_json));
        ("cluster", json_string_option (Some (string_field "cluster" projection.namespace_json)));
        ("project", json_string_option (Some (string_field "project" projection.namespace_json)));
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
    ]

let session_json ?actor ~session_id ~config ~sw
    ~clock ~proc_mgr () =
  let projection =
    build_projection ?actor ~config ~sw
      ~clock ~proc_mgr ()
  in
  let tasks =
    if Coord.is_initialized config then Coord.get_tasks_safe config else []
  in
  let operation_contexts =
    Dashboard_mission_assembly.build_operation_contexts ~tasks
  in
  let session_row_json =
    Dashboard_mission_assembly.build_sessions
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
    (* Team_session_store + Team_session_engine_eio removed *)
    ignore (config, session_id);
    `Null
  in
  let operations_json =
    match session_context with
    | None -> []
    | Some session -> Dashboard_mission_assembly.operation_badges_for_session session operation_contexts
  in
  let keepers_json =
    match session_context with
    | None -> []
    | Some session ->
        Dashboard_mission_assembly.keeper_refs_for_session session.member_names projection.keeper_briefs
  in
  let participants_json =
    match session_context with
    | None -> []
    | Some session ->
        Dashboard_mission_assembly.participant_preview_json session.session_id session.member_names projection.agent_briefs
  in
  `Assoc
    [
      ("generated_at", `String projection.generated_at);
      ("session_id", `String session_id);
      ("session", option_to_json (fun value -> value) session_row_json);
      ( "timeline",
        `List
          (match session_source_json with
          | Some json -> Dashboard_mission_assembly.session_timeline_json json
          | None -> []) );
      ("participants", `List participants_json);
      ("operations", `List operations_json);
      ("keepers", `List keepers_json);
      ("worker_runs", worker_runs_json);
      ( "error",
        match session_row_json with
        | Some _ -> `Null
        | None -> `String "session not found" );
    ]
