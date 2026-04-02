module U = Yojson.Safe.Util
open Operator_pending_confirm

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
  risk_digest : Yojson.Safe.t;
}

let stalled_session_threshold_sec = 300.0
let planned_worker_turn_grace_sec = 180.0
let room_digest_session_limit = 10

let severity_rank = function
  | "critical" -> 3
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

let recommended_confirm_required = Operator_approval.confirm_required

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

let spawn_batch_template_of_cards (cards : worker_card list) =
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

let all_planned_workers (sessions : Team_session_types.session list) =
  List.concat_map
    (fun (session : Team_session_types.session) -> session.planned_workers)
    sessions

let aggregate_worker_counts sessions count_fn =
  all_planned_workers sessions |> count_fn |> Team_session_types.counts_to_json

let aggregate_worker_class_counts s   = aggregate_worker_counts s Team_session_types.worker_class_counts
let aggregate_runtime_pool_counts s   = aggregate_worker_counts s Team_session_types.runtime_pool_counts
let aggregate_lane_counts s           = aggregate_worker_counts s Team_session_types.lane_counts
let aggregate_controller_counts s     = aggregate_worker_counts s Team_session_types.controller_level_counts
let aggregate_control_domain_counts s = aggregate_worker_counts s Team_session_types.control_domain_counts
let aggregate_tier_counts s           = aggregate_worker_counts s Team_session_types.model_tier_counts
let aggregate_task_profile_counts s   = aggregate_worker_counts s Team_session_types.task_profile_counts

let aggregate_escalation_count s =
  all_planned_workers s |> Team_session_types.escalation_count

(** Compute all 7 worker-count aggregates + escalation with a single
    [all_planned_workers] concat_map, avoiding 8 separate list allocations.
    Each count_fn still iterates [workers] independently. *)
let aggregate_all_worker_metrics sessions =
  let workers = all_planned_workers sessions in
  let to_json count_fn = count_fn workers |> Team_session_types.counts_to_json in
  ( to_json Team_session_types.worker_class_counts,
    to_json Team_session_types.runtime_pool_counts,
    to_json Team_session_types.lane_counts,
    to_json Team_session_types.controller_level_counts,
    to_json Team_session_types.control_domain_counts,
    to_json Team_session_types.model_tier_counts,
    to_json Team_session_types.task_profile_counts,
    Team_session_types.escalation_count workers )

let aggregated_local_runtime_json (sessions : Team_session_types.session list) =
  if
    List.exists
      (fun (session : Team_session_types.session) ->
        session.scale_profile = Team_session_types.Scale_local64)
      sessions
  then Tool_local_runtime.runtime_status_json ()
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
      ("risk_digest", digest.risk_digest);
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

let normalize_digest_target_type value =
  match value with
  | Some raw -> (
      match String.trim raw |> String.lowercase_ascii with
      | "room" -> Ok "room"
      | "team_session" -> Ok "team_session"
      | _ -> Error "target_type must be one of: room, team_session")
  | None -> Ok "room"

(* review_item type + helpers are in Operator_digest_review_types
   to avoid field name collision with attention_item in modules
   that include Operator_digest_types *)
