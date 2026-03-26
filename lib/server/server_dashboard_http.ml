(** Server_dashboard_http — Dashboard HTTP handlers (facade). *)

include Server_dashboard_http_core
open Types
open Server_utils

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

(** Track whether shell cache has been populated at least once.
    Used for adaptive timeout in room-truth: cold path gets more time. *)
let _shell_warmed = ref false

let warm_shell_cache (state : Mcp_server.server_state) =
  let t0 = Time_compat.now () in
  (try
     ignore (dashboard_shell_http_json state.room_config);
     _shell_warmed := true;
     Log.Dashboard.info "shell cache pre-warmed (%.1fms)"
       ((Time_compat.now () -. t0) *. 1000.0)
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Dashboard.warn "shell cache pre-warm failed: %s"
       (Printexc.to_string exn))

let _execution_cache =
  create_cached_surface
    (`Assoc
      [
        ("status", `String "initializing");
        ("generated_at", `String (Types.now_iso ()));
        ("message", `String "Execution data is being computed. Refresh in a few seconds.");
      ])

let _transport_health_cache =
  create_cached_surface
    (`Assoc
      [
        ("status", `String "initializing");
        ("generated_at", `String (Types.now_iso ()));
        ( "message",
          `String "Transport health data is warming up. Refresh in a few seconds." );
      ])

let keepalive_running_of_lifecycle_event = function
  | "started" | "restarted" | "reconciled" -> Some true
  | "stopped" | "crashed" | "dead" -> Some false
  | _ -> None

let patch_keeper_diagnostic ~keepalive_running (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
      let fields =
        upsert_assoc_field "keepalive_running" (`Bool keepalive_running) fields
      in
      let fields =
        if keepalive_running then
          let fields =
            match List.assoc_opt "continuity_state" fields with
            | Some (`String ("not_running" | "desired_offline" | "disabled")) ->
                upsert_assoc_field "continuity_state" (`String "recovering") fields
            | _ -> fields
          in
          match List.assoc_opt "quiet_reason" fields with
          | Some (`String "not_running") ->
              upsert_assoc_field "quiet_reason" `Null fields
          | _ -> fields
        else
          fields
          |> upsert_assoc_field "continuity_state" (`String "not_running")
          |> upsert_assoc_field "quiet_reason" (`String "not_running")
      in
      `Assoc fields
  | other -> other

let patch_keeper_row ~keeper_name ~keepalive_running = function
  | `Assoc fields as row -> (
      match Yojson.Safe.Util.member "name" row with
      | `String name when String.equal name keeper_name ->
          let diagnostic =
            match Yojson.Safe.Util.member "diagnostic" row with
            | `Assoc _ as json ->
                patch_keeper_diagnostic ~keepalive_running json
            | `Null ->
                `Assoc
                  [
                    ("keepalive_running", `Bool keepalive_running);
                    ( "continuity_state",
                      `String (if keepalive_running then "recovering" else "not_running") );
                  ]
            | other -> other
          in
          let row_fields : (string * Yojson.Safe.t) list = fields in
          `Assoc
            (row_fields
            |> upsert_assoc_field "keepalive_running" (`Bool keepalive_running)
            |> upsert_assoc_field "diagnostic" diagnostic)
      | _ -> row)
  | other -> other

let patch_keeper_rows ~keeper_name ~keepalive_running rows =
  List.map (patch_keeper_row ~keeper_name ~keepalive_running) rows

let running_keeper_names (config : Room.config) =
  Keeper_types.resident_keeper_names config
  |> List.filter_map (fun name ->
         match Keeper_types.read_meta config name with
         | Ok (Some meta)
           when Keeper_status_bridge.runtime_keepalive_running config meta ->
             Some name
         | _ -> None)

let patch_surface_json_for_running_keepers (config : Room.config) = function
  | `Assoc fields as json ->
      let running = running_keeper_names config in
      if running = [] then json
      else
        let patch_rows rows =
          List.fold_left
            (fun acc keeper_name ->
              patch_keeper_rows ~keeper_name ~keepalive_running:true acc)
            rows running
        in
        (match List.assoc_opt "keepers" fields with
         | Some (`List rows) ->
             `Assoc
               (upsert_assoc_field "keepers" (`List (patch_rows rows)) fields)
         | Some (`Assoc keeper_fields) -> (
             match List.assoc_opt "items" keeper_fields with
             | Some (`List rows) ->
                 let keeper_fields =
                   upsert_assoc_field "items" (`List (patch_rows rows))
                     keeper_fields
                 in
                 `Assoc
                   (upsert_assoc_field "keepers" (`Assoc keeper_fields) fields)
             | _ -> json)
         | _ -> json)
  | other -> other

let patch_execution_cache_for_keeper ~keeper_name ~keepalive_running =
  match _execution_cache.json with
  | `Assoc fields -> (
      match List.assoc_opt "keepers" fields with
      | Some (`List rows) ->
          _execution_cache.json <-
            `Assoc
              (upsert_assoc_field "keepers"
                 (`List (patch_keeper_rows ~keeper_name ~keepalive_running rows))
                 fields)
      | _ -> ())
  | _ -> ()

