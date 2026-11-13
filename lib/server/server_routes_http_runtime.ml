
open Server_utils
open Server_auth

open Server_routes_http_common

module Http = Http_server_eio

let is_dashboard_spa_deep_link path =
  String.starts_with ~prefix:"/dashboard/" path
  && not (String.starts_with ~prefix:"/dashboard/assets/" path)

(** CORS preflight response headers *)
let cors_preflight_headers origin =
  [
    ("access-control-allow-origin", origin);
    ("access-control-allow-methods", "GET, POST, DELETE, OPTIONS");
    ("access-control-allow-headers", cors_allow_headers_value);
    ("access-control-expose-headers", "Mcp-Session-Id, Mcp-Protocol-Version");
  ]

(** JSON-RPC error response helper *)
let json_rpc_error (code : Mcp_error_code.t) message =
  Mcp_error_code.jsonrpc_error_body code ~message

(** Server start time for uptime calculation *)
(* server_start_time moved to [Server_routes_http_runtime_health_helpers]
   (godfile decomp). *)

let server_start_time = Server_routes_http_runtime_health_helpers.server_start_time

let authority_host host =
  match Ipaddr.of_string host with
  | Ok (Ipaddr.V6 _) -> "[" ^ host ^ "]"
  | Ok (Ipaddr.V4 _) | Error _ -> host

let authority_of_host_port host port =
  Printf.sprintf "%s:%d" (authority_host host) port

let advertised_host_port_authority ~request_authority =
  let request_host = Server_request_authority.host request_authority in
  let port_opt = Server_request_authority.port request_authority in
  let port = Server_request_authority.port_or_default request_authority in
  let host = Transport_read_model.normalize_advertised_host request_host in
  let authority =
    match port_opt with
    | Some _ -> authority_of_host_port host port
    | None -> authority_host host
  in
  host, port, authority

let advertised_host_port ~request_authority =
  let host, port, _authority =
    advertised_host_port_authority ~request_authority
  in
  (host, port)

let advertised_base_url ~request_authority _request =
  let _host, _port, authority =
    advertised_host_port_authority ~request_authority
  in
  Printf.sprintf
    "%s://%s"
    (Server_request_authority.scheme request_authority
     |> Server_request_authority.scheme_to_string)
    authority

let websocket_discovery_json ~request_authority request =
  let host, _port = advertised_host_port ~request_authority in
  let ctx =
    Transport_read_model.make_http_context ~include_configured:true
      ~host ~base_url:(advertised_base_url ~request_authority request) ()
  in
  Transport_read_model.websocket_discovery_json ctx

let transport_json ~request_authority request =
  let host, _port = advertised_host_port ~request_authority in
  let ctx =
    Transport_read_model.make_http_context ~include_configured:true
      ~host ~base_url:(advertised_base_url ~request_authority request) ()
  in
  Transport_read_model.transport_status_json ctx

let agent_card_json ~request_authority request =
  let host, port = advertised_host_port ~request_authority in
  let base_url = advertised_base_url ~request_authority request in
  let build = Build_identity.current () in
  `Assoc
    [
      ("schema", `String "masc.agent_card.v1");
      ("name", `String "MASC");
      ("description", `String "MASC multi-agent workspace MCP server");
      ("url", `String base_url);
      ("version", `String build.release_version);
      ( "build",
        `Assoc
          [
            ( "commit",
              Option.fold ~none:`Null ~some:(fun value -> `String value)
                build.commit );
            ( "commit_source",
              Option.fold ~none:`Null ~some:(fun value -> `String value)
                build.commit_source );
            ( "binary_commit",
              Option.fold ~none:`Null ~some:(fun value -> `String value)
                build.binary_commit );
            ( "repo_head_commit",
              Option.fold ~none:`Null ~some:(fun value -> `String value)
                build.repo_head_commit );
            ("started_at", `String build.started_at);
            ("uptime_seconds", `Int build.uptime_seconds);
          ] );
      ( "endpoints",
        `Assoc
          [
            ("mcp", `String (base_url ^ "/mcp"));
            ("health", `String (base_url ^ Server_health_paths.health));
            ("dashboard", `String (base_url ^ "/dashboard/"));
            ("websocket", `String (base_url ^ "/ws"));
          ] );
      ("transport", Transport_bridge.agent_card_transports_json ~host ~port);
      ( "capabilities",
        `Assoc
          [
            ("workspace", `Bool true);
            ("task_backlog", `Bool true);
            ("keeper_runtime", `Bool true);
            ("dashboard", `Bool true);
          ] );
    ]

(* /health probe building blocks (path diagnostics, uptime, protocol
   negotiation, GC counters) extracted to
   [Server_routes_http_runtime_health_helpers] (godfile decomp). *)
let health_path_diagnostics = Server_routes_http_runtime_health_helpers.health_path_diagnostics
let health_uptime_secs = Server_routes_http_runtime_health_helpers.health_uptime_secs
let health_uptime_string = Server_routes_http_runtime_health_helpers.health_uptime_string
let protocol_json = Server_routes_http_runtime_health_helpers.protocol_json
let quick_gc_json = Server_routes_http_runtime_health_helpers.quick_gc_json
let process_memory_json = Server_routes_http_runtime_health_helpers.process_memory_json
let scheduler_json = Server_routes_http_runtime_health_helpers.scheduler_json

let internal_keeper_token_hash_opt ~base_path =
  let hash_file = Auth.internal_keeper_token_hash_file base_path in
  if Sys.file_exists hash_file then
    try
      let hash =
        In_channel.with_open_bin hash_file In_channel.input_all |> String.trim
      in
      if String.equal hash "" then None else Some hash
    with Sys_error _ -> None
  else
    None

let internal_mcp_auth_json ~base_path =
  let env_key = Auth.internal_keeper_token_env_key in
  let env_token =
    match Sys.getenv_opt env_key with
    | Some raw ->
      let trimmed = String.trim raw in
      if String.equal trimmed "" then None else Some trimmed
    | None -> None
  in
  let env_token_present = Option.is_some env_token in
  let token_hash = internal_keeper_token_hash_opt ~base_path in
  let token_hash_file_present = Option.is_some token_hash in
  let env_token_verifies =
    match env_token, token_hash with
    | Some token, Some hash -> String.equal hash (Auth.sha256_hash token)
    | _ -> false
  in
  let ready = env_token_present && token_hash_file_present && env_token_verifies in
  let missing =
    [ (not env_token_present, "env_token")
    ; (not token_hash_file_present, "token_hash_file")
    ; ( env_token_present && token_hash_file_present && not env_token_verifies
      , "token_hash_mismatch" )
    ]
    |> List.filter_map (fun (missing, name) -> if missing then Some name else None)
  in
  let status = if ready then "ok" else "degraded" in
  let operator_next_action =
    if ready then "none" else "sync_internal_keeper_token_and_restart_runtime"
  in
  `Assoc
    [ "schema", `String "masc.internal_mcp_auth.v1"
    ; "status", `String status
    ; "source", `String "running_process_env_and_auth_hash"
    ; "env_key", `String env_key
    ; "env_token_present", `Bool env_token_present
    ; "token_hash_file_present", `Bool token_hash_file_present
    ; "env_token_verifies", `Bool env_token_verifies
    ; "keeper_internal_runtime_mcp_ready", `Bool ready
    ; "missing", `List (List.map (fun name -> `String name) missing)
    ; "operator_action_required", `Bool (not ready)
    ; "operator_next_action", `String operator_next_action
    ]

let otel_health_json () =
  let enabled = Otel_config.enabled in
  let degraded = Otel_spans.is_exporter_degraded () in
  let exporter_active = Otel_spans.is_exporter_active () in
  let status =
    if not enabled
    then "disabled"
    else if degraded
    then "degraded"
    else if exporter_active
    then "ok"
    else "inactive"
  in
  `Assoc
    [ "enabled", `Bool enabled
    ; "status", `String status
    ; "endpoint", `String Otel_config.endpoint
    ; "service_name", `String Otel_config.service_name
    ; "exporter_active", `Bool exporter_active
    ; "exporter_degraded", `Bool degraded
    ; "consecutive_failures", `Int (Otel_spans.consecutive_failures ())
    ; ( "last_successful_export_unix",
        Json_util.float_opt_to_json (Otel_spans.last_successful_export ()) )
    ; ( "last_degradation_error",
        Json_util.string_opt_to_json (Otel_spans.last_degradation_error ()) )
    ]
;;

let schedule_runner_status_json () =
  Server_schedule_runner_policy.status_json
    ~now:(Time_compat.now ())
    (Schedule_runner_status.snapshot ())
;;

let measure_health_phase timing phase f =
  match timing with
  | None -> f ()
  | Some timing -> Server_timing.measure timing phase f

(* The [protocol.listener] label of a health body: the ALPN identifier of the
   protocol the request came on. *)
let listener_of_protocol = function
  | Transport_metrics.H1 -> Server_tls_material.alpn_http1
  | Transport_metrics.H2 -> Server_tls_material.alpn_h2

let default_listener = listener_of_protocol Transport_metrics.H1

let make_health_probe_fields ?timing ?(listener = default_listener) ?full_health_url
    ?(health_detail = "probe") ~request_authority request =
  let uptime_secs = health_uptime_secs () in
  let build =
    measure_health_phase timing Server_timing.Health_build_identity Build_identity.current
  in
  let path_diagnostics =
    measure_health_phase timing Server_timing.Health_paths health_path_diagnostics
  in
  let full_health_url_fields =
    match full_health_url with
    | Some url -> [ ("full_health_url", `String url) ]
    | None -> []
  in
  [
      ("server", `String "masc");
      ("version", `String build.release_version);
      ("release_version", `String build.release_version);
      ("build", Build_identity.to_yojson build);
      ("health_detail", `String health_detail);
    ]
  @ full_health_url_fields
  @ [
      ("protocol", protocol_json ~listener);
      ("transport", transport_json ~request_authority request);
      ("http_listener", Transport_metrics.http_listener_json ());
      ("https_listener", Https_listener_metrics.json ());
      ("paths", Server_base_path_diagnostics.to_yojson path_diagnostics);
      ( "internal_mcp_auth"
      , measure_health_phase timing Server_timing.Health_internal_auth (fun () ->
          internal_mcp_auth_json ~base_path:path_diagnostics.effective_base_path) );
      ("otel", otel_health_json ());
      ("uptime", `String (health_uptime_string uptime_secs));
      ("sse_clients", `Int (Sse.client_count ()));
      ("startup", Server_startup_state.to_yojson ());
      ("schedule_runner", schedule_runner_status_json ());
      ("runtime_startup_degradation",
       Runtime.startup_degradation_to_yojson
         ~exact_slots:(Runtime.exact_slot_degradation ())
         ~exact_registry_stale:(Runtime.exact_output_registry_stale ())
         (Runtime.startup_degradation ()));
      ("dashboard_surface",
       measure_health_phase timing Server_timing.Health_dashboard_surface
         Web_dashboard.surface_status_json);
      ("subsystems", Subsystem_health.to_yojson ());
      ("logs", Log.Ring.summary_json ());
      ("gc", quick_gc_json ());
      ("process_memory", process_memory_json ());
      ("scheduler", scheduler_json ());
    ]

let make_health_probe_json ?timing ?(listener = default_listener) ?(extra_fields = [])
    ~request_authority request =
  Tool_args.ok_assoc
    (make_health_probe_fields ?timing ~listener ~health_detail:"probe"
       ~full_health_url:Server_health_paths.full ~request_authority request
     @ [ "auxiliary_startup",
         Server_auxiliary_startup.to_yojson Server_auxiliary_startup.global;
         "tla_source_observation", Server_tla_source_events.health_json () ]
     @ extra_fields)

(* Keeper fleet scan / paused-keeper diagnostics / phase counts / fleet safety
   extracted to [Server_routes_http_runtime_fleet_scan] (godfile decomp). *)
include Server_routes_http_runtime_fleet_scan
(* Fleet-level health field helpers extracted to
   [Server_routes_http_runtime_health_fleet] (godfile decomp). *)
include Server_routes_http_runtime_health_fleet

let full_health_component_placeholder ?error ?(component_timed_out = false) ~status
    component =
  let error_fields =
    match error with
    | Some error -> [("error", `String error)]
    | None -> []
  in
  `Assoc
    ([
       ("component", `String component);
       ("status", `String status);
       ("component_timed_out", `Bool component_timed_out);
     ]
     @ error_fields)

