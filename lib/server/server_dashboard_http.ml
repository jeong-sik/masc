(** Server_dashboard_http — Dashboard HTTP handlers (facade). *)

include Server_dashboard_http_core
open Types
open Server_utils

let contains_substring ~needle haystack =
  String_util.contains_substring haystack needle

let take n xs =
  let rec loop acc remaining xs =
    if remaining <= 0 then List.rev acc
    else
      match xs with
      | [] -> List.rev acc
      | x :: tl -> loop (x :: acc) (remaining - 1) tl
  in
  loop [] n xs

let trim_to_option raw =
  let trimmed = String.trim raw in
  if trimmed = "" then None else Some trimmed

let git_rev_parse_short path =
  match trim_to_option path with
  | None -> None
  | Some dir when not (Sys.file_exists dir) -> None
  | Some dir ->
      let channels =
        Unix.open_process_args_full "git"
          [| "git"; "-C"; dir; "rev-parse"; "--short"; "HEAD" |]
          (Unix.environment ())
      in
      let stdout, stdin, stderr = channels in
      (try
         close_out_noerr stdin;
         let output = In_channel.input_all stdout in
         ignore (In_channel.input_all stderr);
         match Unix.close_process_full channels with
         | Unix.WEXITED 0 -> trim_to_option output
         | _ -> None
       with
       | Sys_error _ | Unix.Unix_error _ ->
           ignore
             (try Unix.close_process_full channels
              with Unix.Unix_error _ -> Unix.WEXITED 1);
           None)

let path_item_json ~source path =
  `Assoc
    [
      ("path", `String path);
      ("exists", `Bool (String.trim path <> "" && Sys.file_exists path));
      ("source", `String source);
    ]

let shutdown_signal_of_message message =
  if contains_substring ~needle:"Received SIGTERM" message then Some "SIGTERM"
  else if contains_substring ~needle:"Received SIGINT" message then Some "SIGINT"
  else None

let runtime_diagnostics_json () =
  let entries = Log.Ring.recent ~limit:200 ~order:`Newest_first () in
  let diagnostics =
    entries
    |> List.filter_map (fun (entry : Log.Ring.entry) ->
           let message = entry.message in
           match shutdown_signal_of_message message with
           | Some signal ->
               Some
                 (`Assoc
                   [
                     ("ts", `String entry.ts);
                     ("kind", `String "external_signal");
                     ("signal", `String signal);
                     ("message", `String message);
                   ])
           | None when contains_substring
                           ~needle:"repairing state and rewriting canonical JSON"
                           message ->
               Some
                 (`Assoc
                   [
                     ("ts", `String entry.ts);
                     ("kind", `String "state_repair");
                     ("message", `String message);
                   ])
           | None when contains_substring ~needle:"invalid agent JSON" message
                       || contains_substring ~needle:"repaired agent JSON" message
                       || contains_substring
                            ~needle:"parse error: Types_core.agent.last_seen"
                            message ->
               Some
                 (`Assoc
                   [
                     ("ts", `String entry.ts);
                     ("kind", `String "agent_state");
                     ("message", `String message);
                   ])
           | None when contains_substring ~needle:"MaxClientsInSessionMode" message
                       || contains_substring
                            ~needle:
                              "Invalid concurrent usage of PostgreSQL connection"
                            message ->
               Some
                 (`Assoc
                   [
                     ("ts", `String entry.ts);
                     ("kind", `String "backend_pressure");
                     ("message", `String message);
                   ])
           | None -> None)
    |> take 8
  in
  let count kind =
    List.fold_left
      (fun acc json ->
        match Yojson.Safe.Util.member "kind" json with
        | `String value when String.equal value kind -> acc + 1
        | _ -> acc)
      0 diagnostics
  in
  (`List diagnostics, count "external_signal", count "state_repair",
   count "agent_state", count "backend_pressure")

