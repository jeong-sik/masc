(** Team_context_oas_adapter — collaboration context bridge for team sessions.

    Lossy projection: MASC team_session (47 fields) -> collaboration JSON.
    Produces opaque Yojson.Safe.t for OAS swarm_config.collaboration_context.

    @since 2.114.0 *)

let session_status_to_phase_string
    (s : Team_session_types.session_status) : string =
  match s with
  | Running -> "active"
  | Paused -> "waiting_on_participants"
  | Completed -> "completed"
  | Interrupted -> "failed"
  | Failed -> "failed"
  | Cancelled -> "cancelled"

let execution_scope_to_participant_state_string
    (scope : Team_session_types.execution_scope option) : string =
  match scope with
  | None -> "planned"
  | Some Observe_only -> "joined"
  | Some Limited_code_change -> "working"
  | Some Autonomous -> "working"

let add_json_string_if_present key value acc =
  match value with
  | Some text when String.trim text <> "" -> (key, `String (String.trim text)) :: acc
  | _ -> acc

let add_json_bool_if_present key value acc =
  match value with
  | Some flag -> (key, `Bool flag) :: acc
  | None -> acc

let add_json_int_if_present key value acc =
  match value with
  | Some n -> (key, `Int n) :: acc
  | None -> acc

let add_json_float_if_present key value acc =
  match value with
  | Some n -> (key, `Float n) :: acc
  | None -> acc

let count_assoc_to_json counts =
  `Assoc
    (counts
    |> List.map (fun (label, count) -> (label, `Int count))
    |> List.sort (fun (a, _) (b, _) -> compare a b))

type projected_worker_spec = {
  spawn_agent : string;
  runtime_actor : string option;
  spawn_role : string option;
  spawn_model : string option;
  execution_scope : string option;
  thinking_enabled : bool option;
  thinking_budget : int option;
  max_turns : int option;
  timeout_seconds : int option;
  worker_class : string option;
  parent_actor : string option;
  capsule_mode : string option;
  runtime_pool : string option;
  lane_id : string option;
  controller_level : string option;
  control_domain : string option;
  supervisor_actor : string option;
  task_profile : string option;
  risk_level : string option;
  routing_confidence : float option;
  routing_reason : string option;
  routing_escalated : bool;
}

type projected_session_metadata = {
  room_id : string;
  created_by : string;
  origin_kind : string;
  execution_scope : string;
  orchestration_mode : string;
  control_profile : string;
  scale_profile : string;
  instruction_profile : string;
  fallback_policy : string;
  communication_mode : string;
  alert_channel : string;
  duration_seconds : int;
  checkpoint_interval_sec : int;
  min_agents : int;
  auto_resume : bool;
  planned_worker_count : int;
  model_cascade : string list;
  worker_class_counts : (string * int) list;
  runtime_pool_counts : (string * int) list;
  lane_counts : (string * int) list;
  controller_level_counts : (string * int) list;
  control_domain_counts : (string * int) list;
  worker_specs : projected_worker_spec list;
}

type runtime_health = {
  base_path_exists : bool;
  room_initialized : bool;
  session_running : bool;
}

let projected_worker_spec_of_planned_worker
    (pw : Team_session_types.planned_worker) : projected_worker_spec =
  {
    spawn_agent = pw.spawn_agent;
    runtime_actor = pw.runtime_actor;
    spawn_role = pw.spawn_role;
    spawn_model = pw.spawn_model;
    execution_scope =
      Option.map Team_session_types.execution_scope_to_string pw.execution_scope;
    thinking_enabled = pw.thinking_enabled;
    thinking_budget = pw.thinking_budget;
    max_turns = pw.max_turns;
    timeout_seconds = pw.timeout_seconds;
    worker_class =
      Option.map Team_session_types.worker_class_to_string pw.worker_class;
    parent_actor = pw.parent_actor;
    capsule_mode =
      Option.map Team_session_types.capsule_mode_to_string pw.capsule_mode;
    runtime_pool = pw.runtime_pool;
    lane_id = pw.lane_id;
    controller_level =
      Option.map Team_session_types.controller_level_to_string
        pw.controller_level;
    control_domain =
      Option.map Team_session_types.control_domain_to_string pw.control_domain;
    supervisor_actor = pw.supervisor_actor;
    task_profile =
      Option.map Team_session_types.task_profile_to_string pw.task_profile;
    risk_level =
      Option.map Team_session_types.risk_level_to_string pw.risk_level;
    routing_confidence = pw.routing_confidence;
    routing_reason = pw.routing_reason;
    routing_escalated = pw.routing_escalated;
  }

