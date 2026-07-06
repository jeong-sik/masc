let dashboard_shell_status_json (config : Workspace.config) : Yojson.Safe.t =
  let workspace_state_snapshot = Workspace.read_state_snapshot config in
  let workspace_state = workspace_state_snapshot.state in
  let cluster = Env_config_core.cluster_name () in
  let tempo = Tempo.get_tempo config in
  let build = Build_identity.current () in
  `Assoc
    [ "cluster", `String cluster
    ; "base_path", `String config.base_path
    ; "workspace_root", `String config.base_path
    ; "workspace_path", `String config.workspace_path
    ; "workspace_differs", `Bool (config.workspace_path <> config.base_path)
    ; "project", `String workspace_state.project
    ; ( "workspace_state_status"
      , `String
          (Workspace.read_state_status_to_string workspace_state_snapshot.status) )
    ; ( "workspace_state_read_error_count"
      , `Int (List.length workspace_state_snapshot.read_errors) )
    ; ( "workspace_state_read_errors"
      , `List (List.map (fun error -> `String error) workspace_state_snapshot.read_errors) )
    ; "tempo_interval_s", `Float tempo.current_interval_s
    ; "paused", `Bool workspace_state.paused
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
    ; "session_bound_at", `String agent.session_bound_at
    ; "last_seen", `String agent.last_seen
    ; "capabilities", `List (List.map (fun item -> `String item) agent.capabilities)
    ; "emoji", `String profile.emoji
    ; "koreanName", `String profile.korean_name
    ; "profile_errors", Dashboard_execution_helpers.agent_profile_errors_json profile
    ; "profile_error_count", `Int (List.length profile.profile_errors)
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

let dashboard_tasks_safe config = Workspace.get_tasks_safe config
let dashboard_agents_safe config = Workspace.get_active_agents config

let active_agent_summary_json json =
  (* RFC-0089: classify the agent "status" via the closed agent_status ADT
     (Masc_domain.agent_status_of_string_opt) instead of string literals, so a
     new status constructor forces a compile error here too. Behavior is
     unchanged: only Active/Busy/Listening yield a summary; Inactive and any
     other/absent value yield None. *)
  match Json_util.assoc_string_opt "status" json with
  | Some status ->
    (match
       Masc_domain.agent_status_of_string_opt
         (String.lowercase_ascii (String.trim status))
     with
     | Some (Masc_domain.Active | Masc_domain.Busy | Masc_domain.Listening) ->
       let agent_type =
         Json_util.assoc_string_opt "agent_type" json
         |> Option.value ~default:"unknown"
         |> String.trim
         |> String.lowercase_ascii
       in
       Some agent_type
     | Some Masc_domain.Inactive | None -> None)
  | None -> None
;;

let dashboard_general_agent_count_light config =
  if not (Workspace.root_is_initialized config)
  then 0
  else
    Workspace.list_dir config (Workspace.agents_dir config)
    |> List.fold_left
         (fun count name ->
           if name = ""
              || String.contains name '/'
              || not (Filename.check_suffix name ".json")
           then count
           else (
             let path = Filename.concat (Workspace.agents_dir config) name in
             match Workspace.read_json_result config path with
             | Ok json ->
               (match active_agent_summary_json json with
                | Some agent_type when not (String.equal agent_type "keeper") -> count + 1
                | Some _ | None -> count)
             | Error _ -> count))
         0
;;

let dashboard_messages_safe config ~since_seq ~limit =
  Workspace.get_messages_raw config ~since_seq ~limit
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