let patch_operator_snapshot_cache_for_keeper ~keeper_name ~keepalive_running =
  match _operator_snapshot_cache.json with
  | `Assoc fields -> (
      match List.assoc_opt "keepers" fields with
      | Some (`Assoc keeper_fields) -> (
          match List.assoc_opt "items" keeper_fields with
          | Some (`List rows) ->
              let keeper_fields =
                upsert_assoc_field "items"
                  (`List (patch_keeper_rows ~keeper_name ~keepalive_running rows))
                  keeper_fields
              in
              _operator_snapshot_cache.json <-
                `Assoc
                  (upsert_assoc_field "keepers" (`Assoc keeper_fields) fields)
          | _ -> ())
      | _ -> ())
  | _ -> ()

let patch_keeper_dependent_caches ~keeper_name ~event =
  match keepalive_running_of_lifecycle_event event with
  | None -> ()
  | Some keepalive_running ->
      patch_execution_cache_for_keeper ~keeper_name ~keepalive_running;
      patch_operator_snapshot_cache_for_keeper ~keeper_name ~keepalive_running

(** Start the proactive execution refresh loop.  When an Executor_pool
    is available, each refresh runs in a pool domain with a domain-local
    Caqti pool (the main domain's Caqti pool is domain-bound due to
    Switch capture in release).  Falls back to in-domain compute. *)
let start_execution_refresh_loop ~state ~sw ~clock ~net ~mono_clock =
  let room_config = state.Mcp_server.room_config in
  let proc_mgr = state.Mcp_server.proc_mgr in
  let execution_refresh_timeout_s =
    float_of_env_default "MASC_DASHBOARD_EXECUTION_REFRESH_TIMEOUT_S"
      ~default:75.0 ~min_v:30.0 ~max_v:300.0
  in
  ignore net;
  ignore mono_clock;
  let compute () =
    mark_cached_surface_attempt _execution_cache;
    let started_at = Unix.gettimeofday () in
    try
      run_dashboard_compute ~mode:Offloaded_readonly ~sw ~clock ~config:room_config
        (fun ~config ~sw ->
          Dashboard_execution.json ~light:true ~config ~sw ~clock ~proc_mgr ()
          |> patch_surface_json_for_running_keepers config
          |> with_projection_diagnostics ~surface:"execution" ~started_at
               ~extra:
                 [
                   ("session_list", Team_session_store.session_list_diagnostics_json ());
                   ("readonly_pool", Room_utils.domain_local_pg_backend_diagnostics_json ());
                 ])
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      mark_cached_surface_error _execution_cache exn;
      raise exn
  in
  Proactive_refresh.start ~sw ~clock
    ~config:{ (Proactive_refresh.default_config ~label:"execution" ~interval_s:60.0)
              with timeout_s = execution_refresh_timeout_s }
    ~compute
    ~on_result:(mark_cached_surface_success _execution_cache)

