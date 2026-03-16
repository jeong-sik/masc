module U = Yojson.Safe.Util
open Operator_pending_confirm

let ( let* ) = Result.bind

type attention_item = {
  kind : string;
  severity : string;
  summary : string;
  target_type : string;
  target_id : string option;
  actor : string option;
  evidence : Yojson.Safe.t;
}

type recommended_action = {
  action_type : string;
  target_type : string;
  target_id : string option;
  severity : string;
  reason : string;
  suggested_payload : Yojson.Safe.t;
}

type worker_card = {
  actor : string option;
  spawn_agent : string option;
  spawn_role : string option;
  spawn_model : string option;
  execution_scope : string option;
  worker_class : string option;
  parent_actor : string option;
  capsule_mode : string option;
  runtime_pool : string option;
  lane_id : string option;
  controller_level : string option;
  control_domain : string option;
  supervisor_actor : string option;
  model_tier : string option;
  task_profile : string option;
  risk_level : string option;
  routing_confidence : float option;
  routing_reason : string option;
  status : string;
  turn_count : int;
  empty_note_turn_count : int;
  has_turn : bool;
  last_turn_age_sec : int option;
  evidence_source : string;
  last_turn_ts_iso : string option;
}

type session_digest = {
  session_id : string;
  goal : string;
  status : string;
  health : string;
  scale_profile : string;
  planned_worker_count : int;
  active_agent_count : int;
  last_turn_age_sec : int option;
  control_profile : string;
  worker_class_counts : Yojson.Safe.t;
  runtime_pool_counts : Yojson.Safe.t;
  lane_counts : Yojson.Safe.t;
  controller_counts : Yojson.Safe.t;
  control_domain_counts : Yojson.Safe.t;
  tier_counts : Yojson.Safe.t;
  task_profile_counts : Yojson.Safe.t;
  escalation_count : int;
  controller_tree : Yojson.Safe.t;
  lane_health : Yojson.Safe.t;
  confidence_heatmap : Yojson.Safe.t;
  context_pressure_by_lane : Yojson.Safe.t;
  intervention_counters : Yojson.Safe.t;
  local_runtime : Yojson.Safe.t;
  attention_items : attention_item list;
  recommended_actions : recommended_action list;
  worker_cards : worker_card list;
}

let stalled_session_threshold_sec = 300.0
let planned_worker_turn_grace_sec = 180.0
let room_digest_session_limit = 10

let severity_rank = function
  | "bad" -> 2
  | "warn" -> 1
  | _ -> 0

let compare_attention (a : attention_item) (b : attention_item) =
  let by_severity = Int.compare (severity_rank b.severity) (severity_rank a.severity) in
  if by_severity <> 0 then by_severity
  else
    match (a.target_id, b.target_id) with
    | Some x, Some y ->
        let by_target = String.compare x y in
        if by_target <> 0 then by_target else String.compare a.kind b.kind
    | Some _, None -> -1
    | None, Some _ -> 1
    | None, None -> String.compare a.kind b.kind

let compare_recommendation (a : recommended_action) (b : recommended_action) =
  let by_severity = Int.compare (severity_rank b.severity) (severity_rank a.severity) in
  if by_severity <> 0 then by_severity
  else
    match (a.target_id, b.target_id) with
    | Some x, Some y ->
        let by_target = String.compare x y in
        if by_target <> 0 then by_target else String.compare a.action_type b.action_type
    | Some _, None -> -1
    | None, Some _ -> 1
    | None, None -> String.compare a.action_type b.action_type

let compare_worker_card (a : worker_card) (b : worker_card) =
  let by_status = String.compare a.status b.status in
  if by_status <> 0 then by_status
  else
    let by_turns = Int.compare b.turn_count a.turn_count in
    if by_turns <> 0 then by_turns
    else
      String.compare
        (Option.value ~default:"" a.actor)
        (Option.value ~default:"" b.actor)

let compare_session_digest (a : session_digest) (b : session_digest) =
  let by_health = Int.compare (severity_rank b.health) (severity_rank a.health) in
  if by_health <> 0 then by_health
  else
    let by_status =
      match (a.status, b.status) with
      | "running", "running" -> 0
      | "running", _ -> -1
      | _, "running" -> 1
      | _ -> String.compare a.status b.status
    in
    if by_status <> 0 then by_status else String.compare a.session_id b.session_id

let attention_item_to_yojson (item : attention_item) =
  `Assoc
    [
      ("kind", `String item.kind);
      ("severity", `String item.severity);
      ("summary", `String item.summary);
      ("target_type", `String item.target_type);
      ("target_id", string_option_to_json item.target_id);
      ("actor", string_option_to_json item.actor);
      ("evidence", item.evidence);
      ("provenance", `String "derived");
      ("decision_engine", `String "deterministic_translation");
      ("authoritative", `Bool false);
    ]

let recommended_confirm_required = function
  | "room_pause" | "team_stop" | "task_inject" | "team_task_inject"
  | "team_worker_spawn_batch" | "swarm_run_continue"
  | "swarm_run_rerun" | "swarm_run_abandon" ->
      true
  | _ -> false

