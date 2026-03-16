[@@@warning "-32-33-69"]

open Types
open Server_utils
open Server_auth

(* ================================================================ *)
(* Dashboard Data (Batch API)                                       *)
(* ================================================================ *)

include Dashboard_http_helpers
include Dashboard_http_monitoring
include Dashboard_http_keeper
include Dashboard_http_mdal

let dashboard_semantics_http_json () =
  Dashboard_semantics.json ()

let dashboard_batch_json ?(compact = false) (config : Room.config) : Yojson.Safe.t =
  let room_state = Room.read_state config in
  let tempo = Tempo.get_tempo config in
  let tasks = Room.get_tasks_raw config in
  let agents = Room.get_agents_raw config in
  let msgs = Room.get_messages_raw config ~since_seq:0 ~limit:20 in
  let lodge_json = Lodge_heartbeat.(lodge_status () |> lodge_status_to_json) in
  let social_runtime_json = Social_runtime.status_json ~config in
  let now_ts = Time_compat.now () in
  let (board_monitor_json, board_contract_ok) = board_monitoring_json ~now_ts in
  let (governance_monitor_json, governance_feed_ok) =
    governance_monitoring_json ~now_ts ~base_path:config.base_path
  in

  let proactive_fallback_warn =
    float_of_env_default
      "MASC_DASHBOARD_PROACTIVE_FALLBACK_WARN"
      ~default:0.20
      ~min_v:0.0
      ~max_v:1.0
  in
  let proactive_fallback_bad =
    float_of_env_default
      "MASC_DASHBOARD_PROACTIVE_FALLBACK_BAD"
      ~default:0.40
      ~min_v:0.0
      ~max_v:1.0
  in
  let proactive_similarity_warn =
    float_of_env_default
      "MASC_DASHBOARD_PROACTIVE_SIMILARITY_WARN"
      ~default:0.90
      ~min_v:0.0
      ~max_v:1.0
  in
  let proactive_similarity_bad =
    float_of_env_default
      "MASC_DASHBOARD_PROACTIVE_SIMILARITY_BAD"
      ~default:0.97
      ~min_v:0.0
      ~max_v:1.0
  in
  let alert_toast_cooldown_sec =
    int_of_env_default
      "MASC_DASHBOARD_ALERT_TOAST_COOLDOWN_SEC"
      ~default:300
      ~min_v:10
      ~max_v:86400
  in
  let status_json =
    `Assoc [
      ( "room",
        `String
          (if Room.is_initialized config then Room.current_room_id config
           else Filename.basename config.base_path) );
      ("room_base_path", `String config.base_path);
      ("cluster", `String (Option.value ~default:"unknown" (Sys.getenv_opt "MASC_CLUSTER_NAME")));
      ("project", `String room_state.project);
      ("tempo_interval_s", `Float tempo.current_interval_s);
      ("paused", `Bool room_state.paused);
      ("tool_call_health", tool_call_health_json config);
      ("alert_thresholds", `Assoc [
        ("proactive_fallback_warn", `Float proactive_fallback_warn);
        ("proactive_fallback_bad", `Float (max proactive_fallback_warn proactive_fallback_bad));
        ("proactive_similarity_warn", `Float proactive_similarity_warn);
        ("proactive_similarity_bad", `Float (max proactive_similarity_warn proactive_similarity_bad));
        ("toast_cooldown_sec", `Int alert_toast_cooldown_sec);
      ]);
      ("monitoring", `Assoc [
        ("board", board_monitor_json);
        ("governance", governance_monitor_json);
      ]);
      ("lodge", lodge_json);
      ("social_runtime", social_runtime_json);
      ("data_quality", `Assoc [
        ("board_contract_ok", `Bool board_contract_ok);
        ("governance_feed_ok", `Bool governance_feed_ok);
        ("last_sync_at", `String (Types.now_iso ()));
      ]);
    ]
  in
  let tasks_json =
    List.map (fun (t : Types.task) ->
      `Assoc [
        ("id", `String t.id);
        ("title", `String t.title);
        ("status", `String (Types.string_of_task_status t.task_status));
        ("priority", `Int t.priority);
        ("assignee",
         match t.task_status with
         | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } ->
             `String assignee
         | _ -> `Null);
      ]
    )
      (List.filter
         (fun (t : Types.task) ->
           match t.task_status with
           | Types.Cancelled _ -> false
           | Types.Done _ -> not compact
           | _ -> true)
         tasks)
  in
  let agents_json =
    List.map (fun (a : Types.agent) ->
      let (emoji, korean_name) = get_agent_identity a.name in
      `Assoc [
        ("name", `String a.name);
        ("status", `String (Types.string_of_agent_status a.status));
        ("current_task", match a.current_task with Some t -> `String t | None -> `Null);
        ("last_seen", `String a.last_seen);
        ("emoji", `String emoji);
        ("koreanName", `String korean_name);
        ("generation", `Null);
        ("context_ratio", `Null);
        ("turn_count", `Null);
      ]
    ) agents
  in
  let msgs_json =
    List.map
      (fun (m : Types.message) ->
        `Assoc [
          ("from", `String m.from_agent);
          ("content", `String m.content);
          ("timestamp", `String m.timestamp);
          ("seq", `Int m.seq);
        ])
      (List.filteri (fun idx _ -> idx < 20) msgs)
  in
  `Assoc [
    ("status", status_json);
    ("tasks", `Assoc [ ("tasks", `List tasks_json); ("total", `Int (List.length tasks_json)) ]);
    ("agents", `Assoc [ ("agents", `List agents_json); ("total", `Int (List.length agents_json)) ]);
    ("messages", `Assoc [ ("messages", `List msgs_json); ("total", `Int (List.length msgs_json)) ]);
    ("keepers", keepers_dashboard_json ~compact config);
    ("perpetual", perpetual_dashboard_json ());
  ]

let operator_actor_hint request =
  match agent_from_request request with
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  | None -> None

let operator_snapshot_http_json ~state ~sw ~clock request =
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" (operator_actor_hint request);
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      mcp_session_id = None;
    }
  in
  let include_messages =
    match query_param request "include_messages" with
    | Some ("0" | "false" | "no") -> false
    | _ -> true
  in
  let include_sessions =
    match query_param request "include_sessions" with
    | Some ("0" | "false" | "no") -> false
    | _ -> true
  in
  let include_keepers =
    match query_param request "include_keepers" with
    | Some ("0" | "false" | "no") -> false
    | _ -> true
  in
  Operator_control.snapshot_json ?actor:(operator_actor_hint request)
    ~include_messages ~include_sessions ~include_keepers ctx

let operator_digest_http_json ~state ~sw ~clock request =
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" (operator_actor_hint request);
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      mcp_session_id = None;
    }
  in
  let target_type = query_param request "target_type" in
  let target_id = query_param request "target_id" in
  let include_workers =
    match query_param request "include_workers" with
    | Some ("0" | "false" | "no") -> Some false
    | Some ("1" | "true" | "yes") -> Some true
    | _ -> None
  in
  Operator_control.digest_json ?actor:(operator_actor_hint request)
    ?target_type ?target_id ?include_workers ctx

let dashboard_mission_http_json ~state ~sw ~clock request =
  let actor = operator_actor_hint request in
  let cache_key =
    Printf.sprintf "mission:%s" (Option.value ~default:"" actor)
  in
  Dashboard_cache.get_or_compute cache_key ~ttl:3.0 (fun () ->
    Dashboard_mission.json ?actor
      ~config:state.Mcp_server.room_config ~sw ~clock
      ~proc_mgr:state.Mcp_server.proc_mgr ())

let dashboard_session_http_json ~state ~sw ~clock request =
  match query_param request "session_id" with
  | Some session_id when String.trim session_id <> "" ->
      Dashboard_mission.session_json ?actor:(operator_actor_hint request)
        ~session_id:(String.trim session_id)
        ~config:state.Mcp_server.room_config ~sw ~clock
        ~proc_mgr:state.Mcp_server.proc_mgr ()
  | _ ->
      `Assoc
        [
          ("generated_at", `String (Types.now_iso ()));
          ("session_id", `Null);
          ("session", `Null);
          ("timeline", `List []);
          ("participants", `List []);
          ("operations", `List []);
          ("keepers", `List []);
          ("error", `String "session_id is required");
        ]

let dashboard_mission_briefing_http_json ~state ~sw ~clock request =
  Dashboard_mission_briefing.json ?actor:(operator_actor_hint request)
    ~force:(bool_query_param request "force" ~default:false)
    ~config:state.Mcp_server.room_config ~sw ~clock
    ~proc_mgr:state.Mcp_server.proc_mgr ()

let dashboard_proof_http_json ~state request =
  let session_id = query_param request "session_id" in
  let operation_id = query_param request "operation_id" in
  Dashboard_proof.json ?actor:(operator_actor_hint request) ?session_id
    ?operation_id ~config:state.Mcp_server.room_config ()

let dashboard_shell_status_json (config : Room.config) : Yojson.Safe.t =
  let room_state = Room.read_state config in
  let current_room =
    Room.read_current_room config |> Option.value ~default:"default"
  in
  let tempo = Tempo.get_tempo config in
  let lodge_json = Lodge_heartbeat.(lodge_status () |> lodge_status_to_json) in
  let social_runtime_json = Social_runtime.status_json ~config in
  let gardener_json = Gardener.status_json () in
  let guardian_json = Guardian.status_json () in
  let sentinel_json = Sentinel.status_json () in
  let build = Build_identity.current () in
  `Assoc
    [
      ("room", `String current_room);
      ("current_room", `String current_room);
      ("room_base_path", `String config.base_path);
      ( "cluster",
        `String (Option.value ~default:"unknown" (Sys.getenv_opt "MASC_CLUSTER_NAME"))
      );
      ("project", `String room_state.project);
      ("tempo_interval_s", `Float tempo.current_interval_s);
      ("paused", `Bool room_state.paused);
      ("lodge", lodge_json);
      ("social_runtime", social_runtime_json);
      ("gardener", gardener_json);
      ("guardian", guardian_json);
      ("sentinel", sentinel_json);
      ("version", `String build.release_version);
      ("build", Build_identity.to_yojson build);
    ]

let dashboard_task_assignee (task : Types.task) =
  match task.task_status with
  | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } ->
      Some assignee
  | Todo | Cancelled _ -> None

let dashboard_task_json (task : Types.task) =
  `Assoc
    [
      ("id", `String task.id);
      ("title", `String task.title);
      ("description", `String task.description);
      ("status", `String (Types.string_of_task_status task.task_status));
      ("priority", `Int task.priority);
      ("assignee", match dashboard_task_assignee task with Some v -> `String v | None -> `Null);
      ("created_at", `String task.created_at);
    ]

let dashboard_agent_json (agent : Types.agent) =
  let (emoji, korean_name) = get_agent_identity agent.name in
  `Assoc
    [
      ("name", `String agent.name);
      ("agent_type", `String agent.agent_type);
      ("status", `String (Types.string_of_agent_status agent.status));
      ("current_task", match agent.current_task with Some task -> `String task | None -> `Null);
      ("joined_at", `String agent.joined_at);
      ("last_seen", `String agent.last_seen);
      ("capabilities", `List (List.map (fun item -> `String item) agent.capabilities));
      ("emoji", `String emoji);
      ("koreanName", `String korean_name);
    ]