let start_transport_health_refresh_loop ~state ~sw ~clock =
  let timeout_s =
    float_of_env_default "MASC_DASHBOARD_TRANSPORT_HEALTH_TIMEOUT_S"
      ~default:8.0 ~min_v:3.0 ~max_v:30.0
  in
  let compute () =
    mark_cached_surface_attempt _transport_health_cache;
    try
      Transport_metrics.transport_health_json
        ~config:state.Mcp_server.room_config
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        mark_cached_surface_error _transport_health_cache exn;
        raise exn
  in
  Proactive_refresh.start ~sw ~clock
    ~config:
      { (Proactive_refresh.default_config
           ~label:"transport_health" ~interval_s:15.0)
        with timeout_s }
    ~compute
    ~on_result:(mark_cached_surface_success _transport_health_cache)

let dashboard_execution_http_json ~state ~sw ~clock request =
  let fixture = query_param request "fixture" in
  let actor = operator_actor_hint request in
  let full_mode = bool_query_param request "full" ~default:false in
  let light = not full_mode in
  let compute ?actor ?fixture ~light () =
    let started_at = Unix.gettimeofday () in
    run_dashboard_compute ~mode:Offloaded_readonly ~sw ~clock
      ~config:state.Mcp_server.room_config
      (fun ~config ~sw ->
        Dashboard_execution.json ?actor ?fixture ~light
          ~config ~sw ~clock
          ~proc_mgr:state.Mcp_server.proc_mgr ()
        |> patch_surface_json_for_running_keepers config
        |> with_projection_diagnostics ~surface:"execution" ~started_at
             ~extra:
               [
                 ("session_list", Team_session_store.session_list_diagnostics_json ());
                 ("readonly_pool", Room_utils.domain_local_pg_backend_diagnostics_json ());
               ])
  in
  match fixture, actor, full_mode with
  | None, None, false ->
    (* Default light mode: stay instant after first success, but avoid
       serving the empty initializing payload forever when proactive warm-up
       misses its first build window. *)
    cached_surface_or_first_success_json _execution_cache
      ~cache_key:"execution:default:light" ~ttl:120.0 ~clock
      ~timeout_sec:120.0
      (compute ~light:true)
  | _ ->
    (* Parameterized requests (fixture/actor/full): on-demand with SWR cache.
       These are rare (test fixtures, actor-specific views, full mode). *)
    let cache_key =
      Printf.sprintf "execution:%s:%s:%s"
        (Option.value ~default:"" actor)
        (Option.value ~default:"" fixture)
        (if full_mode then "full" else "light")
    in
    Dashboard_cache.get_or_compute_with_timeout cache_key ~ttl:120.0
      ~clock ~timeout_sec:120.0 (compute ?actor ?fixture ~light)