let runtime_resolution_json (config : Room.config) =
  let build = Build_identity.current () in
  let runtime_commit = build.commit in
  let workspace_commit = git_rev_parse_short config.workspace_path in
  let resolved_base_commit = git_rev_parse_short config.base_path in
  let base_path_input =
    Env_config_core.base_path_opt ()
    |> Option.value ~default:config.workspace_path
  in
  let prompt_markdown_dir =
    Prompt_registry.get_markdown_dir () |> Option.value ~default:""
  in
  let prompt_outside_workspace =
    prompt_markdown_dir <> ""
    && not (String.starts_with ~prefix:config.workspace_path prompt_markdown_dir)
  in
  let source_mismatch =
    match runtime_commit, workspace_commit with
    | Some runtime, Some workspace -> not (String.equal runtime workspace)
    | _ -> false
  in
  let diagnostics, signal_count, repair_count, agent_issue_count, backend_pressure_count =
    runtime_diagnostics_json ()
  in
  let warnings =
    []
    |> fun acc ->
      if source_mismatch then
        let runtime = Option.value ~default:"unknown" runtime_commit in
        let workspace = Option.value ~default:"unknown" workspace_commit in
        (Printf.sprintf
           "Runtime build commit (%s) differs from workspace HEAD (%s). Rebuild/restart from the intended worktree."
           runtime workspace)
        :: acc
      else acc
    |> fun acc ->
      if prompt_outside_workspace then
        (Printf.sprintf
           "Prompt markdown dir resolves outside workspace path: %s"
           prompt_markdown_dir)
        :: acc
      else acc
    |> fun acc ->
      if signal_count > 0 then
        (Printf.sprintf
           "Recent external shutdown signals detected in server logs (%d). Ephemeral agents will not auto-rejoin after these restarts."
           signal_count)
        :: acc
      else acc
    |> fun acc ->
      if repair_count > 0 then
        (Printf.sprintf
           "Recent room-state repair events detected (%d)."
           repair_count)
        :: acc
      else acc
    |> fun acc ->
      if agent_issue_count > 0 then
        (Printf.sprintf
           "Recent agent-state compatibility warnings detected (%d)."
           agent_issue_count)
        :: acc
      else acc
    |> fun acc ->
      if backend_pressure_count > 0 then
        (Printf.sprintf
           "Recent PostgreSQL pressure warnings detected (%d)."
           backend_pressure_count)
        :: acc
      else acc
    |> List.rev
  in
  let status = if warnings = [] then "ready" else "warn" in
  `Assoc
    [
      ("status", `String status);
      ("warnings", `List (List.map (fun warning -> `String warning) warnings));
      ("base_path", path_item_json ~source:"input" base_path_input);
      ("workspace_path", path_item_json ~source:"workspace" config.workspace_path);
      ("resolved_base_path", path_item_json ~source:"resolved_base" config.base_path);
      ("data_root", path_item_json ~source:"runtime_data" (Room.masc_root_dir config));
      ("prompt_markdown_dir", path_item_json ~source:"prompt_registry" prompt_markdown_dir);
      ("workspace_git_commit", Option.fold ~none:`Null ~some:(fun value -> `String value) workspace_commit);
      ("resolved_base_git_commit", Option.fold ~none:`Null ~some:(fun value -> `String value) resolved_base_commit);
      ("source_mismatch", `Bool source_mismatch);
      ("diagnostics", diagnostics);
      ("build", Build_identity.to_yojson build);
    ]

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
      ("config_resolution", Config_dir_resolver.(resolve () |> to_json));
      ("runtime_resolution", runtime_resolution_json config);
      ("tool_inventory", Tool_misc.tool_inventory_json ctx ~include_hidden:true ~include_deprecated:true);
      ("tool_usage", Tool_unified.summary_report ());
    ]

(** Track whether shell cache has been populated at least once.
    Used for adaptive timeout in room-truth: cold path gets more time. *)
let _shell_warmed = ref false

let warm_shell_cache (state : Mcp_server.server_state) =
  let t0 = Time_compat.now () in
  (try
     ignore (dashboard_shell_http_json ?clock:state.Mcp_server.clock state.room_config);
     _shell_warmed := true;
     Log.Dashboard.info "shell cache pre-warmed (%.1fms)"
       ((Time_compat.now () -. t0) *. 1000.0)
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Dashboard.warn "shell cache pre-warm failed: %s"
       (Printexc.to_string exn))

(* Delta-push: track last broadcast hash per event_type to skip unchanged payloads. *)
let _last_broadcast_hash : (string, Digestif.SHA256.t) Hashtbl.t =
  Hashtbl.create 8

(** Broadcast a single cached surface to all Observer SSE sessions.
    [event_type] becomes the SSE event "type" field.
    Skips broadcast when payload hash matches the previous one (delta push).
    Safe to call from any fiber — reads only from a cached ref. *)
let broadcast_cached_surface ~event_type (json : Yojson.Safe.t) : unit =
  let serialized = Yojson.Safe.to_string json in
  let hash = Digestif.SHA256.digest_string serialized in
  let changed =
    match Hashtbl.find_opt _last_broadcast_hash event_type with
    | Some prev -> not (Digestif.SHA256.equal prev hash)
    | None -> true
  in
  if changed then begin
    Hashtbl.replace _last_broadcast_hash event_type hash;
    let sse_json =
      `Assoc
        [
          ("type", `String event_type);
          ("payload", json);
          ("ts_unix", `Float (Time_compat.now ()));
        ]
    in
    Sse.broadcast_to Observers sse_json
  end else
    Log.Dashboard.debug "%s: payload unchanged, skipping broadcast" event_type

(* Wire operator broadcast refs now that Sse is in scope. *)
let () = _operator_snapshot_broadcast_ref :=
  broadcast_cached_surface ~event_type:"operator_snapshot"
let () = _operator_digest_broadcast_ref :=
  broadcast_cached_surface ~event_type:"operator_digest"

let _execution_cache =
  create_cached_surface
    (`Assoc
      [
        ("status", `String "initializing");
        ("generated_at", `String (Types.now_iso ()));
        ("message", `String "Execution data is being computed. Refresh in a few seconds.");
      ])