let projected_session_metadata_of_session
    (session : Team_session_types.session) : projected_session_metadata =
  {
    room_id = session.room_id;
    created_by = session.created_by;
    origin_kind =
      Team_session_types.session_origin_kind_to_string session.origin_kind;
    execution_scope =
      Team_session_types.execution_scope_to_string session.execution_scope;
    orchestration_mode =
      Team_session_types.orchestration_mode_to_string
        session.orchestration_mode;
    control_profile =
      Team_session_types.control_profile_to_string session.control_profile;
    scale_profile =
      Team_session_types.scale_profile_to_string session.scale_profile;
    instruction_profile =
      Team_session_types.instruction_profile_to_string
        session.instruction_profile;
    fallback_policy =
      Team_session_types.fallback_policy_to_string session.fallback_policy;
    communication_mode =
      Team_session_types.communication_mode_to_string
        session.communication_mode;
    alert_channel =
      Team_session_types.alert_channel_to_string session.alert_channel;
    duration_seconds = session.duration_seconds;
    checkpoint_interval_sec = session.checkpoint_interval_sec;
    min_agents = session.min_agents;
    auto_resume = session.auto_resume;
    planned_worker_count = List.length session.planned_workers;
    model_cascade = session.model_cascade;
    worker_class_counts =
      Team_session_types.worker_class_counts session.planned_workers;
    runtime_pool_counts =
      Team_session_types.runtime_pool_counts session.planned_workers;
    lane_counts = Team_session_types.lane_counts session.planned_workers;
    controller_level_counts =
      Team_session_types.controller_level_counts session.planned_workers;
    control_domain_counts =
      Team_session_types.control_domain_counts session.planned_workers;
    worker_specs =
      List.map projected_worker_spec_of_planned_worker session.planned_workers;
  }

