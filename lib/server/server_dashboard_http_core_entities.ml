let dashboard_shell_status_json (config : Coord.config) : Yojson.Safe.t =
  let room_state = Coord.read_state config in
  let cluster = Env_config_core.cluster_name () in
  let tempo = Tempo.get_tempo config in
  let build = Build_identity.current () in
  `Assoc
    [ "cluster", `String cluster
    ; "base_path", `String config.base_path
    ; "coordination_root", `String config.base_path
    ; "workspace_path", `String config.workspace_path
    ; "workspace_differs", `Bool (config.workspace_path <> config.base_path)
    ; "cluster", `String (Env_config_core.cluster_name ())
    ; "project", `String room_state.project
    ; "tempo_interval_s", `Float tempo.current_interval_s
    ; "paused", `Bool room_state.paused
    ; "version", `String build.release_version
    ; "build", Build_identity.to_yojson build
    ]
;;

let dashboard_task_assignee (task : Masc_domain.task) =
  match task.task_status with
  | Claimed { assignee; _ }
  | InProgress { assignee; _ }
  | AwaitingVerification { assignee; _ }
  | Done { assignee; _ } -> Some assignee
  | Todo | Cancelled _ -> None
;;

let dashboard_task_json config (task : Masc_domain.task) =
  let base_fields =
    [ "id", `String task.id
    ; "title", `String task.title
    ; "description", `String task.description
    ; "status", `String (Masc_domain.string_of_task_status task.task_status)
    ; "priority", `Int task.priority
    ; "assignee", Json_util.string_opt_to_json (dashboard_task_assignee task)
    ; "created_at", `String task.created_at
    ]
  in
  let projection_fields =
    match
      (fun _t ->
         ignore config;
         `Assoc [])
        task
    with
    | `Assoc fields -> fields
    | _ -> []
  in
  `Assoc (base_fields @ projection_fields)
;;

let dashboard_agent_json (agent : Masc_domain.agent) =
  let profile = Dashboard_execution_helpers.get_agent_profile agent.name in
  let meta = agent.meta in
  `Assoc
    [ "name", `String agent.name
    ; "agent_type", `String agent.agent_type
    ; ( "keeper_name"
      , Json_util.string_opt_to_json (Option.bind meta (fun m -> m.keeper_name)) )
    ; "keeper_id", Json_util.string_opt_to_json (Option.bind meta (fun m -> m.keeper_id))
    ; "status", `String (Masc_domain.string_of_agent_status agent.status)
    ; "current_task", Json_util.string_opt_to_json agent.current_task
    ; "joined_at", `String agent.joined_at
    ; "last_seen", `String agent.last_seen
    ; "capabilities", `List (List.map (fun item -> `String item) agent.capabilities)
    ; "emoji", `String profile.emoji
    ; "koreanName", `String profile.korean_name
    ; "model", `Null
    ; "traits", `List (List.map (fun t -> `String t) profile.traits)
    ; "interests", `List (List.map (fun i -> `String i) profile.interests)
    ; "activityLevel", Json_util.float_opt_to_json profile.activity_level
    ; "primaryValue", Json_util.string_opt_to_json profile.primary_value
    ]
;;

let dashboard_message_json (message : Masc_domain.message) =
  `Assoc
    [ "from", `String message.from_agent
    ; "type", `String message.msg_type
    ; "content", `String message.content
    ; "mention", Json_util.string_opt_to_json message.mention
    ; "timestamp", `String message.timestamp
    ; "trace_context", Json_util.string_opt_to_json message.trace_context
    ; "expires_at", Json_util.float_opt_to_json message.expires_at
    ; "relevance", `String message.relevance
    ; "seq", `Int message.seq
    ]
;;

let dashboard_tasks_safe config = Coord.get_tasks_safe config
let dashboard_agents_safe config = Coord.get_active_agents config

let dashboard_messages_safe config ~since_seq ~limit =
  Coord.get_messages_raw config ~since_seq ~limit
;;

let is_keeper_agent (agent : Masc_domain.agent) =
  String.equal (String.lowercase_ascii (String.trim agent.agent_type)) "keeper"
;;

let dashboard_general_agent_count agents =
  agents
  |> List.fold_left
       (fun count agent -> if is_keeper_agent agent then count else count + 1)
       0
;;

let provider_capacity_json () : Yojson.Safe.t = `Assoc []