(** Bypass the proactive warm-up guard so tests that call
    [dashboard_room_truth_http_json] get the full response instead of
    the "initializing" short-circuit. *)
let seed_execution_cache_for_test () =
  mark_cached_surface_success _execution_cache
    (`Assoc [("status", `String "seeded_for_test")])

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

let patch_keeper_row ~keeper_name ~keepalive_running = function
  | `Assoc fields as row -> (
      match Yojson.Safe.Util.member "name" row with
      | `String name when String.equal name keeper_name ->
          let row_fields : (string * Yojson.Safe.t) list = fields in
          `Assoc
            (row_fields
            |> upsert_assoc_field "keepalive_running" (`Bool keepalive_running))
      | _ -> row)
  | other -> other

let patch_keeper_rows ~keeper_name ~keepalive_running rows =
  List.map (patch_keeper_row ~keeper_name ~keepalive_running) rows

let running_keeper_names (config : Room.config) =
  Keeper_types.keeper_names config
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

(** Late-bound broadcast hook. Set after [broadcast_room_truth_snapshot]
    is defined below [dashboard_room_truth_focus_json]. The ref avoids
    OCaml's top-to-bottom forward-reference restriction. *)
let _broadcast_room_truth_ref : (Mcp_server.server_state -> unit) ref =
  ref (fun (_state : Mcp_server.server_state) -> ())

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
  let compute () =
    mark_cached_surface_attempt _execution_cache;
    let started_at = Unix.gettimeofday () in
    try
      run_dashboard_compute ~mode:Offloaded_readonly ~sw ~clock ~net
        ~mono_clock ~config:room_config
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
              with timeout_s = execution_refresh_timeout_s;
                   warm_delay_s = 0.0 }
    ~compute
    ~on_result:(fun json ->
      mark_cached_surface_success _execution_cache json;
      broadcast_cached_surface ~event_type:"execution_snapshot" json;
      !_broadcast_room_truth_ref state)

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
  let interval_s =
    float_of_env_default "MASC_DASHBOARD_TRANSPORT_HEALTH_INTERVAL_S"
      ~default:30.0 ~min_v:5.0 ~max_v:120.0
  in
  Proactive_refresh.start ~sw ~clock
    ~config:
      { (Proactive_refresh.default_config
           ~label:"transport_health" ~interval_s)
        with timeout_s;
             warm_delay_s = 0.0 }
    ~compute
    ~on_result:(fun json ->
      mark_cached_surface_success _transport_health_cache json;
      broadcast_cached_surface ~event_type:"transport_health_snapshot" json)

