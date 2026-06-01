(** Dashboard batch-JSON snapshot, extracted from
    [server_dashboard_http_core.ml] (godfile decomp).

    [dashboard_batch_json ?compact config] builds the operator
    dashboard's all-in-one snapshot: project status, monitoring
    sub-feeds (board / governance / credentials / workspace_state /
    executor / slots), alert thresholds, tasks list (filtered by
    [compact] flag — Done entries dropped when [compact=true]),
    agents list (with profile enrichment from
    [Dashboard_execution_helpers]), recent messages (capped at 20),
    and the keepers projection from [keepers_dashboard_json].

    Pure helper move — no callback injection. Sibling mirrors the
    parent's `include` directives for [Dashboard_http_monitoring]
    (board/governance/credentials/slot/executor + tool_call_health)
    and [Dashboard_http_keeper] ([keepers_dashboard_json]) so the
    call-site bodies stay literal. *)

open Masc_domain
include Dashboard_http_monitoring
include Dashboard_http_keeper

(* Monitoring alert thresholds for proactive refresh health display.
   Fallback ratio = proportion of requests falling back to stale cache.
   Similarity ratio = how close stale data is to fresh (1.0 = identical).
   Toast cooldown = minimum seconds between repeated alert toasts. *)
let proactive_fallback_warn = 0.20
let proactive_fallback_bad = 0.40
let proactive_similarity_warn = 0.90
let proactive_similarity_bad = 0.97
let alert_toast_cooldown_sec = 300

let dashboard_batch_json ?(compact = false) (config : Workspace.config) : Yojson.Safe.t =
  let workspace_state = Workspace.read_state config in
  let tempo = Tempo.get_tempo config in
  (* M-17 fix: single-namespace, queries scoped by basepath *)
  let tasks = Workspace.get_tasks_safe config in
  let agents = Workspace.get_active_agents config in
  let msgs = Workspace.get_messages_raw config ~since_seq:0 ~limit:20 in
  let now_ts = Time_compat.now () in
  let board_monitor_json, board_contract_ok = board_monitoring_json ~now_ts in
  let governance_monitor_json, governance_feed_ok =
    governance_monitoring_json ~now_ts ~base_path:config.base_path
  in
  let cluster = Env_config_core.cluster_name () in
  let status_json =
    `Assoc
      [ "cluster", `String cluster
      ; "base_path", `String config.base_path
      ; "workspace_root", `String config.base_path
      ; "workspace_path", `String config.workspace_path
      ; "workspace_differs", `Bool (config.workspace_path <> config.base_path)
      ; "cluster", `String (Env_config_core.cluster_name ())
      ; "project", `String workspace_state.project
      ; "tempo_interval_s", `Float tempo.current_interval_s
      ; "paused", `Bool workspace_state.paused
      ; "tool_call_health", tool_call_health_json config
      ; ( "alert_thresholds"
        , `Assoc
            [ "proactive_fallback_warn", `Float proactive_fallback_warn
            ; ( "proactive_fallback_bad"
              , `Float (max proactive_fallback_warn proactive_fallback_bad) )
            ; "proactive_similarity_warn", `Float proactive_similarity_warn
            ; ( "proactive_similarity_bad"
              , `Float (max proactive_similarity_warn proactive_similarity_bad) )
            ; "toast_cooldown_sec", `Int alert_toast_cooldown_sec
            ] )
      ; ( "monitoring"
        , `Assoc
            [ "board", board_monitor_json
            ; "governance", governance_monitor_json
            ; "credentials", credential_monitoring_json ()
            ; "workspace_state", Workspace_eio.state_health_counters ()
            ; "executor", executor_outcomes_json config
            ; "slots", slot_monitoring_json ()
            ] )
      ; ( "data_quality"
        , `Assoc
            [ "board_contract_ok", `Bool board_contract_ok
            ; "governance_feed_ok", `Bool governance_feed_ok
            ; "last_sync_at", `String (Masc_domain.now_iso ())
            ] )
      ]
  in
  let tasks_json =
    List.map
      (fun (t : Masc_domain.task) ->
         let base_fields =
           [ "id", `String t.id
           ; "title", `String t.title
           ; "description", `String t.description
           ; "status", `String (Masc_domain.string_of_task_status t.task_status)
           ; "priority", `Int t.priority
           ; ( "assignee"
             , match t.task_status with
               | Claimed { assignee; _ }
               | InProgress { assignee; _ }
               | Done { assignee; _ } -> `String assignee
               | _ -> `Null )
           ; "created_at", `String t.created_at
           ]
         in
         let projection_fields =
           match
             (fun _t ->
                ignore config;
                `Assoc [])
               t
           with
           | `Assoc fields -> fields
           | _ -> []
         in
         `Assoc (base_fields @ projection_fields))
      (List.filter
         (fun (t : Masc_domain.task) ->
            match t.task_status with
            | Masc_domain.Cancelled _ -> false
            | Masc_domain.Done _ -> not compact
            | Masc_domain.Todo -> true
            | Masc_domain.Claimed _ | Masc_domain.InProgress _ -> true
            | Masc_domain.AwaitingVerification _ -> true)
         tasks)
  in
  let agents_json =
    List.map
      (fun (a : Masc_domain.agent) ->
         let profile = Dashboard_execution_helpers.get_agent_profile a.name in
         `Assoc
           [ "name", `String a.name
           ; "status", `String (Masc_domain.string_of_agent_status a.status)
           ; "current_task", Json_util.string_opt_to_json a.current_task
           ; "last_seen", `String a.last_seen
           ; "emoji", `String profile.emoji
           ; "koreanName", `String profile.korean_name
           ; "model", `Null
           ; "traits", `List (List.map (fun t -> `String t) profile.traits)
           ; "interests", `List (List.map (fun i -> `String i) profile.interests)
           ; "activityLevel", Json_util.float_opt_to_json profile.activity_level
           ; "primaryValue", Json_util.string_opt_to_json profile.primary_value
           ; "generation", `Null
           ; "context_ratio", `Null
           ; "turn_count", `Null
           ])
      agents
  in
  let msgs_json =
    List.map
      (fun (m : Masc_domain.message) ->
         `Assoc
           [ "from", `String m.from_agent
           ; "content", `String m.content
           ; "timestamp", `String m.timestamp
           ; "seq", `Int m.seq
           ])
      (List.filteri (fun idx _ -> idx < 20) msgs)
  in
  `Assoc
    [ "status", status_json
    ; ( "tasks"
      , `Assoc [ "tasks", `List tasks_json; "total", `Int (List.length tasks_json) ] )
    ; ( "agents"
      , `Assoc [ "agents", `List agents_json; "total", `Int (List.length agents_json) ] )
    ; ( "messages"
      , `Assoc [ "messages", `List msgs_json; "total", `Int (List.length msgs_json) ] )
    ; "keepers", keepers_dashboard_json ~compact config
    ]
;;