let dashboard_transport_health_http_json ~state:_ =
  cached_surface_json _transport_health_cache

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
  with_dashboard_timeout ~clock (fun () ->
  let config = state.Mcp_server.room_config in
  let started_at = Unix.gettimeofday () in
  let t0 = Time_compat.now () in
  (* Parallel fetch: shell, execution, and command_summary are independent. *)
  let shell_ref = ref (`Assoc []) in
  let execution_ref = ref (`Assoc []) in
  let command_ref = ref (`Assoc []) in
  let default_timeout_s =
    float_of_env_default "MASC_DASHBOARD_ROOM_TRUTH_TIMEOUT_S"
      ~default:5.0 ~min_v:2.0 ~max_v:25.0
  in
  let fiber_with_timeout ?(timeout_s = default_timeout_s) label f fallback =
    try
      match Eio.Time.with_timeout clock timeout_s (fun () -> Ok (f ())) with
      | Ok v -> v
      | Error `Timeout ->
        Log.Dashboard.warn "room-truth fiber %s timed out (%.0fs)" label timeout_s;
        fallback
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Log.Dashboard.warn "room-truth fiber %s failed: %s" label (Printexc.to_string exn);
      fallback
  in
  let shell_timeout_s =
    if !_shell_warmed then default_timeout_s else 15.0
  in
  let execution_timeout_s =
    if cached_surface_has_success _execution_cache then default_timeout_s else 20.0
  in
  Eio.Fiber.all [
    (fun () -> shell_ref := fiber_with_timeout ~timeout_s:shell_timeout_s "shell"
      (fun () -> dashboard_shell_http_json config) (`Assoc []));
    (fun () -> execution_ref := fiber_with_timeout ~timeout_s:execution_timeout_s "execution"
      (fun () -> dashboard_execution_http_json ~state ~sw ~clock request)
      (cached_surface_json _execution_cache));
    (fun () ->
      command_ref := fiber_with_timeout "command"
        (fun () ->
          if Room.is_initialized config then
            Server_command_plane_http.command_plane_summary_http_json ~state
          else `Assoc [])
        (`Assoc []));
  ];
  let shell_json = !shell_ref in
  if (not !_shell_warmed) && shell_json <> `Assoc [] then
    _shell_warmed := true;
  let execution_json = !execution_ref in
  let command_summary_json = !command_ref in
  let parallel_ms = (Time_compat.now () -. t0) *. 1000.0 in
  Log.Dashboard.info "room-truth parallel fetch: %.0fms" parallel_ms;
  let execution_cache_state =
    json_assoc_field "projection_diagnostics" execution_json
    |> json_string_field_opt "cache_state"
  in
  if execution_cache_state = Some "initializing" then
    `Assoc
      [
        ("status", `String "initializing");
        ("generated_at", `String (Types.now_iso ()));
        ( "message",
          `String
            "Execution snapshot is still warming up. The dashboard will retry automatically." );
      ]
  else
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
        ("pending_confirm_summary",
          Dashboard_cache.get_or_compute "pending_confirm_summary" ~ttl:10.0 (fun () ->
            Operator_control.pending_confirm_summary_json config));
      ]
  in
  let execution_queue =
    match Yojson.Safe.Util.member "execution_queue" execution_json with
    | `List items -> items
    | _ -> []
  in
  let take_n n lst = if List.length lst <= n then lst else List.filteri (fun i _ -> i < n) lst in
  let execution_session_briefs = json_list_field "session_briefs" execution_json |> take_n 20 in
  let execution_operation_briefs = json_list_field "operation_briefs" execution_json |> take_n 20 in
  let execution_worker_support =
    json_list_field "worker_support_briefs" execution_json |> take_n 10
  in
  let execution_continuity =
    json_list_field "continuity_briefs" execution_json |> take_n 10
  in
  let execution_keepers = json_list_field "keepers" execution_json |> take_n 20 in
  let top_queue =
    match execution_queue with
    | head :: _ -> head
    | [] -> `Null
  in
  let has_text key json =
    json_string_field_opt key json |> Option.is_some
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
  |> with_projection_diagnostics ~surface:"room_truth" ~started_at
       ~extra:
         [
           ("parallel_ms", `Int (int_of_float parallel_ms));
           ( "execution_cache_state",
             match execution_cache_state with
             | Some value -> `String value
             | None -> `Null );
         ])

let dashboard_memory_http_json request : Yojson.Safe.t =
  let hearth = query_param request "hearth" in
  let sort_by = board_sort_order_of_request request in
  let exclude_system = bool_query_param request "exclude_system" ~default:false in
  let exclude_automation =
    bool_query_param request "exclude_automation" ~default:false
  in
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let fetch_limit =
    board_fetch_limit ~exclude_system ~exclude_automation ~limit ~offset
  in
  let posts =
    Board_dispatch.list_posts ?hearth ~sort_by ~limit:fetch_limit ()
  in
  let posts = filter_board_posts ~exclude_system ~exclude_automation posts in
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
            ("exclude_automation", `Bool exclude_automation);
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