let dashboard_execution_http_json ~state ~sw ~clock request =
  let net = state.Mcp_server.net in
  let mono_clock = state.Mcp_server.mono_clock in
  let fixture = query_param request "fixture" in
  let actor = operator_actor_hint request in
  let full_mode = bool_query_param request "full" ~default:false in
  let light = not full_mode in
  let compute ?actor ?fixture ~light () =
    let started_at = Unix.gettimeofday () in
    run_dashboard_compute ~mode:Offloaded_readonly ?net ?mono_clock ~sw
      ~clock
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

let dashboard_room_truth_focus_json ~initialized ~runtime_count ~operator_digest_json ~top_queue =
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
                else if runtime_count = 0 then
                  ( "등록된 런타임이 없습니다. 활동이 시작되면 여기에 포커스가 나타납니다.",
                    "No agents or keepers joined yet; room is idle.",
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

let dashboard_room_truth_http_json ~state ~sw:_ ~clock _request =
  (* Fast-path: if the proactive execution refresh hasn't produced a result
     yet, return "initializing" immediately instead of blocking for 15-20s
     on cold-start on-demand compute.  The frontend retries every 3s via
     scheduleWarmRetry; the proactive refresh loop will populate
     _execution_cache in background.
     Escape hatch: if the first attempt started more than (timeout + 15s)
     ago, the proactive warm-up has timed out or failed — fall through to
     normal on-demand computation.  Since #3278 Proactive_refresh.start
     calls on_error on timeout, so last_error_unix is populated. The
     time-based escape remains as defense in depth. *)
  let warm_escape_s =
    float_of_env_default "MASC_DASHBOARD_EXECUTION_REFRESH_TIMEOUT_S"
      ~default:75.0 ~min_v:30.0 ~max_v:300.0
    +. 15.0
  in
  let proactive_first_cycle_pending =
    not (cached_surface_has_success _execution_cache)
    && (match _execution_cache.last_attempt_unix with
        | None -> true (* proactive hasn't started yet *)
        | Some attempt_ts ->
            let elapsed = Time_compat.now () -. attempt_ts in
            elapsed < warm_escape_s
            && Option.is_none _execution_cache.last_error_unix)
  in
  if proactive_first_cycle_pending then
    `Assoc [
      ("status", `String "initializing");
      ("generated_at", `String (Types.now_iso ()));
      ("message",
       `String "Execution snapshot is still warming up. The dashboard will retry automatically.");
    ]
  else
  with_dashboard_timeout ~clock (fun () ->
  let config = state.Mcp_server.room_config in
  let started_at = Unix.gettimeofday () in
  let t0 = Time_compat.now () in
  (* Staged fetch: shell may still need a guarded refresh, while execution
     stays on the proactive cache to keep room-truth off the cold path. *)
  let shell_ref = ref (`Assoc []) in
  let execution_ref = ref (`Assoc []) in
  let command_ref = ref (`Assoc []) in
  (* Single env var for room-truth fiber timeouts.
     Cold start uses higher defaults to allow shell/room reads to warm up. *)
  let warm_timeout_s =
    float_of_env_default "MASC_DASHBOARD_ROOM_TRUTH_TIMEOUT_S"
      ~default:5.0 ~min_v:2.0 ~max_v:25.0
  in
  let cold_timeout_s =
    float_of_env_default "MASC_DASHBOARD_ROOM_TRUTH_COLD_TIMEOUT_S"
      ~default:15.0 ~min_v:5.0 ~max_v:60.0
  in
  let is_cold = not (cached_surface_has_success _execution_cache) in
  let base_timeout_s = if is_cold then cold_timeout_s else warm_timeout_s in
  let fiber_with_timeout ?(timeout_s = base_timeout_s) label f fallback =
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
    if !_shell_warmed then base_timeout_s else cold_timeout_s
  in
  (* Sequential fetch to avoid PG connection concurrent usage (#3305).
     Each component has its own timeout guard and cache fallback,
     so sequential execution adds minimal latency on cache hit. *)
  shell_ref := fiber_with_timeout ~timeout_s:shell_timeout_s "shell"
    (fun () -> dashboard_shell_http_json ~clock config) (`Assoc []);
  execution_ref := cached_surface_json _execution_cache;
  (* command_plane_summary_http_json reads from a proactive cache ref —
     no PG I/O needed.  Skip the Room.is_initialized guard (which does a
     PG query in PostgresNative mode) to avoid 200-500ms latency. *)
  command_ref := Server_command_plane_http.command_plane_summary_http_json ~state;
  let shell_json = !shell_ref in
  if (not !_shell_warmed) && shell_json <> `Assoc [] then
    _shell_warmed := true;
  let execution_json = !execution_ref in
  let command_summary_json = !command_ref in
  let parallel_ms = (Time_compat.now () -. t0) *. 1000.0 in
  if parallel_ms >= 100.0 then
    Log.Dashboard.info "room-truth fetch: %.0fms" parallel_ms
  else
    Log.Dashboard.debug "room-truth fetch: %.0fms" parallel_ms;
  let execution_cache_state =
    json_assoc_field "projection_diagnostics" execution_json
    |> json_string_field_opt "cache_state"
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
  let shell_counts = json_assoc_field "counts" shell_json in
  let runtime_count =
    json_int_field "agents" shell_counts ~default:0
    + json_int_field "keepers" shell_counts ~default:0
  in
  let focus_json =
    dashboard_room_truth_focus_json
      ~initialized:(Room.is_initialized config)
      ~runtime_count
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

(** Assemble a lightweight room-truth snapshot from cached refs only.
    No PG I/O — reads proactive caches for execution and command, and
    the TTL-cached shell.  Returns None when the execution cache has not
    produced its first successful result (cold start). *)
let room_truth_snapshot_from_caches (state : Mcp_server.server_state) :
    Yojson.Safe.t option =
  if not (cached_surface_has_success _execution_cache) then None
  else
    let config = state.room_config in
    let shell_json =
      if !_shell_warmed then
        try dashboard_shell_http_json ?clock:state.Mcp_server.clock config
        with _ -> `Assoc []
      else `Assoc []
    in
    let execution_json = cached_surface_json _execution_cache in
    let command_summary_json =
      Server_command_plane_http.command_plane_summary_http_json ~state
    in
    let session_briefs = json_list_field "session_briefs" execution_json in
    let has_warn =
      List.exists
        (fun row ->
          let h = json_string_field_opt "health" row in
          h = Some "warn" || h = Some "bad")
        session_briefs
    in
    let health = if has_warn then "warn" else "ok" in
    let operator_digest_json =
      `Assoc
        [
          ("health", `String health);
          ( "attention_summary",
            `Assoc
              [
                ("count", `Int (if has_warn then 1 else 0));
                ("provenance", `String "derived");
              ] );
          ( "recommendation_summary",
            `Assoc [ ("count", `Int 0); ("provenance", `String "derived") ] );
          ( "pending_confirm_summary",
            Dashboard_cache.get_or_compute "pending_confirm_summary" ~ttl:10.0
              (fun () -> Operator_control.pending_confirm_summary_json config)
          );
        ]
    in
    let execution_queue =
      match Yojson.Safe.Util.member "execution_queue" execution_json with
      | `List items -> items
      | _ -> []
    in
    let take_n n lst =
      if List.length lst <= n then lst
      else List.filteri (fun i _ -> i < n) lst
    in
    let execution_session_briefs = session_briefs |> take_n 20 in
    let execution_operation_briefs =
      json_list_field "operation_briefs" execution_json |> take_n 20
    in
    let execution_keepers =
      json_list_field "keepers" execution_json |> take_n 20
    in
    let execution_worker_support =
      json_list_field "worker_support_briefs" execution_json |> take_n 10
    in
    let execution_continuity =
      json_list_field "continuity_briefs" execution_json |> take_n 10
    in
    let top_queue =
      match execution_queue with head :: _ -> head | [] -> `Null
    in
    let has_text key json = json_string_field_opt key json |> Option.is_some in
    let execution_summary =
      let existing = json_assoc_field "summary" execution_json in
      match Yojson.Safe.Util.member "blocked_sessions" existing with
      | `Int _ | `Intlit _ -> existing
      | _ ->
          `Assoc
            [
              ("active_sessions", `Int (List.length execution_session_briefs));
              ( "blocked_sessions",
                `Int
                  (count_where execution_session_briefs (fun row ->
                       let health_v = json_string_field_opt "health" row in
                       let status = json_string_field_opt "status" row in
                       has_text "blocker_summary" row
                       || health_v = Some "warn"
                       || health_v = Some "bad"
                       || status = Some "blocked")) );
              ( "active_operations",
                `Int (List.length execution_operation_briefs) );
              ( "blocked_operations",
                `Int
                  (count_where execution_operation_briefs
                     (has_text "blocker_summary")) );
              ( "worker_alerts",
                `Int
                  (count_where execution_worker_support (fun row ->
                       match json_string_field_opt "tone" row with
                       | Some "warn" | Some "bad" -> true
                       | _ -> false)) );
              ( "continuity_alerts",
                `Int
                  (count_where execution_continuity (fun row ->
                       match json_string_field_opt "tone" row with
                       | Some "warn" | Some "bad" -> true
                       | _ -> false)) );
              ("priority_items", `Int (List.length execution_queue));
              ("keepers", `Int (List.length execution_keepers));
            ]
    in
    let command_ops = json_assoc_field "operations" command_summary_json in
    let command_detachments =
      json_assoc_field "detachments" command_summary_json
    in
    let command_alerts = json_assoc_field "alerts" command_summary_json in
    let command_decisions = json_assoc_field "decisions" command_summary_json in
    let swarm_status = json_assoc_field "swarm_status" command_summary_json in
    let swarm_overview = json_assoc_field "overview" swarm_status in
    let command_summary =
      `Assoc
        [
          ( "active_operations",
            `Int
              (json_int_field "active"
                 (json_assoc_field "summary" command_ops)
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
              (json_int_field "bad"
                 (json_assoc_field "summary" command_alerts)
                 ~default:0) );
          ( "warn_alerts",
            `Int
              (json_int_field "warn"
                 (json_assoc_field "summary" command_alerts)
                 ~default:0) );
          ( "moving_lanes",
            `Int (json_int_field "moving_lanes" swarm_overview ~default:0) );
          ( "active_lanes",
            `Int (json_int_field "active_lanes" swarm_overview ~default:0) );
          ("provenance", `String "truth");
        ]
    in
    let shell_counts = json_assoc_field "counts" shell_json in
    let runtime_count =
      json_int_field "agents" shell_counts ~default:0
      + json_int_field "keepers" shell_counts ~default:0
    in
    let focus_json =
      dashboard_room_truth_focus_json
        ~initialized:(Room.is_initialized config)
        ~runtime_count ~operator_digest_json ~top_queue
    in
    Some
      (`Assoc
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
                ( "health",
                  Yojson.Safe.Util.member "health" operator_digest_json );
                ( "attention_summary",
                  json_assoc_field "attention_summary" operator_digest_json );
                ( "recommendation_summary",
                  json_assoc_field "recommendation_summary"
                    operator_digest_json );
                ( "pending_confirm_summary",
                  json_assoc_field "pending_confirm_summary"
                    operator_digest_json );
                ("provenance", `String "derived");
              ] );
          ("focus", focus_json);
        ])