let projected_worker_spec_to_json (spec : projected_worker_spec) :
    Yojson.Safe.t =
  let fields =
    []
    |> add_json_string_if_present "runtime_actor" spec.runtime_actor
    |> add_json_string_if_present "spawn_role" spec.spawn_role
    |> add_json_string_if_present "spawn_model" spec.spawn_model
    |> add_json_string_if_present "execution_scope" spec.execution_scope
    |> add_json_string_if_present "worker_class" spec.worker_class
    |> add_json_string_if_present "parent_actor" spec.parent_actor
    |> add_json_string_if_present "capsule_mode" spec.capsule_mode
    |> add_json_string_if_present "runtime_pool" spec.runtime_pool
    |> add_json_string_if_present "lane_id" spec.lane_id
    |> add_json_string_if_present "controller_level" spec.controller_level
    |> add_json_string_if_present "control_domain" spec.control_domain
    |> add_json_string_if_present "supervisor_actor" spec.supervisor_actor
    |> add_json_string_if_present "task_profile" spec.task_profile
    |> add_json_string_if_present "risk_level" spec.risk_level
    |> add_json_string_if_present "routing_reason" spec.routing_reason
    |> add_json_bool_if_present "thinking_enabled" spec.thinking_enabled
    |> add_json_int_if_present "thinking_budget" spec.thinking_budget
    |> add_json_int_if_present "max_turns" spec.max_turns
    |> add_json_int_if_present "timeout_seconds" spec.timeout_seconds
    |> add_json_float_if_present "routing_confidence" spec.routing_confidence
  in
  `Assoc
    (List.rev
       (("spawn_agent", `String spec.spawn_agent)
        :: ("routing_escalated", `Bool spec.routing_escalated)
        :: fields))

let metadata_of_session_projection (projection : projected_session_metadata) :
    (string * Yojson.Safe.t) list =
  [
    ("room_id", `String projection.room_id);
    ("created_by", `String projection.created_by);
    ("origin_kind", `String projection.origin_kind);
    ("execution_scope", `String projection.execution_scope);
    ("orchestration_mode", `String projection.orchestration_mode);
    ("control_profile", `String projection.control_profile);
    ("scale_profile", `String projection.scale_profile);
    ("instruction_profile", `String projection.instruction_profile);
    ("fallback_policy", `String projection.fallback_policy);
    ("communication_mode", `String projection.communication_mode);
    ("alert_channel", `String projection.alert_channel);
    ("duration_seconds", `Int projection.duration_seconds);
    ("checkpoint_interval_sec", `Int projection.checkpoint_interval_sec);
    ("min_agents", `Int projection.min_agents);
    ("auto_resume", `Bool projection.auto_resume);
    ("planned_worker_count", `Int projection.planned_worker_count);
    ("model_cascade", `List (List.map (fun model -> `String model) projection.model_cascade));
    ("worker_class_counts", count_assoc_to_json projection.worker_class_counts);
    ("runtime_pool_counts", count_assoc_to_json projection.runtime_pool_counts);
    ("lane_counts", count_assoc_to_json projection.lane_counts);
    ( "controller_level_counts",
      count_assoc_to_json projection.controller_level_counts );
    ("control_domain_counts", count_assoc_to_json projection.control_domain_counts);
    ( "worker_specs",
      `List (List.map projected_worker_spec_to_json projection.worker_specs) );
  ]

let runtime_health_to_json (health : runtime_health) =
  `Assoc
    [
      ("base_path_exists", `Bool health.base_path_exists);
      ("room_initialized", `Bool health.room_initialized);
      ("session_running", `Bool health.session_running);
      ( "ready",
        `Bool
          (health.base_path_exists && health.room_initialized
         && health.session_running) );
    ]

let replace_metadata_field key value metadata =
  let remaining =
    List.filter (fun (existing, _) -> not (String.equal existing key)) metadata
  in
  (key, value) :: remaining

let with_runtime_health
    (collaboration : Yojson.Safe.t)
    (health : runtime_health) : Yojson.Safe.t =
  match collaboration with
  | `Assoc fields ->
    let metadata = match List.assoc_opt "metadata" fields with
      | Some (`Assoc m) ->
        `Assoc (replace_metadata_field "runtime_health" (runtime_health_to_json health) m)
      | _ -> `Assoc [("runtime_health", runtime_health_to_json health)]
    in
    `Assoc (replace_metadata_field "metadata" metadata fields)
  | other -> other

let planned_worker_summary (pw : Team_session_types.planned_worker) : string option =
  let parts = ref [] in
  let add label value =
    if String.trim value <> "" then
      parts := (label ^ "=" ^ value) :: !parts
  in
  add "role" (Option.value ~default:"" pw.spawn_role);
  add "actor" (Option.value ~default:"" pw.runtime_actor);
  add "model" (Option.value ~default:"" pw.spawn_model);
  add "scope"
    (match pw.execution_scope with
    | Some scope -> Team_session_types.execution_scope_to_string scope
    | None -> "");
  add "max_turns"
    (match pw.max_turns with
    | Some turns -> string_of_int turns
    | None -> "");
  add "class"
    (match pw.worker_class with
     | Some worker_class -> Team_session_types.worker_class_to_string worker_class
     | None -> "");
  add "pool" (Option.value ~default:"" pw.runtime_pool);
  add "lane" (Option.value ~default:"" pw.lane_id);
  add "domain"
    (match pw.control_domain with
     | Some domain -> Team_session_types.control_domain_to_string domain
     | None -> "");
  add "risk"
    (match pw.risk_level with
     | Some risk -> Team_session_types.risk_level_to_string risk
     | None -> "");
  add "routing"
    (match pw.routing_confidence with
     | Some confidence -> Printf.sprintf "%.2f" confidence
     | None -> "");
  match List.rev !parts with
  | [] -> None
  | parts -> Some (String.concat "; " parts)

let planned_worker_to_participant_json
    (pw : Team_session_types.planned_worker) : Yojson.Safe.t =
  let fields = [
    ("name", `String pw.spawn_agent);
    ("state", `String (execution_scope_to_participant_state_string pw.execution_scope));
  ] in
  let fields = match pw.spawn_role with
    | Some r -> ("role", `String r) :: fields | None -> fields in
  let fields = match planned_worker_summary pw with
    | Some s -> ("summary", `String s) :: fields | None -> fields in
  `Assoc (List.rev fields)

(** Project a MASC team session into opaque collaboration JSON.

    This is a lossy projection: planned_worker (16 fields) compresses to
    participant (4 fields).  Produces Yojson.Safe.t for OAS
    swarm_config.collaboration_context. *)
let collaboration_of_session
    ~base_path
    (session : Team_session_types.session)
    : Yojson.Safe.t =
  let findings =
    Team_context.load_findings ~base_path ~team_session_id:session.session_id
  in
  let projection = projected_session_metadata_of_session session in
  `Assoc [
    ("id", `String session.session_id);
    ("goal", `String session.goal);
    ("phase", `String (session_status_to_phase_string session.status));
    ("participants",
      `List (List.map planned_worker_to_participant_json session.planned_workers));
    ("artifacts", `List []);
    ("contributions", `List []);
    ("findings", `List (List.map (fun f -> `String f) findings));
    ("created_at", `Float session.started_at);
    ("updated_at", `Float (match session.last_event_at with
       | Some t -> t | None -> session.started_at));
    ("outcome", match session.stop_reason with
       | Some r -> `String r | None -> `Null);
    ("metadata", `Assoc (metadata_of_session_projection projection));
  ]