let dashboard_message_json (message : Types.message) =
  `Assoc
    [
      ("from", `String message.from_agent);
      ("content", `String message.content);
      ("timestamp", `String message.timestamp);
      ("seq", `Int message.seq);
    ]

let dashboard_current_room_id config =
  Room.current_room_id config

let dashboard_tasks_safe config =
  Room.get_tasks_raw_in_room config (dashboard_current_room_id config)

let dashboard_agents_safe config =
  Room.get_agents_raw_in_room config (dashboard_current_room_id config)

let dashboard_messages_safe config ~since_seq ~limit =
  Room.get_messages_raw_in_room config ~room_id:(dashboard_current_room_id config) ~since_seq ~limit

let dashboard_shell_http_json (config : Room.config) : Yojson.Safe.t =
  Dashboard_cache.get_or_compute "shell" ~ttl:2.0 (fun () ->
    let agents = dashboard_agents_safe config in
  let tasks = dashboard_tasks_safe config in
  let keepers_json = keepers_dashboard_json ~compact:true config in
  let keepers_total = json_int_field "total" keepers_json ~default:0 in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("status", dashboard_shell_status_json config);
      ( "counts",
        `Assoc
          [
            ("agents", `Int (List.length agents));
            ("tasks", `Int (List.length tasks));
            ("keepers", `Int keepers_total);
          ] );
      ])

let dashboard_tools_http_json ?actor (config : Room.config) : Yojson.Safe.t =
  let ctx : Tool_misc.context =
    {
      config;
      agent_name = Option.value ~default:"dashboard" actor;
    }
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("tool_inventory", Tool_misc.tool_inventory_json ctx ~include_hidden:true ~include_deprecated:true);
      ("tool_usage", Tool_unified.summary_report ());
    ]

let dashboard_execution_http_json ~state ~sw ~clock request =
  let fixture = query_param request "fixture" in
  let actor = operator_actor_hint request in
  let cache_key =
    Printf.sprintf "execution:%s:%s"
      (Option.value ~default:"" actor)
      (Option.value ~default:"" fixture)
  in
  Dashboard_cache.get_or_compute cache_key ~ttl:3.0 (fun () ->
    Dashboard_execution.json ?actor ?fixture
      ~config:state.Mcp_server.room_config ~sw ~clock
      ~proc_mgr:state.Mcp_server.proc_mgr ())

let dashboard_room_truth_focus_json ~initialized ~agent_count ~operator_digest_json ~top_queue =
  let recommendation_summary =
    json_assoc_field "recommendation_summary" operator_digest_json
  in
  let attention_summary = json_assoc_field "attention_summary" operator_digest_json in
  let focus_of_recommendation top_action provenance =
    `Assoc
      [
        ("label", `String "운영 권고");
        ("reason", Yojson.Safe.Util.member "reason" top_action);
        ("source", `String "operator");
        ("provenance", `String provenance);
        ("target_kind", `String "action");
        ("target_id", Yojson.Safe.Util.member "target_id" top_action);
        ("suggested_tab", `String "intervene");
        ("suggested_surface", `Null);
        ( "suggested_params",
          `Assoc
            [
              ("action_type", Yojson.Safe.Util.member "action_type" top_action);
              ("target_type", Yojson.Safe.Util.member "target_type" top_action);
              ("target_id", Yojson.Safe.Util.member "target_id" top_action);
            ] );
      ]
  in
  let focus_of_attention top_item provenance =
    let target_type = json_string_field_opt "target_type" top_item in
    let target_id = json_string_field_opt "target_id" top_item in
    `Assoc
      [
        ("label", `String "주의 필요");
        ( "reason",
          match json_string_field_opt "summary" top_item with
          | Some summary -> `String summary
          | None -> `String "Operator attention item requires follow-up." );
        ("source", `String "operator");
        ("provenance", `String provenance);
        ("target_kind", `String "attention");
        ( "target_id",
          match target_id with
          | Some value -> `String value
          | None -> `Null );
        ("suggested_tab", `String "intervene");
        ("suggested_surface", `Null);
        ( "suggested_params",
          `Assoc
            (List.filter_map
               (fun (key, value_opt) ->
                 Option.map (fun value -> (key, `String value)) value_opt)
               [ ("target_type", target_type); ("target_id", target_id) ]) );
      ]
  in
  let focus_of_queue queue =
    let target_type =
      json_string_field_opt "target_type" queue |> Option.value ~default:"execution"
    in
    let target_id = json_string_field_opt "target_id" queue in
    let linked_session_id = json_string_field_opt "linked_session_id" queue in
    let linked_operation_id = json_string_field_opt "linked_operation_id" queue in
    let suggested_tab, suggested_surface, suggested_params =
      match linked_session_id with
      | Some session_id ->
          ( "intervene",
            None,
            `Assoc
              [
                ("target_type", `String "team_session");
                ("target_id", `String session_id);
              ] )
      | None -> (
          match linked_operation_id with
          | Some operation_id ->
              ( "command",
                Some "operations",
                `Assoc [ ("operation_id", `String operation_id) ] )
          | None ->
              ( "command",
                Some "summary",
                `Assoc
                  (List.filter_map
                     (fun (key, value_opt) ->
                       Option.map (fun value -> (key, `String value)) value_opt)
                     [ ("target_type", Some target_type); ("target_id", target_id) ]) ))
    in
    `Assoc
      [
        ( "label",
          `String
            (match json_string_field_opt "summary" queue with
            | Some summary -> summary
            | None -> "Execution queue requires attention.") );
        ( "reason",
          `String
            (match json_string_field_opt "summary" queue with
            | Some summary -> summary
            | None -> "Top execution queue item is the next drill-down target.") );
        ("source", `String "execution");
        ("provenance", `String "derived");
        ("target_kind", `String "queue");
        ( "target_id",
          match target_id with
          | Some value -> `String value
          | None -> `Null );
        ("suggested_tab", `String suggested_tab);
        ( "suggested_surface",
          match suggested_surface with
          | Some value -> `String value
          | None -> `Null );
        ("suggested_params", suggested_params);
      ]
  in
  match json_record_field "top_action" recommendation_summary with
  | Some top_action ->
      let provenance =
        Option.value
          ~default:"fallback"
          (json_string_field_opt "provenance" recommendation_summary)
      in
      focus_of_recommendation top_action provenance
  | None -> (
      match json_record_field "top_item" attention_summary with
      | Some top_item ->
          let provenance =
            Option.value
              ~default:"derived"
              (json_string_field_opt "provenance" attention_summary)
          in
          focus_of_attention top_item provenance
      | None -> (
          match top_queue with
          | `Assoc _ as queue -> focus_of_queue queue
          | _ ->
              let label, reason, source, provenance =
                if not initialized then
                  ( "초기 room truth",
                    "방이 아직 초기화되지 않았습니다. 기본 room 상태부터 확인하세요.",
                    "orchestra",
                    "derived" )
                else if agent_count = 0 then
                  ( "에이전트가 없습니다. 활동이 시작되면 여기에 포커스가 나타납니다.",
                    "No agents joined yet; room is idle.",
                    "room",
                    "fallback" )
                else
                  ( "지금은 방 전체가 비교적 안정적입니다",
                    "Room-wide view is healthy enough; start from the command overview.",
                    "room",
                    "fallback" )
              in
              `Assoc
                [
                  ("label", `String label);
                  ("reason", `String reason);
                  ("source", `String source);
                  ("provenance", `String provenance);
                  ("target_kind", `String "node");
                  ("target_id", `String "room:default");
                  ("suggested_tab", `String "command");
                  ("suggested_surface", `String "summary");
                  ("suggested_params", `Assoc []);
                ]))

let dashboard_room_truth_http_json ~state ~sw ~clock request =
  let config = state.Mcp_server.room_config in
  let shell_json = dashboard_shell_http_json config in
  let execution_json = dashboard_execution_http_json ~state ~sw ~clock request in
  let command_summary_json =
    if Room.is_initialized config then
      try
        Dashboard_cache.get_or_compute "command_summary" ~ttl:3.0 (fun () ->
          Server_command_plane_http.command_plane_summary_http_json ~state)
      with exn ->
        Log.Dashboard.warn "command_plane_summary: %s" (Printexc.to_string exn);
        `Assoc []
    else
      `Assoc []
  in
  (* Derive digest fields from execution_json to avoid duplicate
     Operator_control.digest_json call (saves ~3s).
     execution_json already calls digest_json internally. *)
  let operator_digest_json =
    let session_briefs = json_list_field "session_briefs" execution_json in
    let has_warn =
      List.exists (fun row ->
        let h = json_string_field_opt "health" row in
        h = Some "warn" || h = Some "bad"
      ) session_briefs
    in
    let health = if has_warn then "warn" else "ok" in
    `Assoc
      [
        ("health", `String health);
        ("attention_summary", `Assoc [ ("count", `Int (if has_warn then 1 else 0)); ("provenance", `String "derived") ]);
        ("recommendation_summary", `Assoc [ ("count", `Int 0); ("provenance", `String "derived") ]);
        ("pending_confirm_summary", Operator_control.pending_confirm_summary_json config);
      ]
  in
  let execution_queue =
    match Yojson.Safe.Util.member "execution_queue" execution_json with
    | `List items -> items
    | _ -> []
  in
  let execution_session_briefs = json_list_field "session_briefs" execution_json in
  let execution_operation_briefs = json_list_field "operation_briefs" execution_json in
  let execution_worker_support =
    json_list_field "worker_support_briefs" execution_json
  in
  let execution_continuity =
    json_list_field "continuity_briefs" execution_json
  in
  let execution_keepers = json_list_field "keepers" execution_json in
  let top_queue =
    match execution_queue with
    | head :: _ -> head
    | [] -> `Null
  in
  let has_text key json =
    match json_string_field_opt key json with
    | Some _ -> true
    | None -> false
  in
  let execution_summary =
    let existing = json_assoc_field "summary" execution_json in
    match Yojson.Safe.Util.member "blocked_sessions" existing with
    | `Int _ | `Intlit _ ->
        existing
    | _ ->
        `Assoc
          [
            ("active_sessions", `Int (List.length execution_session_briefs));
            ( "blocked_sessions",
              `Int
                (count_where execution_session_briefs
                   (fun row ->
                     let health = json_string_field_opt "health" row in
                     let status = json_string_field_opt "status" row in
                     has_text "blocker_summary" row
                     || health = Some "warn"
                     || health = Some "bad"
                     || status = Some "blocked")) );
            ("active_operations", `Int (List.length execution_operation_briefs));
            ( "blocked_operations",
              `Int (count_where execution_operation_briefs (has_text "blocker_summary")) );
            ( "worker_alerts",
              `Int
                (count_where execution_worker_support
                   (fun row ->
                     match json_string_field_opt "tone" row with
                     | Some "warn" | Some "bad" -> true
                     | _ -> false)) );
            ( "continuity_alerts",
              `Int
                (count_where execution_continuity
                   (fun row ->
                     match json_string_field_opt "tone" row with
                     | Some "warn" | Some "bad" -> true
                     | _ -> false)) );
            ("priority_items", `Int (List.length execution_queue));
            ("keepers", `Int (List.length execution_keepers));
          ]
  in
  let command_ops = json_assoc_field "operations" command_summary_json in
  let command_detachments = json_assoc_field "detachments" command_summary_json in
  let command_alerts = json_assoc_field "alerts" command_summary_json in
  let command_decisions = json_assoc_field "decisions" command_summary_json in
  let swarm_status = json_assoc_field "swarm_status" command_summary_json in
  let swarm_overview = json_assoc_field "overview" swarm_status in
  let command_summary =
    `Assoc
      [
        ( "active_operations",
          `Int
            (json_int_field "active" (json_assoc_field "summary" command_ops)
               ~default:0) );
        ( "active_detachments",
          `Int
            (json_int_field "active"
               (json_assoc_field "summary" command_detachments)
               ~default:0) );
        ( "pending_approvals",
          `Int
            (json_int_field "pending"
               (json_assoc_field "summary" command_decisions)
               ~default:0) );
        ( "bad_alerts",
          `Int
            (json_int_field "bad" (json_assoc_field "summary" command_alerts)
               ~default:0) );
        ( "warn_alerts",
          `Int
            (json_int_field "warn" (json_assoc_field "summary" command_alerts)
               ~default:0) );
        ("moving_lanes", `Int (json_int_field "moving_lanes" swarm_overview ~default:0));
        ("active_lanes", `Int (json_int_field "active_lanes" swarm_overview ~default:0));
        ("provenance", `String "truth");
      ]
  in
  let agent_count = json_int_field "agents" (json_assoc_field "counts" shell_json) ~default:0 in
  let focus_json =
    dashboard_room_truth_focus_json
      ~initialized:(Room.is_initialized config)
      ~agent_count
      ~operator_digest_json ~top_queue
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ( "room",
        `Assoc
          [
            ("status", json_assoc_field "status" shell_json);
            ("counts", json_assoc_field "counts" shell_json);
            ("provenance", `String "truth");
          ] );
      ( "execution",
        `Assoc
          [
            ("summary", execution_summary);
            ("top_queue", top_queue);
            ("provenance", `String "derived");
          ] );
      ("command", command_summary);
      ( "operator",
        `Assoc
          [
            ("health", Yojson.Safe.Util.member "health" operator_digest_json);
            ("attention_summary", json_assoc_field "attention_summary" operator_digest_json);
            ( "recommendation_summary",
              json_assoc_field "recommendation_summary" operator_digest_json );
            ( "pending_confirm_summary",
              json_assoc_field "pending_confirm_summary" operator_digest_json );
            ("provenance", `String "derived");
          ] );
      ("focus", focus_json);
    ]

let dashboard_memory_http_json request : Yojson.Safe.t =
  let hearth = query_param request "hearth" in
  let sort_by = board_sort_order_of_request request in
  let exclude_system = bool_query_param request "exclude_system" ~default:false in
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let fetch_limit = board_fetch_limit ~exclude_system ~limit ~offset in
  let posts = Board_dispatch.list_posts ?hearth ~sort_by ~limit:fetch_limit () in
  let posts = filter_board_posts ~exclude_system posts in
  let karma_map = Board_dispatch.get_all_karma () in
  let get_karma author =
    Option.value ~default:0 (List.assoc_opt author karma_map)
  in
  let paged = posts |> drop offset |> take limit in
  let posts_json =
    List.map
      (fun (post : Board.post) ->
        let author = Board.Agent_id.to_string post.author in
        board_post_dashboard_json ~author_karma:(get_karma author) post)
      paged
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("visible_posts", `Int (List.length posts_json));
            ("sort_by", `String (board_sort_label sort_by));
            ("exclude_system", `Bool exclude_system);
          ] );
      ("posts", `List posts_json);
      ("count", `Int (List.length posts_json));
      ("limit", `Int limit);
      ("offset", `Int offset);
      ("sort_by", `String (board_sort_label sort_by));
    ]

let dashboard_governance_http_json request ~base_path : Yojson.Safe.t =
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let status_filter =
    match query_param request "status" with
    | None -> None
    | Some raw -> (
        match String.lowercase_ascii (String.trim raw) with
        | "pending_ruling" -> Some Council.Governance_v2.Pending_ruling
        | "ready_auto_execute" -> Some Council.Governance_v2.Ready_auto_execute
        | "needs_human_gate" -> Some Council.Governance_v2.Needs_human_gate
        | "executed" -> Some Council.Governance_v2.Executed
        | "blocked" -> Some Council.Governance_v2.Blocked
        | "closed" -> Some Council.Governance_v2.Closed
        | _ -> None)
  in
  Dashboard_governance.dashboard_json ~base_path ~limit ~offset
    ~status_filter

let dashboard_planning_http_json request ~(config : Room.config) : Yojson.Safe.t =
  let goals = Goal_store.list_goals config () in
  let rollup = Goal_store.compute_rollup goals in
  let mdal_json =
    match mdal_loops_json ~config request with
    | Ok json -> json
    | Error message -> `Assoc [ ("error", `String message); ("loops", `List []) ]
  in
  let task_rollup =
    dashboard_tasks_safe config
    |> List.fold_left
         (fun (todo, claimed, running, done_count, cancelled) (task : Types.task) ->
           match task.task_status with
           | Todo -> (todo + 1, claimed, running, done_count, cancelled)
           | Claimed _ -> (todo, claimed + 1, running, done_count, cancelled)
           | InProgress _ -> (todo, claimed, running + 1, done_count, cancelled)
           | Done _ -> (todo, claimed, running, done_count + 1, cancelled)
           | Cancelled _ -> (todo, claimed, running, done_count, cancelled + 1))
         (0, 0, 0, 0, 0)
  in
  let (todo_count, claimed_count, running_count, done_count, cancelled_count) = task_rollup in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("goals", `List (List.map Goal_store.goal_to_yojson goals));
      ("rollup", Goal_store.rollup_to_yojson rollup);
      ("mdal", mdal_json);
      ( "task_backlog",
        `Assoc
          [
            ("todo", `Int todo_count);
            ("claimed", `Int claimed_count);
            ("in_progress", `Int running_count);
            ("done", `Int done_count);
            ("cancelled", `Int cancelled_count);
          ] );
    ]

let operator_action_http_json ~state ~sw ~clock request ~args =
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" (operator_actor_hint request);
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      mcp_session_id = None;
    }
  in
  Operator_control.action_json ?actor_hint:(operator_actor_hint request) ctx args

let operator_confirm_http_json ~state ~sw ~clock request ~args =
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" (operator_actor_hint request);
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      mcp_session_id = None;
    }
  in
  Operator_control.confirm_json ?actor_hint:(operator_actor_hint request) ctx args

let operator_error_json message =
  `Assoc [ ("status", `String "error"); ("message", `String message) ]