let compute_section ~name ?section_timings_ref f =
  let started = Unix.gettimeofday () in
  try
    let result = f () in
    let elapsed_ms = max 0 (int_of_float ((Unix.gettimeofday () -. started) *. 1000.)) in
    (match section_timings_ref with
     | Some ref -> ref := (name, elapsed_ms) :: !ref
     | None -> ());
    result
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      let elapsed_ms = max 0 (int_of_float ((Unix.gettimeofday () -. started) *. 1000.)) in
      (match section_timings_ref with
       | Some ref -> ref := (name, elapsed_ms) :: !ref
       | None -> ());
      let error = Printexc.to_string exn in
      full_health_component_placeholder
        ~error
        ~component_timed_out:false
        ~status:"error"
        name

let make_health_json ?(listener = default_listener) ?section_timings_ref
    ~request_authority request =
  let uptime_secs = health_uptime_secs () in
  let build = Build_identity.current () in
  let keeper_config_errors, keeper_config_probe_error =
    match Keeper_types_profile.keeper_toml_config_errors_result () with
    | Ok errors -> errors, None
    | Error error -> [], Some error
  in
  let keeper_config_unknown_keys =
    match keeper_config_probe_error with
    | Some _ -> []
    | None -> Keeper_types_profile.keeper_toml_unknown_keys ()
  in
  let keeper_config_unknown_key_count =
    List.fold_left
      (fun acc (entry : Keeper_types_profile.keeper_toml_unknown_keys) ->
        acc + List.length entry.unknown_keys)
      0
      keeper_config_unknown_keys
  in
  let keeper_config_error_count = List.length keeper_config_errors in
  let keeper_config_schema_blocking =
    keeper_config_error_count > 0
    || Option.is_some keeper_config_probe_error
    || keeper_config_unknown_key_count > 0
  in
  let keeper_config_schema_terminal_reason =
    if keeper_config_error_count > 0 then "config_invalid"
    else if Option.is_some keeper_config_probe_error then "config_probe_failed"
    else if keeper_config_unknown_key_count > 0 then "config_unknown_keys"
    else "none"
  in
  let key_paused_keepers = "paused_keepers" in
  let path_diagnostics = health_path_diagnostics () in
  let base_path = runtime_base_path_opt () in
  let phase_snapshot = keeper_phase_snapshot ?base_path () in
  let phase_counts = phase_snapshot.counts in
  let keeper_fibers = phase_counts.running in
  let server_state = current_server_state_opt () in
  let keeper_identity_drift_json =
    compute_section ~name:"keeper_identity_drift" ?section_timings_ref
      (fun () ->
        match server_state with
        | Some state ->
          keeper_identity_drift_health_json (Mcp_server.workspace_config state)
        | None ->
          `Assoc
            [
              ("schema", `String "masc.keeper_identity_drift.v1");
              ("status", `String "snapshot_not_ready");
              ("blocking", `Bool false);
              ("terminal_reason", `String "snapshot_not_ready");
              ("operator_action_required", `Bool false);
              ("configured_keeper_count", `Int 0);
              ("configured_keeper_names", `List []);
              ("materializable_configured_keeper_count", `Int 0);
              ("materializable_configured_keeper_names", `List []);
              ("persisted_meta_names", `List []);
              ("configured_without_meta_count", `Int 0);
              ("configured_without_meta_names", `List []);
              ("meta_without_config_count", `Int 0);
              ("meta_without_config_names", `List []);
              ("next_action", `String "none");
            ])
  in
  let publication_recovery_activation_json =
    compute_section
      ~name:"publication_recovery_activation"
      ?section_timings_ref
      (fun () ->
        match server_state with
        | None ->
          `Assoc
            [ "status", `String "unavailable"
            ; "operator_action_required", `Bool false
            ; "reason", `String "server_state_not_ready"
            ]
        | Some state ->
          let workspace_scope = Mcp_server.workspace_scope state in
          workspace_scope
          |> Mcp_server.workspace_scope_publication_recovery_snapshot
          |> Mcp_server.publication_recovery_snapshot_to_health_yojson)
  in
  let keeper_owner_json =
    compute_section ~name:"keeper_owner" ?section_timings_ref
      keeper_owner_health_json
  in
  let board_event_collection_json =
    compute_section ~name:"keeper_board_event_collection" ?section_timings_ref
      keeper_board_event_collection_health_json
  in
  let keeper_hitl_gate_json =
    compute_section ~name:"keeper_hitl_gate" ?section_timings_ref
      keeper_hitl_gate_health_json
  in
  (* One read of each keeper meta file, shared by the paused-keepers,
     execution and fleet-safety sections. It is taken right before the
     event-queue section, which discovers the queue-holding Keepers again:
     the owner set and that discovery stay adjacent. The paused and autoboot
     answers are therefore read after the owner and board-event sections
     above; a meta change in between shows in these sections and not in
     those, for one response. The reaction-ledger projection below shares
     this execution snapshot after the adjacent event-queue read. *)
  let fleet_reading =
    Option.map
      (fun state ->
        let reading = read_keeper_metas (Mcp_server.workspace_config state) in
        reading, keeper_fleet_meta_scan reading)
      server_state
  in
  let meta_reading = Option.map fst fleet_reading in
  let paused_scan, bootable_names, autoboot_scan =
    match fleet_reading with
    | Some (_, scan) -> scan.paused_scan, scan.bootable_names, scan.autoboot_scan
    | None -> empty_paused_keeper_scan, [], empty_autoboot_keeper_scan
  in
  let paused_keepers_json =
    compute_section ~name:"paused_keepers" ?section_timings_ref
      (fun () ->
        paused_keepers_health_json_of_scan
          ~registry_paused_names:(registry_paused_keeper_names ())
          paused_scan)
  in
  let execution_snapshot =
    match meta_reading with
    | Some reading -> keeper_execution_snapshot reading
    | None -> empty_keeper_execution_snapshot
  in
  let keeper_event_queue_json =
    compute_section ~name:"keeper_event_queue" ?section_timings_ref
      (fun () ->
        keeper_event_queue_health_json ~execution_snapshot ())
  in
  let reaction_ledger_json =
    compute_section ~name:"keeper_reaction_ledger" ?section_timings_ref
      (fun () -> keeper_reaction_ledger_health_json ~execution_snapshot ())
  in
  let keeper_waiting_inventory_json =
    compute_section ~name:"keeper_waiting_inventory" ?section_timings_ref
      (fun () ->
        match server_state with
        | Some state ->
          Server_keeper_waiting_inventory.health_json
            (Mcp_server.workspace_config state)
        | None ->
          Server_keeper_waiting_inventory.health_placeholder ~status:Health_status.Unavailable)
  in
  let typesafeai_json =
    compute_section ~name:"typesafeai" ?section_timings_ref Server_typesafeai_health.health_json
  in
  let fd_accountant_json =
    compute_section ~name:"fd_accountant" ?section_timings_ref fd_accountant_snapshot_json
  in
  let provider_connection_cache_json =
    compute_section ~name:"provider_connection_cache" ?section_timings_ref
      provider_connection_cache_json
  in
  let disk_observation_json =
    compute_section ~name:"disk_observation" ?section_timings_ref (fun () ->
      Keeper_disk_pressure.snapshot_json
        ~masc_root:path_diagnostics.effective_masc_root
        ())
  in
  let keeper_fleet_safety =
    compute_section ~name:"keeper_fleet_safety" ?section_timings_ref
      (fun () ->
        keeper_fleet_safety_health_json
          ~meta_reading
          ~bootable_names
          ~autoboot_scan
          ~phase_snapshot
          ~execution_snapshot
          ?base_path
          ~phase_counts
          ~paused_keepers_json
          ())
  in
  let skill_catalog_json =
    compute_section ~name:"skill_catalog" ?section_timings_ref (fun () ->
      match base_path with
      | Some base_path ->
        Server_skill_catalog_health.to_yojson
          (Server_skill_snapshot_runtime.lookup ~base_path)
      | None ->
        Server_skill_catalog_health.placeholder ~component_timed_out:false
          ~status:"snapshot_not_ready" ())
  in
  let runtime_startup_degradation_json =
    Runtime.startup_degradation_to_yojson
         ~exact_slots:(Runtime.exact_slot_degradation ())
         ~exact_registry_stale:(Runtime.exact_output_registry_stale ())
         (Runtime.startup_degradation ())
  in
  let memory_execution_json =
    compute_section ~name:"keeper_memory_execution" ?section_timings_ref (fun () ->
      match server_state with
      | None -> `Assoc ["status",`String "snapshot_not_ready";
          "operator_action_required",`Bool false]
      | Some state ->
        Keeper_memory_execution_availability.snapshot
          ~config:(Mcp_server.workspace_config state) ~mode:`Live
        |> Keeper_memory_execution_availability.to_json)
  in
  let keeper_config_operator_action_required = keeper_config_schema_blocking in
  let memory_attention_json =
    compute_section ~name:"keeper_memory_attention" ?section_timings_ref (fun () ->
      match server_state with
      | None -> `Assoc ["status", `String "snapshot_not_ready";
          "operator_action_required", `Bool false]
      | Some state -> Keeper_librarian_queue_refresh.attention_health_json
          ~config:(Mcp_server.workspace_config state))
  in
  (* The sections come first and the rollup reads them, rather than the rollup
     being handed the eight it used to name. The rollup fields are
     appended after, so the payload's key order is unchanged. *)
  let sections = [
    ("server", `String "masc");
    ("version", `String build.release_version);
    ("release_version", `String build.release_version);
    ("build", Build_identity.to_yojson build);
    ("health_detail", `String "full");
    ("protocol", protocol_json ~listener);
    ("transport", transport_json ~request_authority request);
    ("http_listener", Transport_metrics.http_listener_json ());
    ("https_listener", Https_listener_metrics.json ());
    ("paths", Server_base_path_diagnostics.to_yojson path_diagnostics);
    ( "internal_mcp_auth"
    , internal_mcp_auth_json ~base_path:path_diagnostics.effective_base_path );
    ("otel", otel_health_json ());
    ( "runtime_truth"
    , runtime_truth_json ~build ~path_diagnostics ~keeper_fibers
        ~fd_accountant:fd_accountant_json );
    ("uptime", `String (health_uptime_string uptime_secs));
    ("sse_clients", `Int (Sse.client_count ()));
    ("startup", Server_startup_state.to_yojson ());
    ("runtime_startup_degradation", runtime_startup_degradation_json);
    ("dashboard_surface", Web_dashboard.surface_status_json ());
    ("subsystems", Subsystem_health.to_yojson ());
    ("auxiliary_startup", Server_auxiliary_startup.to_yojson Server_auxiliary_startup.global);
    ("tla_source_observation", Server_tla_source_events.health_json ());
    (* Server log visibility belongs on the first health probe too.  Keep the
       payload cheap and redacted: only ring counters, latest metadata, and
       file-sink state are exposed here; full log rows stay behind the
       dashboard logs API. *)
    ("logs", Log.Ring.summary_json ());
    ("gc", quick_gc_json ());
    ("process_memory", process_memory_json ());
    ("scheduler", scheduler_json ());
    ("keeper_fibers", `Int keeper_fibers);
    ( "fd_observation"
    , Keeper_fd_pressure.runtime_state_json ~active_keepers:keeper_fibers
        () );
    ("fd_accountant", fd_accountant_json);
    ("provider_connection_cache", provider_connection_cache_json);
    ("disk_observation", disk_observation_json);
    ("server_hibernation", Server_hibernation.status_json ());
    ("keeper_fleet_safety", keeper_fleet_safety);
    ("keeper_identity_drift", keeper_identity_drift_json);
    ("keeper_memory_execution", memory_execution_json);
    ("keeper_memory_attention", memory_attention_json);
    ("publication_recovery_activation", publication_recovery_activation_json);
    ("keeper_reaction_ledger", reaction_ledger_json);
    ("keeper_owner", keeper_owner_json);
    ("keeper_board_event_collection", board_event_collection_json);
    ("keeper_hitl_gate", keeper_hitl_gate_json);
    ("keeper_event_queue", keeper_event_queue_json);
    ("keeper_waiting_inventory", keeper_waiting_inventory_json);
    ("typesafeai", typesafeai_json);
    ( "keeper_terminal_effect_policy"
    , Keeper_terminal_effect_policy.matrix_to_yojson () );
    ( "keeper_observability_artifacts"
    , Keeper_observability_artifact_registry.to_yojson () );
    ("skill_catalog", skill_catalog_json);
    (* Paused-keeper visibility: a keeper with [meta.paused = true] does not
       run turns and may no longer have a live registry entry. Operators still
       need a durable count and the typed pause cause. *)
    (key_paused_keepers, paused_keepers_json);
    ("keeper_config_error_count",
     `Int keeper_config_error_count);
    ( "keeper_config_errors",
      `List
        (List.map Keeper_types_profile.keeper_toml_config_error_to_json
           keeper_config_errors) );
    ( "keeper_config_probe_error",
      Json_util.option_to_yojson
        Keeper_types_profile.keeper_config_probe_error_to_json
        keeper_config_probe_error );
    ( "keeper_config_unknown_key_count",
      `Int keeper_config_unknown_key_count );
    ( "keeper_config_unknown_keys",
      `List
        (List.map Keeper_types_profile.keeper_toml_unknown_keys_to_json
           keeper_config_unknown_keys) );
    ( "keeper_config_schema_status",
      `String (if keeper_config_schema_blocking then "blocked" else "ok") );
    ( "keeper_config_schema_blocking",
      `Bool keeper_config_schema_blocking );
    ( "keeper_config_schema_terminal_reason",
      `String keeper_config_schema_terminal_reason );
    ( "keeper_config_operator_action_required",
      `Bool keeper_config_operator_action_required );

  ]
  in
  let rollup =
    Server_health_rollup.operator_summary
      ~sections
      ~runtime_startup_degradation:runtime_startup_degradation_json
      ~keeper_config_schema_status:
        (if keeper_config_schema_blocking then "blocked" else "ok")
      ~keeper_config_schema_blocking
      ~keeper_config_schema_terminal_reason
      ~keeper_config_operator_action_required
  in
  let string_list reasons = `List (List.map (fun reason -> `String reason) reasons) in
  Tool_args.ok_assoc
    (sections
     @ [
         ("overall_status", `String rollup.Server_health_rollup.overall_status);
         ( "operator_action_required",
           `Bool rollup.Server_health_rollup.operator_action_required );
         ( "operator_action_reasons",
           string_list rollup.Server_health_rollup.operator_action_reasons );
         ( "operator_actions",
           `List (List.map Operator_action_reason.to_json rollup.Server_health_rollup.operator_actions) );
         ( "overall_status_reasons",
           string_list rollup.Server_health_rollup.overall_status_reasons );
       ])

module Health_observation = Server_full_health_observation

module Health_refresh = Server_full_health_refresh_state

type full_health_completion =
  { promise : unit Eio.Promise.or_exn
  ; admitted_epoch : Mcp_server.Workspace_scope_epoch.t option
  ; started_epoch : Mcp_server.Workspace_scope_epoch.t option option Atomic.t
  ; mutable fleet_failure_epoch : Mcp_server.Workspace_scope_epoch.t option
  ; mutable health_failure_epoch : Mcp_server.Workspace_scope_epoch.t option option
  ; mutable last_failure :
      (Mcp_server.Workspace_scope_epoch.t option * float * Proactive_refresh.failure) option
  ; mutable waiting_scope : (Mcp_server.Workspace_scope_epoch.t * Fleet_stream_hub.t) option
  }

let full_health_failure_epoch completion =
  match Atomic.get completion.started_epoch with
  | Some epoch -> epoch
  | None -> completion.admitted_epoch

type full_health_state_view =
  { observation : Health_observation.t
  ; refresh : full_health_completion Health_refresh.t
  }

let full_health_snapshot_mu = Stdlib.Mutex.create ()
let full_health_observation = ref Health_observation.empty
let full_health_refresh : full_health_completion Health_refresh.t ref =
  ref Health_refresh.empty
(* Capacity-1 mailbox, not a queue: the refresh state lives in
   [full_health_refresh.requested] and this stream only carries "something
   changed". A second pending wakeup would tell the consumer nothing the
   first one did not, so extra ones are coalesced away rather than buffered.
   [max_int] here was an unbounded stream on the invalidation path -- the
   shape that exhausted the heap in #10777 when its consumer fiber stalled. *)
let full_health_refresh_wakeup = Eio.Stream.create 1

(* Every producer takes this short, non-yielding lock around the empty check
   and add. The stream has capacity one and only this function writes it, so
   add cannot wait for space. A standard mutex also admits invalidations from
   outside an Eio fiber without waiting for the periodic refresh. *)
let full_health_refresh_wakeup_mu = Stdlib.Mutex.create ()

let signal_full_health_refresh_wakeup () =
  Stdlib.Mutex.protect full_health_refresh_wakeup_mu (fun () ->
      if Eio.Stream.is_empty full_health_refresh_wakeup
      then Eio.Stream.add full_health_refresh_wakeup ())
;;
let full_health_refresh_timeout_sec =
  Env_config_runtime.Dashboard.full_health_refresh_timeout_sec
;;

let full_health_critical_failure_threshold =
  Env_config_runtime.Dashboard.full_health_critical_failure_threshold
;;

let full_health_refresh_interval_sec =
  Float.max 30.0 (full_health_refresh_timeout_sec +. 5.0)
;;

let full_health_snapshot_ttl_sec =
  Float.max 60.0 (full_health_refresh_interval_sec *. 2.0)
;;

let full_health_refresh_wakeup_coalesce_sec = 0.1

let with_full_health_snapshot_lock f =
  Stdlib.Mutex.protect full_health_snapshot_mu f

let full_health_placeholder_fields ?error ?(component_timed_out = false)
    ?(status = "warming") () =
  [
    ("overall_status", `String status);
    ("operator_action_required", `Bool false);
    ("operator_action_reasons", `List []);
    ("operator_actions", `Null);
    ("overall_status_reasons", `List []);
    ("keeper_fibers", `Int 0);
    ( "fd_observation",
      full_health_component_placeholder ?error ~component_timed_out ~status
        "fd_observation" );
    ( "fd_accountant",
      full_health_component_placeholder ?error ~component_timed_out ~status
        "fd_accountant" );
    ( "provider_connection_cache",
      full_health_component_placeholder ?error ~component_timed_out ~status
        "provider_connection_cache" );
    ( "disk_observation",
      full_health_component_placeholder ?error ~component_timed_out ~status
        "disk_observation" );
    ( "keeper_fleet_safety",
      full_health_component_placeholder ?error ~component_timed_out ~status
        "keeper_fleet_safety" );
    ( "keeper_identity_drift",
      `Assoc
        [
          ("schema", `String "masc.keeper_identity_drift.v1");
          ("status", `String status);
          ("blocking", `Bool false);
          ("terminal_reason", `String "snapshot_not_ready");
          ("operator_action_required", `Bool false);
          ("configured_keeper_count", `Int 0);
          ("configured_keeper_names", `List []);
          ("materializable_configured_keeper_count", `Int 0);
          ("materializable_configured_keeper_names", `List []);
          ("persisted_meta_names", `List []);
          ("configured_without_meta_count", `Int 0);
          ("configured_without_meta_names", `List []);
          ("meta_without_config_count", `Int 0);
          ("meta_without_config_names", `List []);
          ("next_action", `String "none");
          ("component_timed_out", `Bool component_timed_out);
        ] );
    ( "publication_recovery_activation",
      full_health_component_placeholder
        ?error
        ~component_timed_out
        ~status
        "publication_recovery_activation" );
    ( "keeper_reaction_ledger",
      full_health_component_placeholder ?error ~component_timed_out ~status
        "keeper_reaction_ledger" );
    ( "keeper_memory_execution",
      full_health_component_placeholder ~component_timed_out ~status
        "keeper_memory_execution" );
    ( "keeper_memory_attention",
      full_health_component_placeholder ?error ~component_timed_out ~status
        "keeper_memory_attention" );
    ( "keeper_owner",
      full_health_component_placeholder ?error ~component_timed_out ~status
        "keeper_owner" );
    ( "keeper_board_event_collection",
      full_health_component_placeholder ?error ~component_timed_out ~status
        "keeper_board_event_collection" );
    ( "keeper_hitl_gate",
      full_health_component_placeholder ?error ~component_timed_out ~status
        "keeper_hitl_gate" );
    ( "keeper_event_queue",
      `Assoc
        [ ("schema", `String Keeper_event_queue_schema.fleet_health_summary)
        ; ("queue_residence", Keeper_event_queue_persistence.(queue_residence_to_yojson
              (Unknown Queue_observation_incomplete)))
        ; ("status", `String status)
        ; ("operator_action_required", `Bool false)
        ; ("status_reasons", `List [])
        ; ("operator_action_reasons", `List [])
        ; ("backlog_clean", `Bool false)
        ; ( "storage_integrity"
          , `Assoc
              [ ( "schema"
                , `String "masc.keeper_event_queue.storage_integrity.v1" )
              ; ("status", `String status)
              ; ("counts_complete", `Bool false)
              ; ("read_error_count", `Int 0)
              ; ("transition_outbox_count", `Int 0)
              ; ("operator_action_required", `Bool false)
              ] )
        ; ( "work_liveness"
          , `Assoc
              [ ("schema", `String "masc.keeper_event_queue.work_liveness.v2")
              ; ("status", `String status)
              ; ("state", `String "unknown")
              ; ("runnable_backlog_count", `Int 0)
              ; ("runnable_oldest_source_age_seconds", `Null)
              ; ( "queue_residence"
                , Keeper_event_queue_persistence.(queue_residence_to_yojson
                    (Unknown Queue_observation_incomplete)) )
              ; ("operator_action_required", `Bool false)
              ] )
        ; ("keeper_count", `Int 0)
        ; ("keeper_names", `List [])
        ; ("pending_count", `Int 0)
        ; ("total_count", `Int 0)
        ; ("oldest_source_arrived_at_unix", `Null)
        ; ("oldest_source_age_seconds", `Null)
        ; ("runnable_backlog_count", `Int 0)
        ; ("runnable_oldest_source_arrived_at_unix", `Null)
        ; ("runnable_oldest_source_age_seconds", `Null)
        ; ("runnable_by_keeper", `List [])
        ; ("recoverable_backlog_count", `Int 0)
        ; ("recoverable_oldest_source_arrived_at_unix", `Null)
        ; ("recoverable_oldest_source_age_seconds", `Null)
        ; ("recoverable_by_keeper", `List [])
        ; ("retained_disabled_backlog_count", `Int 0)
        ; ("retained_disabled_oldest_source_arrived_at_unix", `Null)
        ; ("retained_disabled_oldest_source_age_seconds", `Null)
        ; ("retained_disabled_by_keeper", `List [])
        ; ("paused_dead_backlog_count", `Int 0)
        ; ("paused_dead_oldest_source_arrived_at_unix", `Null)
        ; ("paused_dead_oldest_source_age_seconds", `Null)
        ; ("paused_dead_by_keeper", `List [])
        ; ("shutdown_fenced_backlog_count", `Int 0)
        ; ("shutdown_fenced_oldest_source_arrived_at_unix", `Null)
        ; ("shutdown_fenced_oldest_source_age_seconds", `Null)
        ; ("shutdown_fenced_by_keeper", `List [])
        ; ("unclassified_count", `Int 0)
        ; ("unclassified_oldest_source_arrived_at_unix", `Null)
        ; ("unclassified_oldest_source_age_seconds", `Null)
        ; ("unclassified_by_keeper", `List [])
        ; ("pending_by_keeper", `List [])
        ; ("read_error_count", `Int 0)
        ; ("read_errors", `List [])
        ; ("keepers", `List [])
        ; ("component_timed_out", `Bool component_timed_out)
        ] );
    ( "keeper_waiting_inventory",
      Server_keeper_waiting_inventory.health_placeholder
        ~status:(Health_status.of_string status) );
    ( "typesafeai",
      Server_typesafeai_health.health_placeholder
        ~status:(Health_status.of_string status) );
    ( "keeper_terminal_effect_policy"
    , Keeper_terminal_effect_policy.matrix_to_yojson () );
    ( "keeper_observability_artifacts"
    , Keeper_observability_artifact_registry.to_yojson () );
    ( "skill_catalog",
      Server_skill_catalog_health.placeholder ?error ~component_timed_out
        ~status () );
    ( "auxiliary_startup",
      Server_auxiliary_startup.to_yojson Server_auxiliary_startup.global );
    ( "tla_source_observation", Server_tla_source_events.health_json () );
    ( "paused_keepers",
      `Assoc
        [
          ("status", `String status);
          ("count", `Int 0);
          ("names", `List []);
          ("component_timed_out", `Bool component_timed_out);
        ] );
    ("keeper_config_error_count", `Int 0);
    ("keeper_config_errors", `List []);
    ("keeper_config_probe_error", `Null);
    ("keeper_config_unknown_key_count", `Int 0);
    ("keeper_config_unknown_keys", `List []);
    ("keeper_config_schema_status", `String status);
    ("keeper_config_schema_blocking", `Bool false);
    ("keeper_config_schema_terminal_reason", `String "snapshot_not_ready");
    ("keeper_config_operator_action_required", `Bool false);
  ]