(** Broadcast current room-truth snapshot to all Observer SSE sessions.
    Called after proactive cache refreshes and keeper lifecycle events.
    Safe to call from any fiber — reads only from cached refs. *)
let broadcast_room_truth_snapshot (state : Mcp_server.server_state) : unit =
  match room_truth_snapshot_from_caches state with
  | None -> ()
  | Some snapshot ->
      let sse_json =
        `Assoc
          [
            ("type", `String "room_truth_snapshot");
            ("payload", snapshot);
            ("ts_unix", `Float (Time_compat.now ()));
          ]
      in
      Sse.broadcast_to Observers sse_json;
      Log.Dashboard.info "room-truth snapshot pushed via SSE"

(* Wire up the late-bound broadcast ref now that both
   [dashboard_room_truth_focus_json] and [broadcast_room_truth_snapshot]
   are defined. *)
let () = _broadcast_room_truth_ref := broadcast_room_truth_snapshot

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
    Board_dispatch.list_posts ?hearth ~sort_by ~exclude_system
      ~exclude_automation ~limit:fetch_limit ()
  in
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
      net = state.Mcp_server.net;
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
      net = state.Mcp_server.net;
      mcp_session_id = None;
    }
  in
  Operator_control.confirm_json ?actor_hint:(operator_actor_hint request) ctx args

let operator_error_json message =
  `Assoc [ ("status", `String "error"); ("message", `String message) ]