let recommended_action_to_yojson ~actor (item : recommended_action) =
  let preview =
    `Assoc
      [
        ("actor", `String actor);
        ("action_type", `String item.action_type);
        ("target_type", `String item.target_type);
        ("target_id", string_option_to_json item.target_id);
        ("payload", item.suggested_payload);
      ]
  in
  `Assoc
    [
      ("action_type", `String item.action_type);
      ("target_type", `String item.target_type);
      ("target_id", string_option_to_json item.target_id);
      ("severity", `String item.severity);
      ("reason", `String item.reason);
      ("confirm_required", `Bool (recommended_confirm_required item.action_type));
      ("suggested_payload", item.suggested_payload);
      ("preview", preview);
      ("provenance", `String "fallback");
      ("decision_engine", `String "deterministic_rules");
      ("authoritative", `Bool false);
    ]

let worker_card_to_yojson (card : worker_card) =
  `Assoc
    [
      ("actor", string_option_to_json card.actor);
      ("spawn_agent", string_option_to_json card.spawn_agent);
      ("spawn_role", string_option_to_json card.spawn_role);
      ("spawn_model", string_option_to_json card.spawn_model);
      ("execution_scope", string_option_to_json card.execution_scope);
      ("worker_class", string_option_to_json card.worker_class);
      ("parent_actor", string_option_to_json card.parent_actor);
      ("capsule_mode", string_option_to_json card.capsule_mode);
      ("runtime_pool", string_option_to_json card.runtime_pool);
      ("lane_id", string_option_to_json card.lane_id);
      ("controller_level", string_option_to_json card.controller_level);
      ("control_domain", string_option_to_json card.control_domain);
      ("supervisor_actor", string_option_to_json card.supervisor_actor);
      ("model_tier", string_option_to_json card.model_tier);
      ("task_profile", string_option_to_json card.task_profile);
      ("risk_level", string_option_to_json card.risk_level);
      ( "routing_confidence",
        option_to_json (fun value -> `Float value) card.routing_confidence );
      ("routing_reason", string_option_to_json card.routing_reason);
      ("status", `String card.status);
      ("turn_count", `Int card.turn_count);
      ("empty_note_turn_count", `Int card.empty_note_turn_count);
      ("has_turn", `Bool card.has_turn);
      ("last_turn_age_sec", option_to_json (fun value -> `Int value) card.last_turn_age_sec);
      ("evidence_source", `String card.evidence_source);
      ("last_turn_ts_iso", string_option_to_json card.last_turn_ts_iso);
      ("provenance", `String "truth");
      ("authoritative", `Bool true);
    ]

let spawn_batch_stub_of_cards (cards : worker_card list) =
  let items =
    cards
    |> List.filter_map (fun (card : worker_card) ->
           let label =
             match (card.spawn_role, card.actor) with
             | Some role, _ when String.trim role <> "" -> role
             | _, Some actor when String.trim actor <> "" -> actor
             | _ -> "worker"
           in
           let fields =
             [
               ( "spawn_prompt",
                 `String
                   (Printf.sprintf
                      "REQUIRED: provide explicit spawn_prompt for replacement worker %s"
                      label) );
             ]
           in
           let fields =
             match card.execution_scope with
             | Some execution_scope when String.trim execution_scope <> "" ->
                 ("execution_scope", `String execution_scope) :: fields
             | _ -> fields
           in
               let fields =
                 match card.spawn_role with
                 | Some role when String.trim role <> "" ->
                     ("spawn_role", `String role) :: fields
                 | _ -> fields
               in
               let fields =
                 match
                   Option.bind card.model_tier
                     (fun raw ->
                       Team_session_types.model_tier_of_string
                         (String.lowercase_ascii (String.trim raw)))
                   |> Option.map Team_session_types.worker_size_of_model_tier
                   |> Option.join
                 with
                 | Some worker_size ->
                     ( "worker_size",
                       `String
                         (Team_session_types.worker_size_to_string worker_size) )
                     :: fields
                 | _ -> fields
               in
               let fields =
                 match card.worker_class with
                 | Some worker_class when String.trim worker_class <> "" ->
                     ("worker_class", `String worker_class) :: fields
                 | _ -> fields
               in
               let fields =
                 match card.parent_actor with
                 | Some parent_actor when String.trim parent_actor <> "" ->
                     ("parent_actor", `String parent_actor) :: fields
                 | _ -> fields
               in
               let fields =
                 match card.capsule_mode with
                 | Some capsule_mode when String.trim capsule_mode <> "" ->
                     ("capsule_mode", `String capsule_mode) :: fields
                 | _ -> fields
               in
               let fields =
                 match card.runtime_pool with
                 | Some runtime_pool when String.trim runtime_pool <> "" ->
                     ("runtime_pool", `String runtime_pool) :: fields
                 | _ -> fields
               in
               let fields =
                 match card.lane_id with
                 | Some lane_id when String.trim lane_id <> "" ->
                     ("lane_id", `String lane_id) :: fields
                 | _ -> fields
               in
               let fields =
                 match card.control_domain with
                 | Some control_domain when String.trim control_domain <> "" ->
                     ("control_domain", `String control_domain) :: fields
                 | _ -> fields
               in
               let fields =
                 match card.supervisor_actor with
                 | Some supervisor_actor when String.trim supervisor_actor <> "" ->
                     ("supervisor_actor", `String supervisor_actor) :: fields
                 | _ -> fields
               in
               let fields =
                 match card.task_profile with
                 | Some task_profile when String.trim task_profile <> "" ->
                     ("task_profile", `String task_profile) :: fields
                 | _ -> fields
               in
           let fields =
             match card.risk_level with
             | Some risk_level when String.trim risk_level <> "" ->
                 ("risk_level", `String risk_level) :: fields
             | _ -> fields
           in
           Some (`Assoc (List.rev fields)))
  in
  `Assoc [ ("spawn_batch", `List items) ]

let aggregate_worker_class_counts (sessions : Team_session_types.session list) =
  sessions
  |> List.concat_map (fun (session : Team_session_types.session) -> session.planned_workers)
  |> Team_session_types.worker_class_counts
  |> Team_session_types.counts_to_json

let aggregate_runtime_pool_counts (sessions : Team_session_types.session list) =
  sessions
  |> List.concat_map (fun (session : Team_session_types.session) -> session.planned_workers)
  |> Team_session_types.runtime_pool_counts
  |> Team_session_types.counts_to_json

let aggregate_lane_counts (sessions : Team_session_types.session list) =
  sessions
  |> List.concat_map (fun (session : Team_session_types.session) -> session.planned_workers)
  |> Team_session_types.lane_counts
  |> Team_session_types.counts_to_json

let aggregate_controller_counts (sessions : Team_session_types.session list) =
  sessions
  |> List.concat_map (fun (session : Team_session_types.session) -> session.planned_workers)
  |> Team_session_types.controller_level_counts
  |> Team_session_types.counts_to_json

let aggregate_control_domain_counts (sessions : Team_session_types.session list) =
  sessions
  |> List.concat_map (fun (session : Team_session_types.session) -> session.planned_workers)
  |> Team_session_types.control_domain_counts
  |> Team_session_types.counts_to_json

let aggregate_tier_counts (sessions : Team_session_types.session list) =
  sessions
  |> List.concat_map (fun (session : Team_session_types.session) -> session.planned_workers)
  |> Team_session_types.model_tier_counts
  |> Team_session_types.counts_to_json

let aggregate_task_profile_counts (sessions : Team_session_types.session list) =
  sessions
  |> List.concat_map (fun (session : Team_session_types.session) -> session.planned_workers)
  |> Team_session_types.task_profile_counts
  |> Team_session_types.counts_to_json

let aggregate_escalation_count (sessions : Team_session_types.session list) =
  sessions
  |> List.concat_map (fun (session : Team_session_types.session) -> session.planned_workers)
  |> Team_session_types.escalation_count

let aggregated_local_runtime_json (sessions : Team_session_types.session list) =
  if
    List.exists
      (fun (session : Team_session_types.session) ->
        session.scale_profile = Team_session_types.Scale_local64)
      sessions
  then Tool_llama.runtime_status_json ()
  else `Null

let session_card_to_yojson ~actor (digest : session_digest) =
  let top_attention =
    match digest.attention_items |> List.sort compare_attention with
    | item :: _ -> Some item
    | [] -> None
  in
  let top_recommendation =
    match digest.recommended_actions |> List.sort compare_recommendation with
    | item :: _ -> Some item
    | [] -> None
  in
  `Assoc
    [
      ("session_id", `String digest.session_id);
      ("goal", `String digest.goal);
      ("status", `String digest.status);
      ("health", `String digest.health);
      ("scale_profile", `String digest.scale_profile);
      ("control_profile", `String digest.control_profile);
      ("planned_worker_count", `Int digest.planned_worker_count);
      ("active_agent_count", `Int digest.active_agent_count);
      ("last_turn_age_sec", option_to_json (fun v -> `Int v) digest.last_turn_age_sec);
      ("worker_class_counts", digest.worker_class_counts);
      ("runtime_pool_counts", digest.runtime_pool_counts);
      ("lane_counts", digest.lane_counts);
      ("controller_counts", digest.controller_counts);
      ("control_domain_counts", digest.control_domain_counts);
      ("tier_counts", digest.tier_counts);
      ("task_profile_counts", digest.task_profile_counts);
      ("escalation_count", `Int digest.escalation_count);
      ("controller_tree", digest.controller_tree);
      ("lane_health", digest.lane_health);
      ("confidence_heatmap", digest.confidence_heatmap);
      ("context_pressure_by_lane", digest.context_pressure_by_lane);
      ("intervention_counters", digest.intervention_counters);
      ("local_runtime", digest.local_runtime);
      ("attention_count", `Int (List.length digest.attention_items));
      ("top_attention", option_to_json attention_item_to_yojson top_attention);
      ("recommended_action_count", `Int (List.length digest.recommended_actions));
      ( "top_recommendation",
        option_to_json (recommended_action_to_yojson ~actor) top_recommendation );
      ("provenance", `String "derived");
      ("authoritative", `Bool false);
    ]

let summary_of_attention_items (items : attention_item list) =
  let sorted = List.sort compare_attention items in
  let top_item : attention_item option =
    match sorted with item :: _ -> Some item | [] -> None
  in
  let bad_count =
    List.fold_left
      (fun acc (item : attention_item) ->
        if String.equal item.severity "bad" then acc + 1 else acc)
      0 sorted
  in
  let warn_count =
    List.fold_left
      (fun acc (item : attention_item) ->
        if String.equal item.severity "warn" then acc + 1 else acc)
      0 sorted
  in
  `Assoc
    [
      ("count", `Int (List.length sorted));
      ("bad_count", `Int bad_count);
      ("warn_count", `Int warn_count);
      ("top_item", option_to_json attention_item_to_yojson top_item);
      ("provenance", `String "derived");
      ("authoritative", `Bool false);
    ]

let dedup_recommendations (items : recommended_action list) =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | (item : recommended_action) :: rest ->
        let key =
          String.concat "|"
            [
              item.action_type;
              item.target_type;
              Option.value ~default:"" item.target_id;
              String.trim item.reason |> String.lowercase_ascii;
            ]
        in
        if List.mem key seen then loop seen acc rest
        else loop (key :: seen) (item :: acc) rest
  in
  items |> List.sort compare_recommendation |> loop [] []

let summary_of_recommendations ~actor (items : recommended_action list) =
  let sorted = dedup_recommendations items in
  let top_item : recommended_action option =
    match sorted with item :: _ -> Some item | [] -> None
  in
  `Assoc
    [
      ("count", `Int (List.length sorted));
      ( "top_action",
        option_to_json (recommended_action_to_yojson ~actor) top_item );
      ("provenance", `String "fallback");
      ("authoritative", `Bool false);
    ]

let judgment_surface_for_target_type = function
  | "room" -> "command.warroom"
  | "team_session" -> "command.swarm"
  | _ -> "command.warroom"

let judgment_target_type_of_string = function
  | "room" -> Operator_judgment.Room
  | "team_session" -> Operator_judgment.Team_session
  | _ -> Operator_judgment.Room

let fresh_operator_judgment config ~target_type ~target_id =
  let judgment_target_type = judgment_target_type_of_string target_type in
  let surface = judgment_surface_for_target_type target_type in
  match
    Operator_judgment.latest_active config ~surface
      ~target_type:judgment_target_type ~target_id
  with
  | Some value when Operator_judgment.is_fresh value ->
      Some (Operator_judgment.to_yojson value)
  | _ -> None

let judgment_summary_json judgment_json =
  `Assoc
    [
      ("summary", judgment_json |> U.member "summary");
      ("confidence", judgment_json |> U.member "confidence");
      ("provenance", `String "judgment");
      ("authoritative", `Bool true);
      ("surface", judgment_json |> U.member "surface");
      ("fresh_until", judgment_json |> U.member "fresh_until");
      ("keeper_name", judgment_json |> U.member "keeper_name");
      ("fallback_used", judgment_json |> U.member "fallback_used");
      ("disagreement_with_truth", judgment_json |> U.member "disagreement_with_truth");
    ]

let active_guidance_fields ~config ~actor ~target_type ~target_id
    ~fallback_recommendations ~fallback_summary =
  let fallback_recommendation_json =
    `List
      (List.map (recommended_action_to_yojson ~actor) fallback_recommendations)
  in
  match fresh_operator_judgment config ~target_type ~target_id with
  | Some judgment_json ->
      let judgment_actions =
        match judgment_json |> U.member "recommended_action" with
        | `Assoc _ as value -> `List [ value ]
        | _ -> fallback_recommendation_json
      in
      let recommendation_source =
        match judgment_json |> U.member "recommended_action" with
        | `Assoc _ -> "judgment"
        | _ -> "fallback"
      in
      [
        ("judgment_owner", `String "resident_operator_keeper");
        ("authoritative_judgment_available", `Bool true);
        ("judgment", judgment_json);
        ("active_guidance_layer", `String "judgment");
        ("active_summary", judgment_summary_json judgment_json);
        ("active_recommended_actions", judgment_actions);
        ("active_recommendation_source", `String recommendation_source);
        ("active_recommendation_summary", judgment_summary_json judgment_json);
        ("fallback_recommended_actions", fallback_recommendation_json);
      ]
  | None ->
      [
        ("judgment_owner", `String "fallback_read_model");
        ("authoritative_judgment_available", `Bool false);
        ("judgment", `Null);
        ("active_guidance_layer", `String "fallback");
        ("active_summary", fallback_summary);
        ("active_recommended_actions", fallback_recommendation_json);
        ("active_recommendation_source", `String "fallback");
        ("active_recommendation_summary", fallback_summary);
        ("fallback_recommended_actions", fallback_recommendation_json);
      ]

let event_ts_iso json =
  match U.member "ts_iso" json with `String value -> Some value | _ -> None

let event_ts_unix json =
  match U.member "ts" json with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | `Intlit raw -> float_of_string_opt raw
  | _ -> (
      match event_ts_iso json with
      | Some iso -> Resilience.Time.parse_iso8601_opt iso
      | None -> None)

let event_type json =
  match U.member "event_type" json with `String value -> Some value | _ -> None

let event_detail_actor json =
  match U.member "detail" json |> U.member "actor" with
  | `String actor ->
      let trimmed = String.trim actor in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let event_detail_kind json =
  match U.member "detail" json |> U.member "kind" with
  | `String kind ->
      let trimmed = String.trim kind in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let event_detail_message json =
  match U.member "detail" json |> U.member "message" with
  | `String message ->
      let trimmed = String.trim message in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let count_spawn_failures events =
  List.fold_left
    (fun acc json ->
      match (event_type json, U.member "detail" json |> U.member "success") with
      | Some "team_step_spawn", `Bool false -> acc + 1
      | _ -> acc)
    0 events

let count_detached_actors events =
  List.fold_left
    (fun acc json ->
      match event_type json with
      | Some "session_agent_detached" -> acc + 1
      | _ -> acc)
    0 events

let empty_note_turn_actors events =
  events
  |> List.filter_map (fun json ->
         match (event_type json, event_detail_kind json, event_detail_actor json) with
         | Some "team_turn", Some "note", Some actor -> (
             match event_detail_message json with None -> Some actor | Some _ -> None)
         | _ -> None)
  |> Team_session_types.dedup_strings

let turn_count_by_actor events actor_name =
  List.fold_left
    (fun acc json ->
      match (event_type json, event_detail_actor json) with
      | Some "team_turn", Some actor when String.equal actor actor_name -> acc + 1
      | _ -> acc)
    0 events

let empty_note_turn_count_for_actor events actor_name =
  List.fold_left
    (fun acc json ->
      match (event_type json, event_detail_kind json, event_detail_actor json) with
      | Some "team_turn", Some "note", Some actor when String.equal actor actor_name -> (
          match event_detail_message json with None -> acc + 1 | Some _ -> acc)
      | _ -> acc)
    0 events

let last_turn_ts_iso_for_actor events actor_name =
  events
  |> List.filter_map (fun json ->
         match (event_type json, event_detail_actor json) with
         | Some "team_turn", Some actor when String.equal actor actor_name ->
             event_ts_iso json
         | _ -> None)
  |> List.rev |> function value :: _ -> Some value | [] -> None

let last_turn_age_sec_for_actor events actor_name ~now =
  events
  |> List.filter_map (fun json ->
         match (event_type json, event_detail_actor json) with
         | Some "team_turn", Some actor when String.equal actor actor_name ->
             event_ts_unix json
         | _ -> None)
  |> List.rev
  |> function
  | ts :: _ -> Some (max 0 (int_of_float (now -. ts)))
  | [] -> None

let normalize_digest_target_type value =
  match value with
  | Some raw -> (
      match String.trim raw |> String.lowercase_ascii with
      | "room" -> Ok "room"
      | "team_session" -> Ok "team_session"
      | _ -> Error "target_type must be one of: room, team_session")
  | None -> Ok "room"

let build_worker_cards ~(session : Team_session_types.session) ~(events : Yojson.Safe.t list)
    ~now =
  let worker_keys =
    if session.planned_workers <> [] then
      session.planned_workers
      |> List.map (fun (worker : Team_session_types.planned_worker) ->
             ( worker.runtime_actor,
               Some worker.spawn_agent,
               worker.spawn_role,
               worker.spawn_model,
               Option.map Team_session_types.execution_scope_to_string
                 worker.execution_scope,
               Option.map Team_session_types.worker_class_to_string
                 worker.worker_class,
               worker.parent_actor,
               Option.map Team_session_types.capsule_mode_to_string
                 worker.capsule_mode,
               worker.runtime_pool,
               worker.lane_id,
               Option.map Team_session_types.controller_level_to_string
                 worker.controller_level,
               Option.map Team_session_types.control_domain_to_string
                 worker.control_domain,
               worker.supervisor_actor,
               Option.map Team_session_types.model_tier_to_string
                 worker.model_tier,
               Option.map Team_session_types.task_profile_to_string
                 worker.task_profile,
               Option.map Team_session_types.risk_level_to_string
                 worker.risk_level,
               worker.routing_confidence,
               worker.routing_reason ))
    else
      session.agent_names
      |> List.map (fun actor ->
               ( Some actor,
                 None,
                 None,
                 None,
                 None,
                 None,
                 None,
               None,
               None,
               None,
               None,
               None,
               None,
               None,
               None,
               None,
               None,
               None ))
  in
  worker_keys
  |> List.map
       (fun
         ( actor,
           spawn_agent,
           spawn_role,
           spawn_model,
           execution_scope,
           worker_class,
           parent_actor,
           capsule_mode,
           runtime_pool,
           lane_id,
           controller_level,
           control_domain,
           supervisor_actor,
           model_tier,
           task_profile,
           risk_level,
           routing_confidence,
           routing_reason ) ->
         let turn_count =
           match actor with
           | Some value -> turn_count_by_actor events value
           | None -> 0
         in
         let empty_note_turn_count =
           match actor with
           | Some value -> empty_note_turn_count_for_actor events value
           | None -> 0
         in
         let has_turn = turn_count > 0 in
         let last_turn_ts_iso =
           match actor with
           | Some value -> last_turn_ts_iso_for_actor events value
           | None -> None
        in
        let last_turn_age_sec =
          match actor with
          | Some value -> last_turn_age_sec_for_actor events value ~now
          | None -> None
        in
        let status =
          match actor with
          | Some _ ->
              let bootstrap_age_sec = now -. session.started_at in
              if has_turn then (
                match last_turn_age_sec with
                | Some age when age <= int_of_float stalled_session_threshold_sec ->
                    "live"
                | Some _ -> "stale_turn"
                | None -> "seen_no_timestamp")
              else if bootstrap_age_sec >= planned_worker_turn_grace_sec then
                "planned_no_turn"
              else "grace_period"
           | None -> "planned"
         in
         let evidence_source =
           match (has_turn, last_turn_age_sec) with
           | false, _ -> "spawn_only"
           | true, Some age when age <= int_of_float stalled_session_threshold_sec ->
               "turn_live"
           | true, Some _ -> "turn_stale"
           | true, None -> "turn_seen"
         in
         {
           actor;
           spawn_agent;
           spawn_role;
           spawn_model;
           execution_scope;
           worker_class;
           parent_actor;
           capsule_mode;
           runtime_pool;
           lane_id;
           controller_level;
           control_domain;
           supervisor_actor;
           model_tier;
           task_profile;
           risk_level;
           routing_confidence;
           routing_reason;
           status;
           turn_count;
           empty_note_turn_count;
           has_turn;
           last_turn_age_sec;
           evidence_source;
           last_turn_ts_iso;
         })
  |> List.sort compare_worker_card

let session_attention_items ~(session : Team_session_types.session)
    ~(events : Yojson.Safe.t list) ~(worker_cards : worker_card list) ~now =
  let spawn_failure_count = count_spawn_failures events in
  let detached_actor_count = count_detached_actors events in
  let empty_note_actors = empty_note_turn_actors events in
  let low_confidence_cards =
    worker_cards
    |> List.filter (fun (card : worker_card) ->
           match card.routing_confidence with
           | Some value -> value < 0.72
           | None -> false)
  in
  let escalated_worker_count =
    session.planned_workers
    |> List.fold_left
         (fun acc (worker : Team_session_types.planned_worker) ->
           if worker.routing_escalated then acc + 1 else acc)
         0
  in
  let local64_missing_roles =
    if
      session.scale_profile = Team_session_types.Scale_local64
      && session.planned_workers <> []
    then
      let present_roles =
        session.planned_workers
        |> List.filter_map (fun (worker : Team_session_types.planned_worker) ->
               Option.map Team_session_types.worker_class_to_string worker.worker_class)
      in
      [ "manager"; "metacog"; "librarian"; "scout" ]
      |> List.filter (fun role -> not (List.mem role present_roles))
    else []
  in
  let base = [] in
  let base =
    if low_confidence_cards <> [] then
      {
        kind = "low_confidence_routing";
        severity = "warn";
        summary =
          Printf.sprintf "%d worker(s) have low routing confidence"
            (List.length low_confidence_cards);
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence =
          `Assoc
            [
              ( "actors",
                `List
                  (List.filter_map
                     (fun (card : worker_card) ->
                       Option.map (fun actor -> `String actor) card.actor)
                     low_confidence_cards) );
            ];
      }
      :: base
    else base
  in
  let base =
    if escalated_worker_count > 0 then
      {
        kind = "routing_escalation_present";
        severity = "warn";
        summary =
          Printf.sprintf "%d worker(s) were escalated to a higher tier"
            escalated_worker_count;
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence = `Assoc [ ("count", `Int escalated_worker_count) ];
      }
      :: base
    else base
  in
  let base =
    if spawn_failure_count > 0 then
      {
        kind = "spawn_failure_present";
        severity = "bad";
        summary =
          Printf.sprintf "session has %d failed spawn event(s)" spawn_failure_count;
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence = `Assoc [ ("count", `Int spawn_failure_count) ];
      }
      :: base
    else base
  in
  let base =
    if detached_actor_count > 0 then
      {
        kind = "detached_actor_present";
        severity = "warn";
        summary =
          Printf.sprintf "session detached %d runtime actor(s)"
            detached_actor_count;
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence = `Assoc [ ("count", `Int detached_actor_count) ];
      }
      :: base
    else base
  in
  let base =
    if local64_missing_roles <> [] then
      {
        kind = "local64_role_gap";
        severity = "warn";
        summary =
          Printf.sprintf "local64 session is missing swarm support roles: %s"
            (String.concat ", " local64_missing_roles);
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence =
          `Assoc
            [
              ( "missing_roles",
                `List (List.map (fun role -> `String role) local64_missing_roles) );
            ];
      }
      :: base
    else base
  in
  let base =
    if empty_note_actors <> [] then
      {
        kind = "empty_note_turn_present";
        severity = "warn";
        summary = "session contains historical empty note turn evidence";
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence =
          `Assoc
            [
              ("count", `Int (List.length empty_note_actors));
              ("actors", `List (List.map (fun actor -> `String actor) empty_note_actors));
            ];
      }
      :: base
    else base
  in
  let age_since_last_turn =
    now -. Option.value ~default:session.started_at session.last_turn_at
  in
  let base =
    if session.status = Team_session_types.Running
       && session.planned_workers <> []
       && age_since_last_turn >= stalled_session_threshold_sec
    then
      {
        kind = "stalled_session";
        severity = "bad";
        summary =
          Printf.sprintf "session has been idle for %d seconds"
            (int_of_float age_since_last_turn);
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence =
          `Assoc
            [
              ("last_turn_age_sec", `Int (int_of_float age_since_last_turn));
              ( "last_turn_at",
                option_to_json (fun value -> `Float value) session.last_turn_at );
            ];
      }
      :: base
    else base
  in
  let no_turn_workers =
    if session.status = Team_session_types.Running
       && now -. session.started_at >= planned_worker_turn_grace_sec
    then
      worker_cards
      |> List.filter (fun (card : worker_card) ->
             String.equal card.status "planned_no_turn"
             && Option.value ~default:"" card.actor <> "")
    else []
  in
  let base =
    if no_turn_workers <> [] then
      {
        kind = "planned_worker_without_turn";
        severity = "warn";
        summary =
          Printf.sprintf "%d planned worker(s) have not recorded a turn"
            (List.length no_turn_workers);
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence =
          `Assoc
            [
              ( "actors",
                `List
                  (List.filter_map
                     (fun (card : worker_card) ->
                       Option.map (fun actor -> `String actor) card.actor)
                     no_turn_workers) );
            ];
      }
      :: base
    else base
  in
  List.sort compare_attention base

let session_recommendations ~(session : Team_session_types.session)
    ~(attentions : attention_item list) ~(worker_cards : worker_card list) =
  let no_turn_worker_cards =
    worker_cards
    |> List.filter (fun (card : worker_card) ->
           String.equal card.status "planned_no_turn"
           && Option.is_some card.spawn_agent)
  in
  let suggestions =
    attentions
    |> List.filter_map (fun item ->
           match item.kind with
           | "spawn_failure_present" ->
               Some
                 {
                   action_type = "team_task_inject";
                   target_type = "team_session";
                   target_id = Some session.session_id;
                   severity = item.severity;
                   reason = item.summary;
                   suggested_payload =
                     `Assoc
                       [
                         ("title", `String "Recover failed worker coverage");
                         ( "description",
                           `String
                             "Spawn failure evidence is present. Add explicit recovery work or reassign the missing worker contribution." );
                         ("priority", `Int 1);
                       ];
                 }
           | "detached_actor_present" ->
               Some
                 {
                   action_type = "team_note";
                   target_type = "team_session";
                   target_id = Some session.session_id;
                   severity = item.severity;
                   reason = item.summary;
                   suggested_payload =
                     `Assoc
                       [
                         ( "message",
                           `String
                             "[operator] A runtime actor detached. Reassign the missing work and record the replacement explicitly." );
                       ];
                 }
           | "empty_note_turn_present" ->
               Some
                 {
                   action_type = "team_note";
                   target_type = "team_session";
                   target_id = Some session.session_id;
                   severity = item.severity;
                   reason = item.summary;
                   suggested_payload =
                     `Assoc
                       [
                         ( "message",
                           `String
                             "[operator] Record explicit non-empty contribution notes for each worker turn." );
                       ];
                 }
           | "stalled_session" ->
               Some
                 {
                   action_type = "team_stop";
                   target_type = "team_session";
                   target_id = Some session.session_id;
                   severity = item.severity;
                   reason = item.summary;
                   suggested_payload =
                     `Assoc
                       [
                         ("reason", `String "stalled_session_detected");
                         ("generate_report", `Bool true);
                       ];
                 }
           | "planned_worker_without_turn" ->
               if no_turn_worker_cards = [] then
                 Some
                   {
                     action_type = "team_note";
                     target_type = "team_session";
                     target_id = Some session.session_id;
                     severity = item.severity;
                     reason = item.summary;
                     suggested_payload =
                       `Assoc
                         [
                           ( "message",
                             `String
                               "[operator] Planned workers have not reported yet. Record a concrete progress note or detach and replace the missing worker." );
                         ];
                   }
               else
                 Some
                   {
                     action_type = "team_worker_spawn_batch";
                     target_type = "team_session";
                     target_id = Some session.session_id;
                     severity = item.severity;
                     reason = item.summary;
                   suggested_payload =
                       spawn_batch_stub_of_cards no_turn_worker_cards;
                   }
           | "local64_role_gap" ->
	               let missing_roles =
	                 match item.evidence |> U.member "missing_roles" with
	                 | `List xs ->
	                     xs
	                     |> List.filter_map (function
	                          | `String role when String.trim role <> "" ->
	                              Some (String.trim role)
	                          | _ -> None)
	                 | _ -> []
	               in
	               let spawn_batch =
	                 missing_roles
	                 |> List.map (fun role ->
	                        let spawn_role, capsule_mode =
	                          match role with
	                          | "manager" -> ("middle-manager", "capsule")
	                          | "metacog" -> ("metacog-observer", "capsule")
	                          | "librarian" -> ("knowledge-librarian", "capsule")
	                          | "scout" -> ("research-scout", "fresh")
	                          | other -> (other, "fresh")
	                        in
	                        `Assoc
	                          [
	                            ( "spawn_prompt",
	                              `String
	                                (Printf.sprintf
	                                   "REQUIRED: provide explicit spawn_prompt for local64 %s role"
	                                   role) );
	                            ("spawn_role", `String spawn_role);
	                            ("worker_class", `String role);
	                            ("capsule_mode", `String capsule_mode);
	                            ("runtime_pool", `String "local64");
	                          ])
	               in
	               Some
	                 {
	                   action_type = "team_worker_spawn_batch";
	                   target_type = "team_session";
	                   target_id = Some session.session_id;
	                   severity = item.severity;
	                   reason = item.summary;
	                   suggested_payload = `Assoc [ ("spawn_batch", `List spawn_batch) ];
	                 }
           | "low_confidence_routing" ->
               Some
                 {
                   action_type = "team_note";
                   target_type = "team_session";
                   target_id = Some session.session_id;
                   severity = item.severity;
                   reason = item.summary;
                   suggested_payload =
                     `Assoc
                       [
                         ( "message",
                           `String
                             "[operator] Low-confidence routing detected. Re-check ambiguous workers and escalate disputed outputs to 35B." );
                       ];
                 }
           | "routing_escalation_present" ->
               Some
                 {
                   action_type = "team_note";
                   target_type = "team_session";
                   target_id = Some session.session_id;
                   severity = item.severity;
                   reason = item.summary;
                   suggested_payload =
                     `Assoc
                       [
                         ( "message",
                           `String
                             "[operator] Tier escalation is active. Audit the escalated workers and keep final judgment on 35B." );
                       ];
                 }
	           | _ -> None)
  in
  dedup_recommendations suggestions

let health_from_attention_items (items : attention_item list) =
  if
    List.exists
      (fun (item : attention_item) -> String.equal item.severity "bad")
      items
  then "bad"
  else if items <> [] then "warn"
  else "ok"

let normalize_team_health = function
  | "healthy" -> "ok"
  | "degraded" -> "warn"
  | "critical" -> "bad"
  | other -> other

let build_session_digest config (session : Team_session_types.session) ~now =
  let status_json = Team_session_engine_eio.session_status_json config session in
  let summary = U.member "summary" status_json in
  let team_health = U.member "team_health" status_json in
  let events = Team_session_store.read_events ~max_events:2000 config session.session_id in
  let worker_cards = build_worker_cards ~session ~events ~now in
  let attention_items = session_attention_items ~session ~events ~worker_cards ~now in
  let recommended_actions =
    session_recommendations ~session ~attentions:attention_items ~worker_cards
  in
  let active_agent_count =
    match U.member "active_agents" summary with
    | `List xs -> List.length xs
    | _ -> 0
  in
  let last_turn_age_sec =
    match session.last_turn_at with
    | Some ts -> Some (max 0 (int_of_float (now -. ts)))
    | None when session.status = Team_session_types.Running ->
        Some (max 0 (int_of_float (now -. session.started_at)))
    | None -> None
  in
  {
    session_id = session.session_id;
    goal = session.goal;
    status =
      (match U.member "session" status_json |> U.member "status" with
      | `String status -> status
      | _ -> Team_session_types.status_to_string session.status);
    health =
      (let attention_health = health_from_attention_items attention_items in
       if not (String.equal attention_health "ok") then attention_health
       else
         match U.member "status" team_health with
         | `String status -> normalize_team_health status
         | _ -> attention_health);
    scale_profile =
      (match U.member "scale_profile" summary with
      | `String value -> value
      | _ -> Team_session_types.scale_profile_to_string session.scale_profile);
    control_profile =
      (match U.member "control_profile" summary with
      | `String value -> value
      | _ ->
          Team_session_types.control_profile_to_string session.control_profile);
    planned_worker_count = List.length session.planned_workers;
    active_agent_count;
    last_turn_age_sec;
    worker_class_counts =
      (match U.member "worker_class_counts" summary with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.worker_class_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    runtime_pool_counts =
      (match U.member "runtime_pool_counts" summary with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.runtime_pool_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    lane_counts =
      (match U.member "lane_counts" summary with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.lane_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    controller_counts =
      (match U.member "controller_counts" summary with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.controller_level_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    control_domain_counts =
      (match U.member "control_domain_counts" summary with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.control_domain_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    tier_counts =
      (match U.member "tier_counts" summary with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.model_tier_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    task_profile_counts =
      (match U.member "task_profile_counts" summary with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.task_profile_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    escalation_count =
      (match U.member "escalation_count" summary with
      | `Int value -> value
      | `Intlit raw -> (try int_of_string raw with Failure _ -> 0)
      | _ -> Team_session_types.escalation_count session.planned_workers);
    controller_tree =
      (match U.member "controller_tree" summary with
      | `Assoc _ as json -> json
      | _ -> `Assoc []);
    lane_health =
      (match U.member "lane_health" summary with
      | `Assoc _ as json -> json
      | _ -> `Assoc []);
    confidence_heatmap =
      (match U.member "confidence_heatmap" summary with
      | `Assoc _ as json -> json
      | _ -> `Assoc []);
    context_pressure_by_lane =
      (match U.member "context_pressure_by_lane" summary with
      | `Assoc _ as json -> json
      | _ -> `Assoc []);
    intervention_counters =
      (match U.member "intervention_counters" summary with
      | `Assoc _ as json -> json
      | _ -> `Assoc []);
    local_runtime =
      (match U.member "local_runtime" status_json with
      | `Assoc _ as json -> json
      | `Null as json -> json
      | _ -> `Null);
    attention_items;
    recommended_actions;
    worker_cards;
  }

let build_room_attention_items ?command_plane_summary config =
  let command_plane_summary =
    match command_plane_summary with
    | Some s -> s
    | None -> Command_plane_v2.summary_json config
  in
  let microarch_signals =
    command_plane_summary
    |> U.member "operations"
    |> U.member "microarch"
    |> U.member "signals"
  in
  let intent_summary =
    command_plane_summary
    |> U.member "intents"
    |> U.member "summary"
  in
  let signal_items =
    [
      ( "command_issue_pressure",
        "command-plane issue pressure is elevated",
        microarch_signals |> U.member "issue_pressure" );
      ( "command_cache_contention",
        "command-plane cache contention is elevated",
        microarch_signals |> U.member "cache_contention" );
      ( "command_scheduler_efficiency",
        "command-plane scheduler efficiency is degraded",
        microarch_signals |> U.member "scheduler_efficiency" );
      ( "command_routing_confidence",
        "command-plane routing confidence is degraded",
        microarch_signals |> U.member "routing_confidence" );
      ( "command_quality_per_token",
        "command-plane quality-per-token is degraded",
        microarch_signals |> U.member "quality_per_token" );
      ( "command_verification_gate_failures",
        "command-plane verification gate failures are accumulating",
        microarch_signals |> U.member "verification_gate_failures" );
      ( "command_rework_rate",
        "command-plane rework rate is elevated",
        microarch_signals |> U.member "rework_rate" );
      ( "command_artifact_scope_drift",
        "command-plane artifact scope drift is elevated",
        microarch_signals |> U.member "artifact_scope_drift" );
      ( "command_speculative_posture",
        "command-plane speculative posture needs review",
        microarch_signals |> U.member "speculative_posture" );
    ]
    |> List.filter_map (fun (kind, summary, signal_json) ->
           match signal_json |> U.member "tone" with
           | `String "warn" ->
               Some
                 {
                   kind;
                   severity = "warn";
                   summary;
                   target_type = "room";
                   target_id = None;
                   actor = None;
                   evidence = signal_json;
                 }
           | `String "bad" ->
               Some
                 {
                   kind;
                   severity = "bad";
                   summary;
                   target_type = "room";
                   target_id = None;
                   actor = None;
                   evidence = signal_json;
                 }
           | _ -> None)
  in
  let intent_items =
    [
      ( "intent_blocked",
        "blocked intents need intervention",
        intent_summary |> U.member "blocked",
        "blocked" );
      ( "intent_handoff_ready",
        "handoff-ready intents need continuity review",
        intent_summary |> U.member "handoff_ready",
        "handoff_ready" );
    ]
    |> List.filter_map (fun (kind, summary, value_json, field_name) ->
           match value_json with
           | `Int count when count > 0 ->
               Some
                 {
                   kind;
                   severity = if count >= 3 then "bad" else "warn";
                   summary;
                   target_type = "room";
                   target_id = None;
                   actor = None;
                   evidence =
                     `Assoc
                       [
                         (field_name, `Int count);
                       ];
                 }
           | _ -> None)
  in
  let pending_confirms = read_pending_confirms config in
  let pending_items =
    if pending_confirms = [] then []
    else
      [
        {
          kind = "pending_confirm_waiting";
          severity = "warn";
          summary =
            Printf.sprintf "%d pending confirmation(s) are waiting for operator input"
              (List.length pending_confirms);
          target_type = "room";
          target_id = None;
          actor = None;
          evidence = `Assoc [ ("count", `Int (List.length pending_confirms)) ];
        };
      ]
  in
  List.sort compare_attention (pending_items @ signal_items @ intent_items)

let room_recommendations ?command_plane_summary config =
  let command_plane_summary =
    match command_plane_summary with
    | Some s -> s
    | None -> Command_plane_v2.summary_json config
  in
  let microarch_signals =
    command_plane_summary
    |> U.member "operations"
    |> U.member "microarch"
    |> U.member "signals"
  in
  let intent_summary =
    command_plane_summary
    |> U.member "intents"
    |> U.member "summary"
  in
  let signal_recommendations =
    [
      ( microarch_signals |> U.member "issue_pressure",
        "broadcast",
        "command-plane issue pressure is elevated",
        "[operator] Issue pressure is elevated. Inspect blocked operations, run a dispatch tick, and checkpoint or finalize stale work." );
      ( microarch_signals |> U.member "routing_confidence",
        "broadcast",
        "command-plane routing confidence is degraded",
        "[operator] Routing confidence is low. Inspect candidate scoring and avoid risky manual rebalance until blockers clear." );
      ( microarch_signals |> U.member "quality_per_token",
        "broadcast",
        "command-plane quality-per-token is degraded",
        "[operator] Quality per token is low. Narrow the task graph, reduce weak candidates, and keep coding stages explicit before spawning more workers." );
      ( microarch_signals |> U.member "verification_gate_failures",
        "broadcast",
        "command-plane verification gate failures are accumulating",
        "[operator] Verification failures are stacking up. Stop widening the swarm, inspect implement->verify handoff quality, and patch failing gates first." );
      ( microarch_signals |> U.member "rework_rate",
        "broadcast",
        "command-plane rework rate is elevated",
        "[operator] Rework is high. Deduplicate artifact ownership and collapse parallel work that is touching the same scope." );
      ( microarch_signals |> U.member "artifact_scope_drift",
        "broadcast",
        "command-plane artifact scope drift is elevated",
        "[operator] Artifact scope drift is rising. Require explicit artifact_scope on coding stages before further routing or review." );
      ( microarch_signals |> U.member "cache_contention",
        "broadcast",
        "command-plane cache contention is elevated",
        "[operator] Cache contention is elevated. Reduce concurrent hot lanes or rebalance worker placement before scaling further." );
      ( microarch_signals |> U.member "speculative_posture",
        "broadcast",
        "command-plane speculative posture needs review",
        "[operator] Speculative posture is unstable. Review commit and abort rates before widening speculation." );
      ( intent_summary |> U.member "blocked",
        "broadcast",
        "blocked intents need intervention",
        "[operator] Some intents are blocked. Inspect intent forecast, missing dependencies, and current focus before issuing more work." );
      ( intent_summary |> U.member "handoff_ready",
        "broadcast",
        "handoff-ready intents need continuity review",
        "[operator] Handoff-ready intents are accumulating. Review continuity and either finalize or hand off explicitly." );
    ]
    |> List.filter_map
         (fun (signal_json, action_type, reason, message) ->
           match signal_json with
           | `Assoc _ -> (
               match signal_json |> U.member "tone" with
               | `String ("warn" | "bad" as severity) ->
                   Some
                     {
                       action_type;
                       target_type = "room";
                       target_id = None;
                       severity;
                       reason;
                       suggested_payload = `Assoc [ ("message", `String message) ];
                     }
               | _ -> None)
           | `Int count when count > 0 ->
               Some
                 {
                   action_type;
                   target_type = "room";
                   target_id = None;
                   severity = if count >= 3 then "bad" else "warn";
                   reason;
                   suggested_payload = `Assoc [ ("message", `String message) ];
                 }
           | _ -> None)
  in
  let swarm_resolution_recommendation =
    let swarm = Command_plane_v2.swarm_live_json config () in
    match U.member "resolution_recommendation" swarm with
    | `Assoc _ as recommendation -> (
        match
          recommendation |> U.member "recommended_kind" |> U.to_string_option,
          swarm |> U.member "run_id" |> U.to_string_option
        with
        | Some recommended_kind, Some run_id -> (
            let reason =
              recommendation |> U.member "reason" |> U.to_string_option
              |> Option.value ~default:"swarm-live run needs operator resolution"
            in
            let operation_id =
              match U.member "operation" swarm with
              | `Assoc _ as operation ->
                  operation |> U.member "operation_id" |> U.to_string_option
              | _ -> None
            in
            let payload =
              `Assoc
                [
                  ("run_id", `String run_id);
                  ("reason", `String reason);
                  ( "evidence",
                    match recommendation |> U.member "evidence" with
                    | `Assoc _ as evidence -> evidence
                    | _ -> `Assoc [] );
                ]
            in
            let payload =
              match operation_id with
              | Some value -> (
                  match payload with
                  | `Assoc fields ->
                      `Assoc (("operation_id", `String value) :: fields)
                  | other -> other)
              | None -> payload
            in
            let action_type =
              match recommended_kind with
              | "continue" -> "swarm_run_continue"
              | "rerun" -> "swarm_run_rerun"
              | "abandon" -> "swarm_run_abandon"
              | _ -> ""
            in
            if action_type = "" then None
            else
              Some
                {
                  action_type;
                  target_type = "swarm_run";
                  target_id = Some run_id;
                  severity =
                    (match recommendation |> U.member "recommended_kind" |> U.to_string_option with
                    | Some "continue" -> "warn"
                    | _ -> "bad");
                  reason;
                  suggested_payload = payload;
                })
        | _ -> None)
    | _ -> None
  in
  dedup_recommendations
    (signal_recommendations
    @
    match swarm_resolution_recommendation with
    | Some item -> [ item ]
    | None -> [])

let digest_json ?actor ?target_type ?target_id ?include_workers (ctx : 'a context) :
    (Yojson.Safe.t, string) result =
  let config = ctx.config in
  if not (Room.is_initialized config) then
    Ok
      (`Assoc
        [
          ("trace_id", `String (trace_id "opsd"));
          ("target_type", `String "room");
          ("target_id", `Null);
          ("health", `String "ok");
          ("judgment_owner", `String "fallback_read_model");
          ("authoritative_judgment_available", `Bool false);
          ("provenance_summary", operator_surface_contract_json);
          ("judgment", `Null);
          ("resident_judge_runtime", resident_judge_runtime_json config);
          ("command_plane", `Assoc []);
          ("swarm_status", Swarm_status.empty_json);
          ("attention_items", `List []);
          ("attention_summary", summary_of_attention_items []);
          ("pending_confirm_summary", pending_confirm_summary_json_of_scope (pending_confirm_scope_of_entries ?actor []));
          ("recommended_actions", `List []);
          ("recommendation_summary", summary_of_recommendations ~actor:"dashboard" []);
          ("active_guidance_layer", `String "fallback");
          ("active_summary", summary_of_recommendations ~actor:"dashboard" []);
          ("active_recommended_actions", `List []);
          ("active_recommendation_source", `String "fallback");
          ("active_recommendation_summary", summary_of_recommendations ~actor:"dashboard" []);
          ("fallback_recommended_actions", `List []);
          ("session_cards", `List []);
          ("worker_cards", `List []);
        ])
  else
    let actor_name = normalized_actor ~context_actor:ctx.agent_name actor in
    let* target_type = normalize_digest_target_type target_type in
    let now = Time_compat.now () in
    let tracked_sessions = Team_session_store.list_sessions config in
    let command_plane_snapshot_json = Command_plane_v2.snapshot_json config in
    let command_plane_digest_json = Command_plane_v2.summary_json config in
    let swarm_status_json =
      Swarm_status.build_json_from_snapshot config command_plane_snapshot_json
    in
    match target_type with
    | "room" ->
        let sessions =
          tracked_sessions
          |> List.map (fun session -> build_session_digest config session ~now)
          |> List.sort compare_session_digest
        in
        let limited_sessions =
          sessions |> List.to_seq |> Seq.take room_digest_session_limit |> List.of_seq
        in
        let attention_items =
          build_room_attention_items config
          @ (limited_sessions |> List.concat_map (fun digest -> digest.attention_items))
          |> List.sort compare_attention
        in
        let recommended_actions =
          dedup_recommendations
            (room_recommendations config
            @ (limited_sessions
              |> List.concat_map (fun digest -> digest.recommended_actions)))
        in
        let fallback_recommendation_summary =
          summary_of_recommendations ~actor:actor_name recommended_actions
        in
        let active_guidance =
          active_guidance_fields ~config ~actor:actor_name ~target_type:"room"
            ~target_id:None ~fallback_recommendations:recommended_actions
            ~fallback_summary:fallback_recommendation_summary
        in
        Ok
          (`Assoc
            ([
              ("trace_id", `String (trace_id "opsd"));
              ("target_type", `String "room");
              ("target_id", `Null);
              ("health", `String (health_from_attention_items attention_items));
              ("provenance_summary", operator_surface_contract_json);
              ("resident_judge_runtime", resident_judge_runtime_json config);
              ("command_plane", command_plane_digest_json);
              ("swarm_status", swarm_status_json);
              ("role_census", aggregate_worker_class_counts tracked_sessions);
              ("runtime_pools", aggregate_runtime_pool_counts tracked_sessions);
              ("lane_census", aggregate_lane_counts tracked_sessions);
              ("controller_census", aggregate_controller_counts tracked_sessions);
              ("control_domains", aggregate_control_domain_counts tracked_sessions);
              ("model_tiers", aggregate_tier_counts tracked_sessions);
              ("task_profiles", aggregate_task_profile_counts tracked_sessions);
              ("escalation_count", `Int (aggregate_escalation_count tracked_sessions));
              ("local_runtime", aggregated_local_runtime_json tracked_sessions);
              ("attention_items", `List (List.map attention_item_to_yojson attention_items));
              ("attention_summary", summary_of_attention_items attention_items);
              ("pending_confirm_summary", pending_confirm_summary_json ?actor config);
              ( "recommended_actions",
                `List
                  (List.map (recommended_action_to_yojson ~actor:actor_name)
                     recommended_actions) );
              ("recommendation_summary", fallback_recommendation_summary);
              ( "session_cards",
                `List
                  (List.map (session_card_to_yojson ~actor:actor_name) limited_sessions)
              );
              ("worker_cards", `List []);
            ]
            @ active_guidance))
    | "team_session" -> (
        match target_id with
        | None -> Error "target_id is required when target_type=team_session"
        | Some session_id -> (
            match Team_session_store.load_session config session_id with
            | None ->
                Error (Printf.sprintf "team session not found: %s" session_id)
            | Some session ->
                let digest = build_session_digest config session ~now in
                let worker_cards =
                  let should_include =
                    match include_workers with
                    | Some value -> value
                    | None -> true
                  in
                  if should_include then digest.worker_cards else []
                in
                let fallback_recommendation_summary =
                  summary_of_recommendations ~actor:actor_name
                    digest.recommended_actions
                in
                let active_guidance =
                  active_guidance_fields ~config ~actor:actor_name
                    ~target_type:"team_session" ~target_id:(Some session_id)
                    ~fallback_recommendations:digest.recommended_actions
                    ~fallback_summary:fallback_recommendation_summary
                in
                Ok
                  (`Assoc
                    ([
                      ("trace_id", `String (trace_id "opsd"));
                      ("target_type", `String "team_session");
                      ("target_id", `String session_id);
                      ("health", `String digest.health);
                      ("provenance_summary", operator_surface_contract_json);
                      ("resident_judge_runtime", resident_judge_runtime_json config);
                      ("command_plane", command_plane_digest_json);
                      ("swarm_status", swarm_status_json);
                      ( "attention_items",
                        `List
                          (List.map attention_item_to_yojson digest.attention_items)
                      );
                      ("attention_summary", summary_of_attention_items digest.attention_items);
                      ( "recommended_actions",
                        `List
                          (List.map (recommended_action_to_yojson ~actor:actor_name)
                             digest.recommended_actions) );
                      ("recommendation_summary", fallback_recommendation_summary);
                      ("session_cards", `List [ session_card_to_yojson ~actor:actor_name digest ]);
                      ("worker_cards", `List (List.map worker_card_to_yojson worker_cards));
                    ]
                    @ active_guidance))))
    | _ -> Error "unsupported target_type"