let cached_full_health_fields = function
  | `Assoc fields ->
      let cached =
        List.filter (fun (name, _) -> Server_health_rollup.is_cached name) fields
      in
      let has_cached name =
        List.exists (fun (cached_name, _) -> String.equal cached_name name) cached
      in
      let missing_placeholders =
        full_health_placeholder_fields ~status:"unavailable" ()
        |> List.filter (fun (name, _) ->
            Server_health_rollup.is_cached name && not (has_cached name))
      in
      cached @ missing_placeholders
  | json ->
      [
        ( "full_health_payload",
          `Assoc
            [
              ("status", `String "unexpected_payload");
              ("payload", json);
            ] );
      ]

let duration_ms ~started_at ~finished_at =
  max 0 (int_of_float ((finished_at -. started_at) *. 1000.))

let current_workspace_epoch () =
  Option.map
    (fun state -> (Mcp_server.workspace_scope state).epoch)
    (current_server_state_opt ())

let unchanged_workspace_epoch before =
  if Health_observation.same_scope before (current_workspace_epoch ())
  then before, true
  else None, false

let compute_full_health_snapshot ?(listener = default_listener)
    ?(on_workspace_epoch = fun _ -> ()) ~request_authority
    request : Health_observation.snapshot =
  let workspace_epoch = current_workspace_epoch () in
  on_workspace_epoch workspace_epoch;
  let started_at = Unix.gettimeofday () in
  let section_timings_ref = ref [] in
  try
    let fields =
      cached_full_health_fields
        (make_health_json ~listener ~section_timings_ref ~request_authority request)
    in
    let finished_at = Unix.gettimeofday () in
    let workspace_epoch, scope_consistent = unchanged_workspace_epoch workspace_epoch in
    {
      workspace_epoch;
      scope_consistent;
      fields;
      computed_at = finished_at;
      duration_ms = duration_ms ~started_at ~finished_at;
      failure = None;
      stale_since_ts = None;
      last_good_available = true;
      section_timings = List.rev !section_timings_ref;
    }
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      let finished_at = Unix.gettimeofday () in
      let failure = Proactive_refresh.Raised exn in
      let error = Proactive_refresh.failure_message failure in
      let workspace_epoch, scope_consistent = unchanged_workspace_epoch workspace_epoch in
      {
        workspace_epoch;
        scope_consistent;
        fields = full_health_placeholder_fields ~error ~status:"error" ();
        computed_at = finished_at;
        duration_ms = duration_ms ~started_at ~finished_at;
        failure = Some failure;
        stale_since_ts = Some finished_at;
        last_good_available = false;
        section_timings = List.rev !section_timings_ref;
      }

(* A hub belongs to one workspace generation. Replacing a workspace, even
   with the same paths, must not give its new subscribers the previous
   generation's last reading. Old subscriptions keep their old hub until the
   route closes them on scope replacement. *)
let fleet_stream_hub_mu = Stdlib.Mutex.create ()
let fleet_stream_hub :
    (Mcp_server.Workspace_scope_epoch.t * Fleet_stream_hub.t) option ref = ref None

let select_fleet_stream_hub state epoch =
  Stdlib.Mutex.protect fleet_stream_hub_mu (fun () ->
    let current = Mcp_server.workspace_scope state in
    let is_server =
      match current_server_state_opt () with
      | Some active -> active == state
      | None -> false
    in
    if not is_server || not (Mcp_server.Workspace_scope_epoch.equal current.epoch epoch)
    then None
    else
      match !fleet_stream_hub with
      | Some (existing, hub) when Mcp_server.Workspace_scope_epoch.equal existing epoch ->
          Some (hub, false)
      | Some _ | None ->
          let hub = Fleet_stream_hub.create ~on_subscriber_error:(fun exn ->
            Log.Dashboard.warn "fleet stream subscriber failed and was removed: %s"
              (Printexc.to_string exn)) in
          fleet_stream_hub := Some (epoch, hub);
          Some (hub, true))

let with_fleet_stream_hub epoch f =
  match epoch, current_server_state_opt () with
  | Some epoch, Some state ->
      Option.iter (fun (hub, _) -> f hub) (select_fleet_stream_hub state epoch)
  | (None | Some _), (None | Some _) -> ()

(* A scan that produced a reading tells the hub. A fleet section that cannot be
   read is a fault in the server: it is logged, and the hub keeps the last
   reading it has. *)
let publish_fleet_stream_reading (snapshot : Health_observation.snapshot) =
  with_fleet_stream_hub snapshot.workspace_epoch (fun hub ->
    match Fleet_stream_health_section.fleet_of_health_fields snapshot.fields with
    | Ok fleet ->
        Fleet_stream_hub.observe hub ~measured_at:snapshot.computed_at fleet
    | Error (Fleet_stream_health_section.Not_measured _) -> ()
    | Error (Fleet_stream_health_section.Scan_failed reason) ->
        Fleet_stream_hub.note_degraded hub ~since:snapshot.computed_at reason
    | Error (Fleet_stream_health_section.Unreadable detail) ->
        Log.Dashboard.warn "fleet stream: the fleet section cannot be read: %s" detail;
        Fleet_stream_hub.note_degraded hub ~since:snapshot.computed_at
          Fleet_stream.Scan_failed)

let fleet_failure_reason = function
  | Proactive_refresh.Timed_out _ -> Fleet_stream.Scan_timed_out
  | Proactive_refresh.Raised _ -> Fleet_stream.Scan_failed

let note_fleet_stream_failure ~workspace_epoch ~since failure =
  let reason = fleet_failure_reason failure in
  with_fleet_stream_hub workspace_epoch (fun hub ->
    Fleet_stream_hub.note_degraded hub ~since reason)

(* A new scope can be waiting behind an old generation's shared worker. A
   timed-out or failed wait makes its first reading unavailable too, without
   asserting that its own scan ran. Do not replace a reading the new scope
   obtained independently while that worker was still settling. *)
let fleet_hub_is_current state epoch hub =
  Stdlib.Mutex.protect fleet_stream_hub_mu (fun () ->
    Option.exists (fun active -> active == state) (current_server_state_opt ())
    && Mcp_server.Workspace_scope_epoch.equal (Mcp_server.workspace_scope state).epoch epoch
    && match !fleet_stream_hub with
       | Some (current_epoch, current_hub) ->
           current_hub == hub && Mcp_server.Workspace_scope_epoch.equal epoch current_epoch
       | None -> false)

let note_waiting_scope_failure_if_unmeasured completion ~failed_epoch ~since failure =
  let waiting_hub =
    match completion.waiting_scope, current_server_state_opt () with
    | Some (epoch, hub), Some state
      when not (Option.exists (Mcp_server.Workspace_scope_epoch.equal epoch) failed_epoch)
           && fleet_hub_is_current state epoch hub -> Some hub
    | (None | Some _), (None | Some _) -> None
  in
  Option.iter (fun hub ->
    Fleet_stream_hub.note_unavailable_if_unmeasured hub
      ~since (fleet_failure_reason failure)) waiting_hub

(* Health failure accounting is once per worker, but a worker admitted in one
   scope can actually start in another. The latter scope still needs its own
   availability notification if the shared worker later fails there. Calls
   hold [full_health_snapshot_mu]. *)
let note_worker_fleet_failure_once completion ~workspace_epoch failure =
  match workspace_epoch with
  | None -> ()
  | Some epoch ->
      let already_reported =
        Option.exists (Mcp_server.Workspace_scope_epoch.equal epoch)
          completion.fleet_failure_epoch
      in
      if not already_reported then begin
        completion.fleet_failure_epoch <- Some epoch;
        note_fleet_stream_failure ~workspace_epoch ~since:(Unix.gettimeofday ()) failure
      end

let remember_worker_fleet_failure completion workspace_epoch =
  match workspace_epoch with
  | None -> ()
  | Some epoch -> completion.fleet_failure_epoch <- Some epoch

let store_successful_full_health_snapshot_locked snapshot ~refresh_requested =
  full_health_observation := Health_observation.publish snapshot !full_health_observation;
  full_health_refresh :=
    Health_refresh.complete ~refresh_requested !full_health_refresh;
  publish_fleet_stream_reading snapshot

let mark_full_health_snapshot_failure_locked ~workspace_epoch ~worker_active failure =
  let now = Unix.gettimeofday () in
  let error = Proactive_refresh.failure_message failure in
  let timed_out =
    match failure with
    | Proactive_refresh.Timed_out _ -> true
    | Proactive_refresh.Raised _ -> false
  in
  let same_workspace =
    Health_observation.same_scope workspace_epoch (current_workspace_epoch ())
  in
  let requested = (!full_health_refresh).requested in
  let critical_edge =
    if not same_workspace
    then false
    else
      let state = Health_observation.for_scope ~workspace_epoch !full_health_observation in
      let cold_fields =
        match state.snapshot with
        | Some snapshot -> snapshot.fields
        | None ->
          let status = if timed_out then "timeout" else "error" in
          full_health_placeholder_fields ~error ~component_timed_out:timed_out ~status ()
      in
      let state, critical_edge =
        Health_observation.fail ~workspace_epoch ~now ~failure ~cold_fields
          ~critical_threshold:full_health_critical_failure_threshold state
      in
      full_health_observation := state;
      critical_edge
  in
  full_health_refresh :=
    Health_refresh.note_failure ~worker_active !full_health_refresh;
  if not same_workspace && requested then
    full_health_refresh := Health_refresh.request !full_health_refresh;
  note_fleet_stream_failure ~workspace_epoch ~since:now failure;
  if critical_edge then
    Otel_metric_store.inc_counter
      "masc_full_health_refresh_critical_total"
      ~labels:[ "reason", "consecutive_failures" ]
      ()

(* A compute can return a failed observation without throwing. Route it
   through the failure transition before publishing, so sync refresh and the
   worker preserve the last measurement and consecutive-failure evidence. *)
let store_full_health_snapshot_locked (snapshot : Health_observation.snapshot) ~refresh_requested =
  if not snapshot.scope_consistent
     || not (Health_observation.same_scope snapshot.workspace_epoch (current_workspace_epoch ()))
  then
    let refresh_requested = refresh_requested || (!full_health_refresh).requested in
    full_health_refresh := Health_refresh.complete ~refresh_requested !full_health_refresh
  else match snapshot.failure with
  | None ->
      store_successful_full_health_snapshot_locked snapshot ~refresh_requested
  | Some failure ->
      mark_full_health_snapshot_failure_locked ~workspace_epoch:snapshot.workspace_epoch
        ~worker_active:false failure;
      full_health_refresh :=
        Health_refresh.complete ~refresh_requested !full_health_refresh

let store_full_health_snapshot snapshot =
  with_full_health_snapshot_lock (fun () ->
      store_full_health_snapshot_locked snapshot ~refresh_requested:false);
  Dashboard_observation_commit.process_written `Health

let mark_full_health_snapshot_failure failure =
  with_full_health_snapshot_lock (fun () ->
      mark_full_health_snapshot_failure_locked ~workspace_epoch:(current_workspace_epoch ())
        ~worker_active:false failure);
  Dashboard_observation_commit.process_written `Health

let mark_full_health_refresh_wait_failure failure =
  let changed = with_full_health_snapshot_lock (fun () ->
      let before = !full_health_observation in
      (match (!full_health_refresh).active_worker with
      | None -> ()
      | Some worker ->
        let workspace_epoch = full_health_failure_epoch worker.completion in
        let since = Unix.gettimeofday () in
        worker.completion.last_failure <- Some (workspace_epoch, since, failure);
        let already_reported =
          Option.exists (Health_observation.same_scope workspace_epoch)
            worker.completion.health_failure_epoch
        in
        if already_reported then
          note_worker_fleet_failure_once worker.completion ~workspace_epoch failure
        else begin
          mark_full_health_snapshot_failure_locked ~workspace_epoch ~worker_active:true failure;
          if Health_observation.same_scope workspace_epoch (current_workspace_epoch ()) then
            worker.completion.health_failure_epoch <- Some workspace_epoch;
          remember_worker_fleet_failure worker.completion workspace_epoch
        end;
        note_waiting_scope_failure_if_unmeasured worker.completion
          ~failed_epoch:workspace_epoch ~since failure);
      before != !full_health_observation)
  in
  if changed then Dashboard_observation_commit.process_written `Health

let compute_full_health_snapshot_for_refresh ?(listener = default_listener)
    ~request_authority request =
  let was_requested =
    with_full_health_snapshot_lock (fun () ->
        let prior_requested = (!full_health_refresh).requested in
        full_health_refresh :=
          Health_refresh.begin_direct ~now:(Unix.gettimeofday ()) !full_health_refresh;
        prior_requested)
  in
  try compute_full_health_snapshot ~listener ~request_authority request with
  | Eio.Cancel.Cancelled _ as exn ->
      with_full_health_snapshot_lock (fun () ->
          full_health_refresh :=
            Health_refresh.cancel_direct ~was_requested !full_health_refresh);
      raise exn

let refresh_full_health_snapshot_sync ?(listener = default_listener)
    ~request_authority request =
  compute_full_health_snapshot_for_refresh ~listener ~request_authority request
  |> store_full_health_snapshot

let finish_full_health_refresh_worker
    (worker : full_health_completion Health_refresh.worker)
    resolver
    (outcome : (Health_observation.snapshot, exn) result) =
  let settled, enqueue_follow_up =
    with_full_health_snapshot_lock (fun () ->
        match Health_refresh.take_worker ~id:worker.id !full_health_refresh with
        | Some (refresh, active) ->
            let dirty = match active.freshness with
              | Health_refresh.Current_generation -> false
              | Health_refresh.Invalidated_during_refresh _ -> true
            in
            full_health_refresh := refresh;
            let finish_failure ?(scope_consistent = true) ~workspace_epoch failure =
              let since = Unix.gettimeofday () in
              worker.completion.last_failure <- Some (workspace_epoch, since, failure);
              (* A wait failure counts once per workspace generation, not once
                 per worker: the worker can begin after its admitted scope was
                 replaced. A later failure in that new scope is its first. *)
              let same_workspace =
                Health_observation.same_scope workspace_epoch (current_workspace_epoch ())
              in
              let preserve_request () =
                (not scope_consistent || not same_workspace)
                && (!full_health_refresh).requested
              in
              let already_reported =
                Option.exists (Health_observation.same_scope workspace_epoch)
                  worker.completion.health_failure_epoch
              in
              if not scope_consistent then
                full_health_refresh :=
                  Health_refresh.complete ~refresh_requested:(preserve_request ()) !full_health_refresh
              else if already_reported then
                (full_health_refresh :=
                   Health_refresh.complete ~refresh_requested:(preserve_request ()) !full_health_refresh;
                 note_worker_fleet_failure_once worker.completion ~workspace_epoch failure)
              else (
                mark_full_health_snapshot_failure_locked
                  ~workspace_epoch
                  ~worker_active:false failure;
                if same_workspace then
                  worker.completion.health_failure_epoch <- Some workspace_epoch;
                remember_worker_fleet_failure worker.completion workspace_epoch);
              note_waiting_scope_failure_if_unmeasured worker.completion
                ~failed_epoch:workspace_epoch ~since failure;
              if dirty then
                full_health_refresh := Health_refresh.request !full_health_refresh
            in
            (match outcome with
             | Ok snapshot ->
                 (match snapshot.failure, active.freshness with
                  | Some failure, _ ->
                      finish_failure ~scope_consistent:snapshot.scope_consistent
                        ~workspace_epoch:snapshot.workspace_epoch failure
                  | None, Health_refresh.Current_generation ->
                      store_full_health_snapshot_locked snapshot
                        ~refresh_requested:false
                  | None, Health_refresh.Invalidated_during_refresh since ->
                      (* Retain a measured scan even when mutations prevent it
                         from certifying freshness. Without this, a busy cold
                         runtime can discard every successful observation.
                         Only a current scan ends the continuous stale period. *)
                      if snapshot.scope_consistent && Health_observation.same_scope snapshot.workspace_epoch
                           (current_workspace_epoch ())
                      then begin
                        let state =
                          Health_observation.publish_dirty ~since snapshot
                            !full_health_observation
                        in
                        full_health_observation := state;
                        Option.iter publish_fleet_stream_reading state.snapshot
                      end;
                      full_health_refresh :=
                        Health_refresh.complete ~refresh_requested:true !full_health_refresh)
             | Error exn ->
                 finish_failure
                   ~workspace_epoch:(full_health_failure_epoch worker.completion)
                   (Proactive_refresh.Raised exn));
            true, dirty || (!full_health_refresh).requested
        | None -> false, false)
  in
  if settled then begin
    Dashboard_observation_commit.process_written `Health;
    Eio.Promise.resolve resolver
      (match outcome with
       | Ok _ -> Ok ()
       | Error exn -> Error exn);
    if enqueue_follow_up then begin
      Log.Dashboard.debug
        "full_health_snapshot requests a successor after worker %d was invalidated"
        worker.id;
      signal_full_health_refresh_wakeup ()
    end
  end

let cancel_full_health_refresh_worker
    (worker : full_health_completion Health_refresh.worker)
    resolver
    exn =
  let settled, enqueue_follow_up =
    with_full_health_snapshot_lock (fun () ->
        match Health_refresh.cancel_worker ~id:worker.id !full_health_refresh with
        | Some (refresh, dirty) ->
            full_health_refresh := refresh;
            true, dirty
        | None -> false, false)
  in
  if settled then begin
    Eio.Promise.resolve_error resolver exn;
    if enqueue_follow_up then begin
      Log.Dashboard.debug
        "full_health_snapshot requests a successor after cancelled worker %d was invalidated"
        worker.id;
      match Fs_compat.execution_context () with
      | Fs_compat.Eio_fiber ->
          (try Eio.Cancel.protect signal_full_health_refresh_wakeup
           with _ -> ())
      | Non_eio -> ()
    end
  end

let await_full_health_refresh_worker ~sw ~compute =
  Eio.Switch.check sw;
  let action =
    with_full_health_snapshot_lock (fun () ->
        Eio.Switch.check sw;
        match Health_refresh.admit !full_health_refresh with
        | Health_refresh.Join (refresh, worker) ->
            full_health_refresh := refresh;
            `Join worker
        | Health_refresh.Start plan ->
            let completion, resolver = Eio.Promise.create () in
            let completion =
              { promise = completion
              ; admitted_epoch = current_workspace_epoch ()
              ; started_epoch = Atomic.make None
              ; fleet_failure_epoch = None
              ; health_failure_epoch = None
              ; last_failure = None
              ; waiting_scope = None
              }
            in
            let refresh, worker =
              Health_refresh.start ~now:(Unix.gettimeofday ()) ~completion plan
            in
            full_health_refresh := refresh;
            `Start (worker, resolver))
  in
  let worker =
    match action with
    | `Join worker ->
        Log.Dashboard.debug
          "full_health_snapshot joined active worker %d"
          worker.id;
        worker
    | `Start (worker, resolver) ->
        (try
           Eio.Switch.check sw;
           let hook =
             Eio.Switch.on_release_cancellable sw (fun () ->
               let exn =
                 match Eio.Switch.get_error sw with
                 | Some exn -> exn
                 | None -> Eio.Cancel.Cancelled Exit
               in
               cancel_full_health_refresh_worker worker resolver exn)
           in
           (try
              Eio.Fiber.fork ~sw (fun () ->
                  Fun.protect ~finally:(fun () -> Eio.Switch.remove_hook hook)
                    (fun () ->
                      let outcome =
                        try
                          Ok (compute ~on_workspace_epoch:(fun epoch ->
                            Atomic.set worker.completion.started_epoch (Some epoch)))
                        with
                        | Eio.Cancel.Cancelled _ as exn ->
                            cancel_full_health_refresh_worker worker resolver exn;
                            raise exn
                        | exn -> Error exn
                      in
                      finish_full_health_refresh_worker worker resolver outcome));
              worker
            with exn ->
              Eio.Switch.remove_hook hook;
              raise exn)
         with exn ->
           cancel_full_health_refresh_worker worker resolver exn;
           raise exn)
  in
  Eio.Promise.await_exn worker.completion.promise

let snapshot_is_stale ~now (snapshot : Health_observation.snapshot) =
  Option.is_some snapshot.stale_since_ts
  || now -. snapshot.computed_at > full_health_snapshot_ttl_sec

let full_health_snapshot_stale_reason ~now (snapshot : Health_observation.snapshot option) =
  match snapshot with
  | None -> None
  | Some snapshot ->
      (match snapshot.failure with
       | Some (Proactive_refresh.Timed_out _) when snapshot.last_good_available ->
           Some "last_good_refresh_timeout"
       | Some (Proactive_refresh.Raised _) when snapshot.last_good_available ->
           Some "last_good_refresh_error"
       | Some (Proactive_refresh.Timed_out _) -> Some "refresh_timeout"
       | Some (Proactive_refresh.Raised _) -> Some "refresh_error"
       | None when Option.is_some snapshot.stale_since_ts -> Some "invalidated"
       | None when snapshot_is_stale ~now snapshot -> Some "ttl_expired"
       | None -> None)

let full_health_snapshot_stale_age_ms ~now (snapshot : Health_observation.snapshot option) =
  let stale_started_at =
    match snapshot with
    | None -> None
    | Some snapshot ->
        (match snapshot.stale_since_ts with
         | Some ts -> Some ts
         | None when snapshot_is_stale ~now snapshot ->
             Some (snapshot.computed_at +. full_health_snapshot_ttl_sec)
         | None -> None)
  in
  match stale_started_at with
  | None -> `Null
  | Some started_at ->
      `Int (max 0 (int_of_float ((now -. started_at) *. 1000.)))

let full_health_snapshot_metadata ~now (view : full_health_state_view) =
  let snapshot = view.observation.snapshot in
  let refresh = view.refresh in
  let refresh_in_flight, refresh_started_at =
    match refresh.flight with
    | Health_refresh.Idle -> false, None
    | Health_refresh.In_flight started_at -> true, started_at
  in
  let refresh_requested = refresh.requested in
  let worker_active = Option.is_some refresh.active_worker in
  let worker_submissions = refresh.submissions in
  let worker_joins = refresh.joins in
  let invalidation_generation = refresh.invalidation_generation in
  let component_timed_out =
    match (refresh_in_flight, refresh_started_at) with
    | true, Some started_at ->
        now -. started_at > full_health_refresh_timeout_sec
    | _ ->
        (match snapshot with
         | Some { failure = Some (Proactive_refresh.Timed_out _); _ } -> true
         | Some { failure = Some (Proactive_refresh.Raised _);_} | Some { failure = None;_} | None -> false)
  in
  let snapshot_age_ms, computed_at, duration_ms, error, stale_since_ts, status =
    match snapshot with
    | None -> (`Null, `Null, `Null, `Null, `Null, "warming")
    | Some snapshot ->
        let status =
          match snapshot.failure with
          | Some (Proactive_refresh.Timed_out _ | Proactive_refresh.Raised _)
            when snapshot.last_good_available ->
            "stale"
          | Some (Proactive_refresh.Timed_out _) -> "timeout"
          | Some (Proactive_refresh.Raised _) -> "error"
          | None when snapshot_is_stale ~now snapshot -> "stale"
          | None -> "ready"
        in
        let stale_since_ts_json =
          match snapshot.stale_since_ts with
          | Some t -> `Float t
          | None -> `Null
        in
        ( `Int (duration_ms ~started_at:snapshot.computed_at ~finished_at:now),
          `Float snapshot.computed_at,
          `Int snapshot.duration_ms,
          (match snapshot.failure with
           | Some failure -> `String (Proactive_refresh.failure_message failure)
           | None -> `Null),
          stale_since_ts_json,
          status )
  in
  let stale_reason =
    Json_util.string_opt_to_json (full_health_snapshot_stale_reason ~now snapshot)
  in
  let stale_age_ms = full_health_snapshot_stale_age_ms ~now snapshot in
  let section_timings_json =
    match snapshot with
    | Some s ->
        `List
          (List.map
             (fun (name, ms) ->
               `Assoc [ ("name", `String name); ("ms", `Int ms) ])
             s.section_timings)
    | None -> `List []
  in
  `Assoc
    [
      ("status", `String status);
      ("snapshot_age_ms", snapshot_age_ms);
      ("stale_reason", stale_reason);
      ("stale_age_ms", stale_age_ms);
      ("computed_at_unix", computed_at);
      ("duration_ms", duration_ms);
      ("ttl_ms", `Int (int_of_float (full_health_snapshot_ttl_sec *. 1000.)));
      ("refresh_in_flight", `Bool refresh_in_flight);
      ("refresh_requested", `Bool refresh_requested);
      ("refresh_worker_active", `Bool worker_active);
      ("refresh_worker_submissions_total", `Int worker_submissions);
      ("refresh_worker_joins_total", `Int worker_joins);
      ("invalidation_generation", `Int invalidation_generation);
      ( "refresh_wakeup_coalesce_ms"
      , `Int (int_of_float (full_health_refresh_wakeup_coalesce_sec *. 1000.)) );
      ( "refresh_started_at_unix",
        match refresh_started_at with
        | Some started_at -> `Float started_at
        | None -> `Null );
      ( "refresh_timeout_ms",
        `Int (int_of_float (full_health_refresh_timeout_sec *. 1000.)) );
      ("component_timed_out", `Bool component_timed_out);
      ("error", error);
      ("last_good_available", `Bool (Option.fold ~none:false ~some:(fun (s : Health_observation.snapshot) -> s.last_good_available) snapshot));
      ("section_timings", section_timings_json);
      (* [stale_since_ts] is the wall-clock of the FIRST invalidation or failure of
         the current outage; null when the snapshot is fresh. It
         answers "how long has it been stale?". [computed_at_unix]
         answers "when was what is served measured?": a failure keeps
         the last good snapshot's [computed_at]
         ([mark_full_health_snapshot_failure_locked]), so under partial
         degradation it is the last good refresh's time, not the failed
         attempt's. *)
      ("stale_since_ts", stale_since_ts);
    ]

let mark_full_health_refresh_requested ~now () =
  let wake, refresh =
    with_full_health_snapshot_lock (fun () ->
      let epoch = current_workspace_epoch () in
      let refresh = !full_health_refresh in
      let worker_matches =
        Option.exists (fun (worker : full_health_completion Health_refresh.worker) ->
          Health_observation.same_scope epoch (full_health_failure_epoch worker.completion))
          refresh.active_worker
      in
      let foreign_worker = Option.is_some refresh.active_worker && not worker_matches in
      let foreign_snapshot =
        Option.exists (fun (snapshot : Health_observation.snapshot) ->
          not snapshot.scope_consistent
          || not (Health_observation.same_scope epoch snapshot.workspace_epoch))
          (!full_health_observation).snapshot
      in
      let expired_success =
        Option.exists (fun (snapshot : Health_observation.snapshot) ->
          Option.is_none snapshot.failure
          && Option.is_none snapshot.stale_since_ts
          && snapshot_is_stale ~now snapshot)
          (!full_health_observation).snapshot
      in
      let requested = Health_refresh.request refresh in
      full_health_refresh := requested;
      (not worker_matches
       && (foreign_worker || foreign_snapshot
           || expired_success
           || Option.is_none (!full_health_observation).snapshot)), requested)
  in
  if wake then signal_full_health_refresh_wakeup ();
  refresh

let invalidate_full_health_snapshot_locked () =
  let now = Unix.gettimeofday () in
  full_health_refresh := Health_refresh.invalidate ~now !full_health_refresh;
  full_health_observation :=
    Health_observation.invalidate ~now !full_health_observation

let invalidate_full_health_snapshot () =
  with_full_health_snapshot_lock invalidate_full_health_snapshot_locked;
  (* The state above is the invalidation; the wake only brings the refresh
     forward. Its bounded stream write does not yield, including when the
     observer is a non-Eio domain. *)
  signal_full_health_refresh_wakeup ()

let invalidate_full_health_snapshot_for_workspace ~base_path =
    let wake =
      with_full_health_snapshot_lock (fun () ->
        let in_current_scope =
          match current_server_state_opt () with
          | None -> true
          | Some state ->
            let current_path = (Mcp_server.workspace_scope state).config.base_path in
            (match Config_dir_resolver.canonical_base_path base_path,
                   Config_dir_resolver.canonical_base_path current_path with
             | Ok base_path, Ok current_path -> String.equal base_path current_path
             | Error _, _ | _, Error _ -> true)
        in
        if in_current_scope then invalidate_full_health_snapshot_locked ();
        in_current_scope)
    in
    if wake then signal_full_health_refresh_wakeup ()
;;

let invalidate_full_health_snapshot_for_registry_change ~base_path = function
  (* Paused-keeper health still includes registry entries from all workspaces. *)
  | Keeper_registry.Lifecycle_phase_changed | Keeper_registry.Membership_changed ->
    invalidate_full_health_snapshot ()
  | Keeper_registry.Failure_reason_changed ->
    invalidate_full_health_snapshot_for_workspace ~base_path
;;

let fleet_stream_hub_for_scope_with ~before_registration
    ~state ~(scope : Mcp_server.workspace_scope) =
  match select_fleet_stream_hub state scope.epoch with
  | None -> None
  | Some (hub, _) ->
      before_registration ();
      let admitted, wake =
        with_full_health_snapshot_lock (fun () ->
          if not (fleet_hub_is_current state scope.epoch hub) then false, false
          else
            let worker = (!full_health_refresh).active_worker in
            let current = Fleet_stream_hub.current hub in
            let needs_refresh =
              match current, worker with
              | None, Some worker ->
                  not (Option.exists (Mcp_server.Workspace_scope_epoch.equal scope.epoch)
                         (full_health_failure_epoch worker.completion))
              | None, None | Some (Fleet_stream.Unavailable_snapshot _), None -> true
              | Some (Fleet_stream.Unavailable_snapshot _), Some _
              | Some (Fleet_stream.Snapshot _ | Fleet_stream.Changed _ | Fleet_stream.Degraded _),
                (None | Some _) -> false
            in
            (match current with
             | None ->
              Option.iter (fun (worker : full_health_completion Health_refresh.worker) ->
                worker.completion.waiting_scope <- Some (scope.epoch, hub);
                Option.iter (fun (failed_epoch, since, failure) ->
                  note_waiting_scope_failure_if_unmeasured worker.completion
                    ~failed_epoch ~since failure) worker.completion.last_failure) worker
             | Some _ -> ());
            if needs_refresh then invalidate_full_health_snapshot_locked ();
            true, needs_refresh)
      in
      if wake then signal_full_health_refresh_wakeup ();
      if admitted then Some hub else None

let fleet_stream_hub_for_scope ~state ~scope =
  fleet_stream_hub_for_scope_with ~before_registration:(fun () -> ()) ~state ~scope

let full_health_snapshot_state () =
  with_full_health_snapshot_lock (fun () ->
      { observation =
          Health_observation.for_scope ~workspace_epoch:(current_workspace_epoch ())
            !full_health_observation
      ; refresh = !full_health_refresh })

let make_cached_full_health_json_with ~after_selection ?timing ?(listener = default_listener)
    ~request_authority request =
  let now = Unix.gettimeofday () in
  let view = full_health_snapshot_state () in
  let snapshot = view.observation.snapshot in
  after_selection ();
  let needs_refresh =
    match snapshot with
    | None -> true
    | Some snapshot -> snapshot_is_stale ~now snapshot
  in
  let view =
    if needs_refresh then { view with refresh = mark_full_health_refresh_requested ~now () }
    else view
  in
  let fields =
    match snapshot with
    | Some snapshot -> snapshot.fields
    | None -> full_health_placeholder_fields ()
  in
  Tool_args.ok_assoc
    (make_health_probe_fields ?timing ~listener ~health_detail:"full" ~request_authority
       request
     @ fields
     @ [
         ( "full_health_snapshot",
           full_health_snapshot_metadata ~now view );
       ])

let make_cached_full_health_json ?timing ?listener ~request_authority request =
  make_cached_full_health_json_with ~after_selection:(fun () -> ())
    ?timing ?listener ~request_authority request

let start_full_health_snapshot_refresh_loop ~sw ~clock ~request_authority =
  let request = Httpun.Request.create `GET Server_health_paths.full in
  (match current_server_state_opt () with
   | Some state ->
       Server_observation_refresh.install_scoped ~state ~sw
         ~install:(fun ~scope:_ ~sw:_ ~is_current ->
           if is_current () then invalidate_full_health_snapshot ())
   | None -> ());
  Proactive_refresh.start_on_change
    ~sw
    ~clock
    ~changes:full_health_refresh_wakeup
    ~config:
      {
        (Proactive_refresh.default_config
           ~label:"full_health_snapshot"
           ~interval_s:full_health_refresh_interval_sec)
        with
        timeout_s = full_health_refresh_timeout_sec;
        on_failure = Some mark_full_health_refresh_wait_failure;
        wakeup_coalesce_s = full_health_refresh_wakeup_coalesce_sec;
        warm_delay_s = 0.5;
        warn_first_failure = false;
      }
    (* /health probe (5KB probe payload) was measured at 4-8s cold.
       Even though [Proactive_refresh] runs [compute] on its own
       fiber, that fiber lives on the Eio main domain — so the 6-10s
       fleet meta scan inside [compute_full_health_snapshot]
       blocked every other HTTP fiber for the duration (Eio cooperative
       scheduling: no yield points inside the synchronous compute).

       Offload to a worker domain via [Domain_pool_ref].  The probe
       payload is served from the cached snapshot; refresh runs off
       the main domain so concurrent HTTP requests are not stalled. *)
    ~compute:(fun () ->
      await_full_health_refresh_worker ~sw ~compute:(fun ~on_workspace_epoch ->
          Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
              compute_full_health_snapshot ~on_workspace_epoch ~request_authority request));
      (* A shared scan can return a recorded failure without raising. Keep
         that read owed instead of settling into an indefinite healthy wait.
         Its original typed failure already lives in the cached observation. *)
      match (full_health_snapshot_state ()).observation.snapshot with
      | Some { failure = Some (Proactive_refresh.Raised exn); _ } -> raise exn
      | Some { failure = Some (Proactive_refresh.Timed_out _); _ } -> raise Eio.Time.Timeout
      | Some { failure = None; _ } | None -> ())
    ~on_result:Fun.id

module For_testing = struct
  let make_cached_full_health_json_after_selection ~after_selection ~request_authority request =
    make_cached_full_health_json_with ~after_selection ~request_authority request

  let fleet_stream_hub_for_scope_before_registration ~before_registration ~state ~scope =
    fleet_stream_hub_for_scope_with ~before_registration ~state ~scope

  let take_full_health_wakeup () = Eio.Stream.take full_health_refresh_wakeup
  let take_full_health_wakeup_nonblocking () =
    Option.is_some (Eio.Stream.take_nonblocking full_health_refresh_wakeup)
  let full_health_wakeup_stream () = full_health_refresh_wakeup

  let reset_full_health_snapshot () =
    with_full_health_snapshot_lock (fun () ->
        full_health_observation := Health_observation.empty;
        full_health_refresh := Health_refresh.empty)

    (* The wakeup stream is deliberately left alone. It carries "re-check the
       flag" and nothing else, its capacity is 1, and this reset has already
       cleared the flag it points at -- so a token left behind can only make a
       running consumer look once and find its work already done. Clearing it
       needed a non-blocking take, which RFC-0063 6.1 bars from a file with no
       cooperative yield: the rule that caught the unbounded drain loop this
       reset used to run. *)

  let refresh_full_health_snapshot_now ?(listener = default_listener)
      ~request_authority request =
    refresh_full_health_snapshot_sync ~listener ~request_authority request

  let mark_full_health_snapshot_failure = mark_full_health_snapshot_failure

  let mark_full_health_refresh_wait_failure = mark_full_health_refresh_wait_failure

  let full_health_refresh_timing () =
    ( full_health_refresh_interval_sec,
      full_health_refresh_timeout_sec,
      full_health_snapshot_ttl_sec )

  let full_health_refresh_wakeup_coalesce_sec () =
    full_health_refresh_wakeup_coalesce_sec

  let run_full_health_refresh_worker_before_scope ~before_scope ~sw ~compute =
    await_full_health_refresh_worker ~sw ~compute:(fun ~on_workspace_epoch ->
        before_scope ();
        let workspace_epoch = current_workspace_epoch () in
        on_workspace_epoch workspace_epoch;
        let started_at = Unix.gettimeofday () in
        let fields, failure = match compute () with
          | Ok fields -> fields, None
          | Error failure ->
              full_health_placeholder_fields
                ~error:(Proactive_refresh.failure_message failure) ~status:"error" (),
              Some failure
        in
        let computed_at = Unix.gettimeofday () in
        let workspace_epoch, scope_consistent = unchanged_workspace_epoch workspace_epoch in
        { workspace_epoch;
          scope_consistent;
          fields;
          computed_at;
          duration_ms = duration_ms ~started_at ~finished_at:computed_at;
          failure;
          stale_since_ts = Option.map (fun _ -> computed_at) failure;
          last_good_available = Option.is_none failure;
          section_timings = []
        })

  let run_full_health_refresh_worker ~sw ~compute =
    run_full_health_refresh_worker_before_scope ~before_scope:(fun () -> ()) ~sw ~compute

  let full_health_refresh_worker_stats () =
    with_full_health_snapshot_lock (fun () ->
        let refresh = !full_health_refresh in
        ( refresh.submissions,
          refresh.joins,
          Option.is_some refresh.active_worker,
          refresh.invalidation_generation,
          Option.is_some (!full_health_observation).snapshot,
          refresh.requested ))
  ;;

  let full_health_observation_failures () =
    with_full_health_snapshot_lock (fun () ->
      (Health_observation.for_scope ~workspace_epoch:(current_workspace_epoch ())
         !full_health_observation).consecutive_failures)
  ;;
end

let full_health_requested request =
  Server_utils.bool_query_param request "full" ~default:false

(* RFC-0484 §3.3: the probe the TUI reads on every refresh carries the
   operator rollup the last full-health snapshot computed. The probe never
   computes the rollup, so it and [?full=1] always report the same snapshot;
   before the first snapshot it carries none, and the TUI shows nothing. *)
let probe_operator_rollup_fields () =
  match (full_health_snapshot_state ()).observation.snapshot with
  | None -> []
  | Some snapshot ->
    List.filter
      (fun (name, _) -> List.exists (String.equal name) Server_health_rollup.operator_field_names)
      snapshot.Health_observation.fields
;;

let make_health_response_json ?timing ?(listener = default_listener) ~request_authority
    request =
  measure_health_phase timing Server_timing.Health_response (fun () ->
    if full_health_requested request
    then make_cached_full_health_json ?timing ~listener ~request_authority request
    else
      make_health_probe_json ?timing ~listener ~request_authority
        ~extra_fields:(probe_operator_rollup_fields ()) request)

let make_health_response_body ?listener ~request_authority request =
  let timing = Server_timing.create () in
  let json = make_health_response_json ~timing ?listener ~request_authority request in
  let body =
    Server_timing.measure timing Server_timing.Json_serialize (fun () ->
      Yojson.Safe.to_string json)
  in
  body, Server_timing.extra_header timing

type health_requester =
  | Reads
  | Reads_nothing
  | Refused of Masc_domain.masc_error

(* HIGH-RISK-UNREVIEWED [H1]: the one decision of who gets more than the
   public probe. It is [Server_auth.board_access_for_request] and nothing
   else: Operator and Named read, Anonymous does not, and a credential that
   judgment refuses is refused here, never taken for no credential. Before a
   workspace is published nobody reads: there is no credential store to judge
   with. The match names every reader constructor, so a new one stops the
   build here. *)
let health_requester request =
  match current_server_state_opt () with
  | None -> Reads_nothing
  | Some state ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    (match Server_auth.board_access_for_request ~base_path request with
     | Ok
         ( ( Masc_board_handlers.Board_access.Operator
           | Masc_board_handlers.Board_access.Named _ )
         , (_ : string option) ) -> Reads
     | Ok (Masc_board_handlers.Board_access.Anonymous, (_ : string option)) -> Reads_nothing
     | Error error -> Refused error)
;;

(* The readiness both [/health/ready] and the public body of [/health] say:
   a published state and the startup flag, read once. *)
let public_readiness () =
  let ready = Option.is_some (ready_server_state ()) in
  ready, (Server_startup_state.snapshot ()).phase
;;

(* HIGH-RISK-UNREVIEWED [H2]: only the [Reads] branch builds or reads
   anything beyond the public probe: the query, the probe body, the operator
   rollup, the full-health snapshot and its refresh request, and the timing
   header. The other two branches run none of it. *)
let health_handler request reqd =
  match health_requester request with
  | Reads ->
    let request_authority = Server_request_authority.current_exn () in
    let listener = listener_of_protocol (Http_reqd.protocol reqd) in
    let body, extra_headers =
      make_health_response_body ~listener ~request_authority request
    in
    Http.Response.json ~extra_headers body reqd
  | Reads_nothing ->
    let ready, phase = public_readiness () in
    Http.Response.json_value (Server_health_public.health_json ~ready ~phase) reqd
  | Refused error -> Server_auth.respond_auth_error request reqd error
;;

(* HIGH-RISK-UNREVIEWED [H4]: the two sibling probes answer everyone with no
   judgment of the requester, so a field added to either body is public. *)

(** Liveness probe: responds 200 as soon as the HTTP accept loop is running.
    Does not depend on server_state initialization.
    Kubernetes/Railway liveness probe target. *)
let liveness_handler _request reqd =
  Http.Response.json_value Server_health_public.liveness_json reqd
;;

(** Readiness probe: responds 200 only after the startup barrier and state publication. *)
let readiness_handler _request reqd =
  let ready, phase = public_readiness () in
  let status = if ready then `OK else `Service_unavailable in
  Http.Response.json_value ~status (Server_health_public.readiness_json ~ready ~phase) reqd
;;

let board_comment_request_of_query ~offset ~limit =
  let open Result.Syntax in
  let integer_field name = function
    | None -> Ok None
    | Some raw ->
      (match int_of_string_opt raw with
       | Some value -> Ok (Some value)
       | None -> Error (Printf.sprintf "%s must be an integer" name))
  in
  let error message =
    `Assoc
      [ "error", `String message
      ; "code", `String "invalid_board_comment_page"
      ]
  in
  let parsed =
    let* offset = integer_field "comment_offset" offset in
    let* limit = integer_field "comment_limit" limit in
    let fields =
      List.filter_map Fun.id
        [ Option.map (fun value -> "comment_offset", `Int value) offset
        ; Option.map (fun value -> "comment_limit", `Int value) limit
        ]
    in
    match Board.Comment_page.request_of_args (`Assoc fields) with
    | Ok request -> Ok request
    | Error detail ->
      Error (Board.Comment_page.request_error_to_string detail)
  in
  Result.map_error error parsed
;;

let default_board_comment_request =
  match board_comment_request_of_query ~offset:None ~limit:None with
  | Ok request -> request
  | Error detail ->
    invalid_arg
      ("Board comment page default is invalid: " ^ Yojson.Safe.to_string detail)
;;

module Comment_id_map = Map.Make (String)
module Comment_id_set = Set.Make (String)

(* Resolve every displayed reply's ancestry in the already-read thread. The
   companion context may include rows outside the numeric page; the original
   comments/page contract stays unchanged for clients that only page rows. *)
let board_comment_context ~focused_comment comments selected =
  let by_id =
    List.fold_left
      (fun acc (comment : Board.comment) ->
        Comment_id_map.add (Board.Comment_id.to_string comment.id) comment acc)
      Comment_id_map.empty
      comments
  in
  let rec include_id included id =
    if Comment_id_set.mem id included then included
    else
      let included = Comment_id_set.add id included in
      match Comment_id_map.find_opt id by_id with
      | None -> included
      | Some comment ->
        (match comment.parent_id with
         | None -> included
         | Some parent -> include_id included (Board.Comment_id.to_string parent))
  in
  let included =
    List.fold_left
      (fun acc (comment : Board.comment) ->
        include_id acc (Board.Comment_id.to_string comment.id))
      Comment_id_set.empty
      selected
  in
  let included =
    match focused_comment with
    | None -> included
    | Some id -> include_id included id
  in
  List.filter
    (fun (comment : Board.comment) ->
      Comment_id_set.mem (Board.Comment_id.to_string comment.id) included)
    comments

let board_post_detail_json ~reader ?(comment_request = default_board_comment_request) ?focused_comment ~config ~voter
    ~reaction_actor ~response_format ~post_id () =
  match Board_dispatch.get_post_and_comments ~reader ~post_id with
  | Error err ->
      let status = match err with
        | Board.Io_error _ -> `Service_unavailable
        | Board.Invalid_id _ | Board.Post_not_found _ | Board.Comment_not_found _
        | Board.Validation_error _ | Board.Already_voted _ | Board.Already_exists _
        | Board.Unauthorized _ | Board.Recipient_lookup_failed _ -> `Not_found
      in
      (status, Yojson.Safe.to_string
         (`Assoc ["error", `String (Board_tool.board_error_to_string err)]))
  | Ok (post, comments) ->
      let _, comment_positions =
        List.fold_left
          (fun (offset, acc) (comment : Board.comment) ->
            offset + 1,
            Comment_id_map.add (Board.Comment_id.to_string comment.id) offset acc)
          (0, Comment_id_map.empty)
          comments
      in
      let comment_revision =
        `List (List.map (fun (comment : Board.comment) ->
            `List [ `String (Board.Comment_id.to_string comment.id)
                  ; (match comment.parent_id with
                     | None -> `Null
                     | Some parent -> `String (Board.Comment_id.to_string parent)) ]) comments)
        |> Yojson.Safe.to_string |> Agent_core_sha256.digest_string |> Agent_core_sha256.to_hex in
      let author = Board.Agent_id.to_string post.author in
      let author_karma = Board_dispatch.get_agent_karma ~reader ~agent_name:author in
      match
        Board.Comment_page.select
          ~comment_id_of:(fun (comment : Board.comment) ->
            Some (Board.Comment_id.to_string comment.id))
          comment_request comments
      with
      | Board.Comment_page.Offset_out_of_range { requested; total } ->
        ( `Bad_request
        , Yojson.Safe.to_string
            (`Assoc
               [ "error", `String
                   (Printf.sprintf
                      "comment_offset %d is past the end of a thread with %d comments"
                      requested total)
               ; "code", `String "invalid_board_comment_page"
               ]) )
      | Board.Comment_page.Comment_not_found { comment_id; _ } ->
        ( `Bad_request
        , Yojson.Safe.to_string
            (`Assoc
               [ "error", `String
                   (Printf.sprintf "comment %s is not in this thread"
                      (Board.Comment_id.to_string comment_id))
               ; "code", `String "invalid_board_comment_page"
               ]) )
      | Board.Comment_page.Page page ->
        let context_comments = board_comment_context ~focused_comment comments page.items in
        let comments = page.items in
        let comment_page_json =
          Board.Comment_page.Position.to_yojson
            (Board.Comment_page.Position.of_page page)
        in
        let current_vote = board_current_vote_for_post ~reader ~voter ~post_id in
        let reaction_targets =
          (Board.Reaction_post, post_id)
          :: List.map
               (fun (comment : Board.comment) ->
                  (Board.Reaction_comment, Board.Comment_id.to_string comment.id))
               context_comments
        in
        let reaction_rows =
          board_reactions_batch ~reader ~targets:reaction_targets ~voter:reaction_actor
        in
        let reactions_for = board_reactions_lookup reaction_rows in
        let reactions = reactions_for (Board.Reaction_post, post_id) in
        let post_json =
          board_post_dashboard_json ?current_vote
            ?reactions ~author_karma post
        in
        let comment_json (comment : Board.comment) =
          let comment_id = Board.Comment_id.to_string comment.id in
          let current_vote = board_current_vote_for_comment ~reader ~voter ~comment_id in
          let reactions = reactions_for (Board.Reaction_comment, comment_id) in
          board_comment_dashboard_json ?current_vote ?reactions comment in
        let context_comment_json (comment : Board.comment) =
          match comment_json comment with
          | `Assoc fields -> `Assoc
              (("thread_offset", `Int (Comment_id_map.find
                  (Board.Comment_id.to_string comment.id) comment_positions)) :: fields)
          | json -> json in
        let page_fields =
          [ "comments", `List (List.map comment_json comments);
            "comment_page", comment_page_json;
            "comment_context", `List (List.map context_comment_json context_comments);
            "comment_revision", `String comment_revision ]
        in
        let json =
          match response_format with
          | Server_board_post_response_format.Flat ->
            (match post_json with
             | `Assoc fields -> `Assoc (fields @ page_fields)
             | _ -> `Assoc (("post", post_json) :: page_fields))
          | Server_board_post_response_format.Nested ->
            `Assoc (("post", post_json) :: page_fields)
        in
        (`OK, Yojson.Safe.to_string json)

let board_sub_board_detail_prefix = "/api/v1/board/sub-boards/"

let board_sub_board_error_status ~fallback = function
  | Board.Io_error _ -> `Service_unavailable
  | Board.Invalid_id _ | Board.Post_not_found _ | Board.Comment_not_found _
  | Board.Validation_error _ | Board.Already_voted _ | Board.Already_exists _
  | Board.Unauthorized _ | Board.Recipient_lookup_failed _ -> fallback

let board_sub_board_detail_json ~reader ~path =
  match extract_path_param ~prefix:board_sub_board_detail_prefix path with
  | None ->
    (`Bad_request, `Assoc [ ("error", `String "sub_board_id is required") ])
  | Some sub_board_id ->
    (match Board_dispatch.get_sub_board ~reader ~sub_board_id with
     | Ok sb -> (`OK, Board.sub_board_to_yojson sb)
     | Error e ->
       ( board_sub_board_error_status ~fallback:`Not_found e,
         `Assoc [ ("error", `String (Board_tool.board_error_to_string e)) ] ))

(** CORS preflight handler *)
let options_handler request reqd =
  let request_authority = Server_request_authority.current_exn () in
  let cors =
    match public_read_cors_origin_opt ~request_authority request with
    | Some origin -> cors_preflight_headers origin
    | None -> [ "vary", "Origin" ]
  in
  let headers =
    Httpun.Headers.of_list (("content-length", "0") :: cors)
  in
  let response = Httpun.Response.create ~headers `No_content in
  Http_reqd.respond_with_string reqd response ""
