
open Server_utils
open Server_auth

open Server_routes_http_common

module Http = Http_server_eio

let is_dashboard_spa_deep_link path =
  String.starts_with ~prefix:"/dashboard/" path
  && not (String.starts_with ~prefix:"/dashboard/assets/" path)
  && path <> "/dashboard/credits"

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

let is_http_error_response = function
  | `Assoc fields ->
      let id_is_null =
        match List.assoc_opt "id" fields with
        | Some `Null -> true
        | _ -> false
      in
      let code =
        match List.assoc_opt "error" fields with
        | Some (`Assoc err_fields) ->
            (match List.assoc_opt "code" err_fields with
             | Some (`Int c) -> Some c
             | _ -> None)
        | _ -> None
      in
      let is_parse_or_invalid = function
        | Mcp_error_code.Parse_error | Invalid_request -> true
        | _ -> false
      in
      id_is_null
      && (match code with
          | Some c ->
              (match Mcp_error_code.of_wire_code c with
               | Some ec -> is_parse_or_invalid ec
               | None -> false)
          | None -> false)
  | _ -> false

(** Server start time for uptime calculation *)
(* server_start_time moved to [Server_routes_http_runtime_health_helpers]
   (godfile decomp). *)

let server_start_time = Server_routes_http_runtime_health_helpers.server_start_time
let configured_http_port () =
  Env_config_core.masc_http_port_int ()

let configured_http_host () =
  Env_config_core.masc_host ()

let authority_host host =
  match Ipaddr.of_string host with
  | Ok (Ipaddr.V6 _) -> "[" ^ host ^ "]"
  | Ok (Ipaddr.V4 _) | Error _ -> host

let authority_of_host_port host port =
  Printf.sprintf "%s:%d" (authority_host host) port

let advertised_host_port_authority request =
  let default_host = configured_http_host () in
  let default_port = configured_http_port () in
  let fallback () =
    let host = Transport_read_model.normalize_advertised_host default_host in
    (host, default_port, authority_of_host_port host default_port)
  in
  match Httpun.Headers.get request.Httpun.Request.headers "host" with
  | None -> fallback ()
  | Some raw -> (
      let trimmed = String.trim raw in
      if trimmed = "" || host_header_has_forbidden_authority_chars trimmed
      then fallback ()
      else
        try
          let uri = Uri.of_string ("http://" ^ trimmed) in
          let parsed_host = Uri.host uri |> Option.value ~default:default_host in
          let port_opt = Uri.port uri in
          let port = Option.value ~default:default_port port_opt in
          let host = Transport_read_model.normalize_advertised_host parsed_host in
          let authority =
            match port_opt with
            | Some _ -> authority_of_host_port host port
            | None ->
              if String.equal host parsed_host
              then authority_host host
              else authority_of_host_port host port
          in
          (host, port, authority)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | _ -> fallback ())

let advertised_host_port request =
  let host, port, _authority = advertised_host_port_authority request in
  (host, port)

let normalize_forwarded_proto raw =
  let value =
    raw
    |> String.trim
    |> String.lowercase_ascii
    |> fun value ->
    let len = String.length value in
    if len >= 2 && value.[0] = '"' && value.[len - 1] = '"'
    then String.sub value 1 (len - 2)
    else value
  in
  match value with
  | "http" | "https" -> Some value
  | _ -> None

let first_forwarded_proto raw =
  raw
  |> String.split_on_char ','
  |> List.find_map (fun element ->
       element
       |> String.split_on_char ';'
       |> List.find_map (fun part ->
            match String.split_on_char '=' (String.trim part) with
            | [ key; value ] when String.equal (String.lowercase_ascii (String.trim key)) "proto" ->
              normalize_forwarded_proto value
            | _ -> None))

let advertised_scheme request =
  let headers = request.Httpun.Request.headers in
  match Httpun.Headers.get headers "x-forwarded-proto" with
  | Some raw -> (
      match
        raw
        |> String.split_on_char ','
        |> List.find_map normalize_forwarded_proto
      with
      | Some scheme -> scheme
      | None -> (
          match Httpun.Headers.get headers "forwarded" with
          | Some raw -> Option.value ~default:"http" (first_forwarded_proto raw)
          | None -> "http"))
  | None -> (
      match Httpun.Headers.get headers "forwarded" with
      | Some raw -> Option.value ~default:"http" (first_forwarded_proto raw)
      | None -> "http")

let advertised_base_url request =
  let _host, _port, authority = advertised_host_port_authority request in
  Printf.sprintf "%s://%s" (advertised_scheme request) authority

let websocket_discovery_json request =
  let (host, _port) = advertised_host_port request in
  let ctx =
    Transport_read_model.make_http_context ~include_configured:true
      ~host ~base_url:(advertised_base_url request) ()
  in
  Transport_read_model.websocket_discovery_json ctx

let transport_json request =
  let (host, _port) = advertised_host_port request in
  let ctx =
    Transport_read_model.make_http_context ~include_configured:true
      ~host ~base_url:(advertised_base_url request) ()
  in
  Transport_read_model.transport_status_json ctx

let agent_card_json request =
  let (host, port) = advertised_host_port request in
  let base_url = advertised_base_url request in
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
            ("health", `String (base_url ^ "/health"));
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
            ("graphql_readonly", `Bool true);
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

let make_health_probe_fields ?(listener = "http/1.1") ?full_health_url
    ?(health_detail = "probe") request =
  let uptime_secs = health_uptime_secs () in
  let build = Build_identity.current () in
  let path_diagnostics = health_path_diagnostics () in
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
      ("transport", transport_json request);
      ("http_listener", Transport_metrics.http_listener_json ());
      ("paths", Server_base_path_diagnostics.to_yojson path_diagnostics);
      ( "internal_mcp_auth"
      , internal_mcp_auth_json ~base_path:path_diagnostics.effective_base_path );
      ("otel", otel_health_json ());
      ("uptime", `String (health_uptime_string uptime_secs));
      ("sse_clients", `Int (Sse.client_count ()));
      ("startup", Server_startup_state.to_yojson ());
      ("subsystems", Subsystem_health.to_yojson ());
      ("logs", Log.Ring.summary_json ());
      ("gc", quick_gc_json ());
    ]

let make_health_probe_json ?(listener = "http/1.1") request =
  Tool_args.ok_assoc
    (make_health_probe_fields ~listener ~health_detail:"probe"
       ~full_health_url:"/health?full=1" request)

(* Keeper fleet scan / paused-keeper diagnostics / phase counts / fleet safety
   extracted to [Server_routes_http_runtime_fleet_scan] (godfile decomp). *)
include Server_routes_http_runtime_fleet_scan
(* Fleet-level health field helpers extracted to
   [Server_routes_http_runtime_health_fleet] (godfile decomp). *)
include Server_routes_http_runtime_health_fleet

let full_health_refresh_timeout_error error =
  String_util.contains_substring error "refresh_timeout label=full_health_snapshot"

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
      let timed_out = full_health_refresh_timeout_error error in
      let status = if timed_out then "timeout" else "error" in
      full_health_component_placeholder ~error ~component_timed_out:true ~status name

let assoc_member_opt name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let assoc_string_opt name json =
  match assoc_member_opt name json with
  | Some (`String value) -> Some value
  | _ -> None

let assoc_bool_opt name json =
  match assoc_member_opt name json with
  | Some (`Bool value) -> Some value
  | _ -> None

let health_status_rank = Health_status.rank_string

let max_health_status = Health_status.max_string

let full_health_operator_summary ~keeper_fleet_safety
    ~keeper_identity_drift_json ~reaction_ledger_json ~keeper_config_schema_status
    ~keeper_config_schema_blocking ~keeper_config_schema_terminal_reason
    ~keeper_config_operator_action_required ~lazy_task_boot_guard_fires_total =
  let status = ref "ok" in
  let reasons = ref [] in
  let note_status component json fallback_reason =
    let component_status =
      match assoc_string_opt "status" json with
      | Some value -> value
      | None -> "unknown"
    in
    status := max_health_status !status component_status;
    let action_required =
      match assoc_bool_opt "operator_action_required" json with
      | Some value -> value
      | None -> false
    in
    let parsed_component_status = Health_status.of_string component_status in
    if
      action_required
      || Health_status.requires_operator_action parsed_component_status
      || Health_status.equal parsed_component_status Health_status.Unknown
    then
      let reason =
        match fallback_reason with
        | Some value -> value
        | None -> component_status
      in
      reasons := Printf.sprintf "%s:%s" component reason :: !reasons
  in
  note_status "keeper_fleet_safety" keeper_fleet_safety
    (assoc_string_opt "blocker" keeper_fleet_safety);
  note_status "keeper_identity_drift" keeper_identity_drift_json
    (assoc_string_opt "terminal_reason" keeper_identity_drift_json);
  note_status "keeper_reaction_ledger" reaction_ledger_json None;
  status := max_health_status !status keeper_config_schema_status;
  if keeper_config_operator_action_required || keeper_config_schema_blocking
  then
    reasons :=
      Printf.sprintf "keeper_config_schema:%s" keeper_config_schema_terminal_reason
      :: !reasons;
  if lazy_task_boot_guard_fires_total > 0
  then (
    status := max_health_status !status "degraded";
    reasons :=
      Printf.sprintf
        "lazy_task_boot_guard_fires_total:%d"
        lazy_task_boot_guard_fires_total
      :: !reasons);
  let reasons = List.rev !reasons in
  (!status, reasons <> [], reasons)

let make_health_json ?(listener = "http/1.1") ?section_timings_ref request =
  let uptime_secs = health_uptime_secs () in
  let build = Build_identity.current () in
  let keeper_config_parse_errors =
    try Keeper_types_profile.keeper_toml_config_errors () with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
        [
          {
            Keeper_types_profile.keeper_name = "unknown";
            path = "";
            error = Printexc.to_string exn;
            reason = "health_probe_failed";
          };
        ]
  in
  let keeper_config_unknown_keys =
    try Keeper_types_profile.keeper_toml_unknown_keys () with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
        [
          {
            Keeper_types_profile.keeper_name = "unknown";
            path = "";
            unknown_keys = [ "health_probe_failed: " ^ Printexc.to_string exn ];
          };
        ]
  in
  let keeper_config_unknown_key_count =
    List.fold_left
      (fun acc (entry : Keeper_types_profile.keeper_toml_unknown_keys) ->
        acc + List.length entry.unknown_keys)
      0
      keeper_config_unknown_keys
  in
  let keeper_config_parse_error_count = List.length keeper_config_parse_errors in
  let keeper_config_schema_blocking =
    keeper_config_parse_error_count > 0 || keeper_config_unknown_key_count > 0
  in
  let keeper_config_schema_terminal_reason =
    if keeper_config_parse_error_count > 0 then "config_parse_failed"
    else if keeper_config_unknown_key_count > 0 then "config_unknown_keys"
    else "none"
  in
  let key_paused_keepers = "paused_keepers" in
  let path_diagnostics = health_path_diagnostics () in
  let base_path = runtime_base_path_opt () in
  let phase_snapshot = keeper_phase_snapshot ?base_path () in
  let phase_counts = phase_snapshot.counts in
  let keeper_fibers = phase_counts.running in
  (* Single-pass fleet meta scan: reads each keeper meta file once,
     shared by paused-keepers and fleet-safety sections. *)
  let fleet_meta_scan =
    match current_server_state_opt () with
    | Some state ->
      Some (keeper_fleet_meta_scan (Mcp_server.workspace_config state))
    | None -> None
  in
  let keeper_identity_drift_json =
    compute_section ~name:"keeper_identity_drift" ?section_timings_ref
      (fun () ->
        match current_server_state_opt () with
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
              ("persisted_meta_count", `Int 0);
              ("persisted_meta_names", `List []);
              ("configured_without_meta_count", `Int 0);
              ("configured_without_meta_names", `List []);
              ("meta_without_config_count", `Int 0);
              ("meta_without_config_names", `List []);
              ("next_action", `String "none");
            ])
  in
  let paused_keepers_json =
    compute_section ~name:"paused_keepers" ?section_timings_ref
      (fun () ->
        match fleet_meta_scan with
        | Some scan ->
          paused_keepers_health_json_of_scan
            ~running_names:(running_paused_keeper_names ())
            scan.paused_scan
        | None -> paused_keepers_health_json ())
  in
  let reaction_ledger_json =
    compute_section ~name:"keeper_reaction_ledger" ?section_timings_ref
      keeper_reaction_ledger_health_json
  in
  let fd_accountant_json =
    compute_section ~name:"fd_accountant" ?section_timings_ref fd_accountant_snapshot_json
  in
  let keeper_fleet_safety =
    compute_section ~name:"keeper_fleet_safety" ?section_timings_ref
      (fun () ->
        match fleet_meta_scan with
        | Some scan ->
          keeper_fleet_safety_health_json
            ~bootable_names:scan.bootable_names
            ~autoboot_scan:scan.autoboot_scan
            ~phase_snapshot
            ?base_path
            ~phase_counts
            ~paused_keepers_json
            ()
        | None ->
          keeper_fleet_safety_health_json
            ~phase_snapshot
            ?base_path
            ~phase_counts
            ~paused_keepers_json
            ())
  in
  let lazy_task_boot_guard_fires_total =
    int_of_float
      (Otel_metric_store.metric_total "masc_lazy_task_boot_guard_fired_total")
  in
  let keeper_config_operator_action_required = keeper_config_schema_blocking in
  let overall_status, operator_action_required, operator_action_reasons =
    full_health_operator_summary
      ~keeper_fleet_safety
      ~keeper_identity_drift_json
      ~reaction_ledger_json
      ~keeper_config_schema_status:
        (if keeper_config_schema_blocking then "blocked" else "ok")
      ~keeper_config_schema_blocking
      ~keeper_config_schema_terminal_reason
      ~keeper_config_operator_action_required
      ~lazy_task_boot_guard_fires_total
  in
  Tool_args.ok_assoc [
    ("server", `String "masc");
    ("version", `String build.release_version);
    ("release_version", `String build.release_version);
    ("build", Build_identity.to_yojson build);
    ("health_detail", `String "full");
    ("protocol", protocol_json ~listener);
    ("transport", transport_json request);
    ("http_listener", Transport_metrics.http_listener_json ());
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
    ("subsystems", Subsystem_health.to_yojson ());
    (* Server log visibility belongs on the first health probe too.  Keep the
       payload cheap and redacted: only ring counters, latest metadata, and
       file-sink state are exposed here; full log rows stay behind the
       dashboard logs API. *)
    ("logs", Log.Ring.summary_json ());
    ("feature_flags", let features = Dashboard_feature_health.get_all_features () in
      Dashboard_feature_health.overview_json features);
    ("gc", quick_gc_json ());
    ("overall_status", `String overall_status);
    ("operator_action_required", `Bool operator_action_required);
    ( "operator_action_reasons",
      `List (List.map (fun reason -> `String reason) operator_action_reasons) );
    ("keeper_fibers", `Int keeper_fibers);
    ( "keeper_fd_pressure"
    , Keeper_fd_pressure.runtime_state_json ~active_keepers:keeper_fibers
        ~starting_keepers:0 ~requested_keepers:24 () );
    ("fd_accountant", fd_accountant_json);
    ("server_hibernation", Server_hibernation.status_json ());
    ("keeper_fleet_safety", keeper_fleet_safety);
    ("keeper_identity_drift", keeper_identity_drift_json);
    ("keeper_reaction_ledger", reaction_ledger_json);
    (* Paused-keeper visibility: a keeper with [meta.paused = true] does not
       run turns, and auto-paused keepers may no longer have a live registry
       entry. The dashboard "깨우기" button now auto-resumes paused keepers,
       but ops still need a quick count without external telemetry. List names
       so an operator can correlate with the structured blocker cause. *)
    (key_paused_keepers, paused_keepers_json);
    ("keeper_config_parse_error_count",
     `Int keeper_config_parse_error_count);
    ( "keeper_config_parse_errors",
      `List
        (List.map Keeper_types_profile.keeper_toml_config_error_to_json
           keeper_config_parse_errors) );
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
    (* P2 silent-failure fix: lazy_task_boot_guard fires when a keeper
       startup task exceeds the boot timeout (server_bootstrap_loops.ml:116).
       The Otel_metric_store counter `masc_lazy_task_boot_guard_fired_total`
       was already incremented but `/health` did not surface it, so an
       operator hitting /health would see "ok" while keepers had
       silently failed to start.  Exposing the cumulative count here
       lets dashboards / health probes alert on a non-zero value. *)
    ("lazy_task_boot_guard_fires_total",
     `Int lazy_task_boot_guard_fires_total);
  ]

(* [stale_since_ts] records the wall-clock time of the FIRST refresh
   failure since the last successful refresh.  It is preserved across
   subsequent consecutive failures (never overwritten — see
   [mark_full_health_snapshot_error]) and cleared on the next
   successful [store_full_health_snapshot].  This lets downstream
   consumers compute "how long has the snapshot been stale?" without
   relying on the per-failure [computed_at] timestamp, which under
   partial-degradation now points at the LAST successful refresh, not
   the failure event. *)
type full_health_snapshot = {
  fields : (string * Yojson.Safe.t) list;
  computed_at : float;
  duration_ms : int;
  error : string option;
  stale_since_ts : float option;
  last_good_available : bool;
  section_timings : (string * int) list;
}

let full_health_snapshot_mu = Stdlib.Mutex.create ()
let full_health_snapshot = ref None
let full_health_refresh_in_flight = ref false
let full_health_refresh_started_at = ref None
let full_health_refresh_requested = ref false
(* Consecutive [/health?full=1] refresh failures (timeouts or
   exceptions).  Reset to 0 on every successful
   [store_full_health_snapshot]; incremented inside
   [mark_full_health_snapshot_error].  Guarded by
   [full_health_snapshot_mu] like every other piece of refresh
   bookkeeping. *)
let full_health_consecutive_failures = ref 0
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

let with_full_health_snapshot_lock f =
  Stdlib.Mutex.protect full_health_snapshot_mu f

let full_health_cached_field_names =
  [
    "feature_flags";
    "overall_status";
    "operator_action_required";
    "operator_action_reasons";
    "keeper_fibers";
    "keeper_fd_pressure";
    "fd_accountant";
    "keeper_fleet_safety";
    "keeper_identity_drift";
    "keeper_reaction_ledger";
    "paused_keepers";
    "cdal";
    "keeper_config_parse_error_count";
    "keeper_config_parse_errors";
    "keeper_config_unknown_key_count";
    "keeper_config_unknown_keys";
    "keeper_config_schema_status";
    "keeper_config_schema_blocking";
    "keeper_config_schema_terminal_reason";
    "keeper_config_operator_action_required";
    "lazy_task_boot_guard_fires_total";
  ]

let full_health_field_is_cached name =
  List.exists (String.equal name) full_health_cached_field_names

let full_health_placeholder_fields ?error ?(component_timed_out = false)
    ?(status = "warming") () =
  [
    ( "feature_flags",
      full_health_component_placeholder ?error ~component_timed_out ~status
        "feature_flags" );
    ("overall_status", `String status);
    ("operator_action_required", `Bool false);
    ("operator_action_reasons", `List []);
    ("keeper_fibers", `Int 0);
    ( "keeper_fd_pressure",
      full_health_component_placeholder ?error ~component_timed_out ~status
        "keeper_fd_pressure" );
    ( "fd_accountant",
      full_health_component_placeholder ?error ~component_timed_out ~status
        "fd_accountant" );
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
          ("persisted_meta_count", `Int 0);
          ("persisted_meta_names", `List []);
          ("configured_without_meta_count", `Int 0);
          ("configured_without_meta_names", `List []);
          ("meta_without_config_count", `Int 0);
          ("meta_without_config_names", `List []);
          ("next_action", `String "none");
          ("component_timed_out", `Bool component_timed_out);
        ] );
    ( "keeper_reaction_ledger",
      full_health_component_placeholder ?error ~component_timed_out ~status
        "keeper_reaction_ledger" );
    ( "paused_keepers",
      `Assoc
        [
          ("status", `String status);
          ("count", `Int 0);
          ("names", `List []);
          ("component_timed_out", `Bool component_timed_out);
        ] );
    ( "cdal",
      full_health_component_placeholder ?error ~component_timed_out ~status
        "cdal" );
    ("keeper_config_parse_error_count", `Int 0);
    ("keeper_config_parse_errors", `List []);
    ("keeper_config_unknown_key_count", `Int 0);
    ("keeper_config_unknown_keys", `List []);
    ("keeper_config_schema_status", `String status);
    ("keeper_config_schema_blocking", `Bool false);
    ("keeper_config_schema_terminal_reason", `String "snapshot_not_ready");
    ("keeper_config_operator_action_required", `Bool false);
    ("lazy_task_boot_guard_fires_total", `Int 0);
  ]

let cached_full_health_fields = function
  | `Assoc fields ->
      let cached =
        List.filter (fun (name, _) -> full_health_field_is_cached name) fields
      in
      let has_cached name =
        List.exists (fun (cached_name, _) -> String.equal cached_name name) cached
      in
      let missing_placeholders =
        full_health_placeholder_fields ~status:"unavailable" ()
        |> List.filter (fun (name, _) ->
            full_health_field_is_cached name && not (has_cached name))
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

let compute_full_health_snapshot ?(listener = "http/1.1") request =
  let started_at = Unix.gettimeofday () in
  let section_timings_ref = ref [] in
  try
    let fields =
      cached_full_health_fields (make_health_json ~listener ~section_timings_ref request)
    in
    let finished_at = Unix.gettimeofday () in
    {
      fields;
      computed_at = finished_at;
      duration_ms = duration_ms ~started_at ~finished_at;
      error = None;
      stale_since_ts = None;
      last_good_available = true;
      section_timings = List.rev !section_timings_ref;
    }
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      let finished_at = Unix.gettimeofday () in
      let error = Printexc.to_string exn in
      {
        fields = full_health_placeholder_fields ~error ~status:"error" ();
        computed_at = finished_at;
        duration_ms = duration_ms ~started_at ~finished_at;
        error = Some error;
        stale_since_ts = Some finished_at;
        last_good_available = false;
        section_timings = List.rev !section_timings_ref;
      }

let store_full_health_snapshot snapshot =
  with_full_health_snapshot_lock (fun () ->
      full_health_snapshot := Some snapshot;
      full_health_refresh_in_flight := false;
      full_health_refresh_started_at := None;
      full_health_refresh_requested := false;
      (* Successful refresh — clear consecutive-failure counter so the
         critical alarm only re-fires after another N successive
         failures.  A snapshot is "successful" iff [error] is None;
         the inline error path in [compute_full_health_snapshot]
         routes through here too, so guard on the field. *)
      match snapshot.error with
      | None -> full_health_consecutive_failures := 0
      | Some _ -> ())

let mark_full_health_snapshot_error exn =
  let now = Unix.gettimeofday () in
  let error = Printexc.to_string exn in
  let timed_out = full_health_refresh_timeout_error error in
  with_full_health_snapshot_lock (fun () ->
      (* Partial degradation: preserve the last successful snapshot's
         per-component [fields] and overwrite only the [error] /
         [stale_since_ts] / refresh-bookkeeping signals.  If we have
         no prior snapshot (warm path on cold boot), fall back to the
         all-error placeholder so the field set stays well-typed. *)
      let preserved_fields, preserved_computed_at, preserved_duration_ms,
          prior_stale_since, last_good_available, preserved_section_timings =
        match !full_health_snapshot with
        | Some s when s.last_good_available ->
            (* A last-good payload exists — keep its component fields
               and preserve [computed_at] so [snapshot_age_ms]
               remains the age of the payload rather than the age of
               the failed refresh attempt. *)
            (s.fields, s.computed_at, s.duration_ms, s.stale_since_ts, true,
             s.section_timings)
        | Some s ->
            (* Previous snapshot was already an error placeholder —
               keep whatever [fields] it had (which may itself be
               preserved last-good data from an even earlier
               success) and DO NOT overwrite the [stale_since_ts]
               timestamp.  This pins [stale_since_ts] to the FIRST
               failure of the current outage. *)
            ( s.fields,
              s.computed_at,
              s.duration_ms,
              s.stale_since_ts,
              s.last_good_available,
              s.section_timings )
        | None ->
            (* Cold boot — no prior snapshot.  Fall back to the
               original placeholder shape, but classify refresh
               timeouts as [timeout] instead of generic [error] so
               operators can distinguish "no last-good payload yet"
               from a stale last-good fallback. *)
            let status = if timed_out then "timeout" else "error" in
            ( full_health_placeholder_fields ~error
                ~component_timed_out:timed_out ~status (),
              now,
              0,
              None,
              false,
              [] )
      in
      let stale_since_ts =
        match prior_stale_since with
        | Some t -> Some t
        | None -> Some now
      in
      full_health_snapshot :=
        Some
          {
            fields = preserved_fields;
            computed_at = preserved_computed_at;
            duration_ms = preserved_duration_ms;
            error = Some error;
            stale_since_ts;
            last_good_available;
            section_timings = preserved_section_timings;
          };
      full_health_refresh_in_flight := false;
      full_health_refresh_started_at := None;
      full_health_refresh_requested := false;
      (* Increment the consecutive-failure counter and emit the
         Otel_metric_store critical-edge signal ONLY when we cross the
         configured threshold on this exact failure.  Subsequent
         failures past the threshold do not re-emit — operators
         get one structural alert per outage, not a noisy stream
         scaling with the failure count. *)
      incr full_health_consecutive_failures;
      if !full_health_consecutive_failures
         = full_health_critical_failure_threshold
      then
        Otel_metric_store.inc_counter
          "masc_full_health_refresh_critical_total"
          ~labels:[ "reason", "consecutive_failures" ]
          ())

let compute_full_health_snapshot_for_refresh ?(listener = "http/1.1") request =
  with_full_health_snapshot_lock (fun () ->
      full_health_refresh_in_flight := true;
      full_health_refresh_started_at := Some (Unix.gettimeofday ());
      full_health_refresh_requested := false);
  compute_full_health_snapshot ~listener request

let refresh_full_health_snapshot_sync ?(listener = "http/1.1") request =
  compute_full_health_snapshot_for_refresh ~listener request
  |> store_full_health_snapshot

let snapshot_is_stale ~now snapshot =
  now -. snapshot.computed_at > full_health_snapshot_ttl_sec

let full_health_snapshot_stale_reason ~now snapshot =
  match snapshot with
  | None -> None
  | Some snapshot ->
      (match snapshot.error with
       | Some error
         when snapshot.last_good_available
              && full_health_refresh_timeout_error error ->
           Some "last_good_refresh_timeout"
       | Some _ when snapshot.last_good_available -> Some "last_good_refresh_error"
       | Some error when full_health_refresh_timeout_error error ->
           Some "refresh_timeout"
       | Some _ -> Some "refresh_error"
       | None when snapshot_is_stale ~now snapshot -> Some "ttl_expired"
       | None -> None)

let full_health_snapshot_stale_age_ms ~now snapshot =
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

let full_health_snapshot_metadata ~now ~refresh_in_flight ~refresh_started_at
    ~refresh_requested snapshot =
  let component_timed_out =
    match (refresh_in_flight, refresh_started_at) with
    | true, Some started_at ->
        now -. started_at > full_health_refresh_timeout_sec
    | _ ->
        (match snapshot with
         | Some { error = Some error; _ } -> full_health_refresh_timeout_error error
         | _ -> false)
  in
  let snapshot_age_ms, computed_at, duration_ms, error, stale_since_ts, status =
    match snapshot with
    | None -> (`Null, `Null, `Null, `Null, `Null, "warming")
    | Some snapshot ->
        let status =
          match snapshot.error with
          | Some _ when snapshot.last_good_available -> "stale"
          | Some error when full_health_refresh_timeout_error error -> "timeout"
          | Some _ -> "error"
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
          (Json_util.string_opt_to_json snapshot.error),
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
      ( "refresh_started_at_unix",
        match refresh_started_at with
        | Some started_at -> `Float started_at
        | None -> `Null );
      ( "refresh_timeout_ms",
        `Int (int_of_float (full_health_refresh_timeout_sec *. 1000.)) );
      ("component_timed_out", `Bool component_timed_out);
      ("error", error);
      ("last_good_available", `Bool (Option.fold ~none:false ~some:(fun s -> s.last_good_available) snapshot));
      ("section_timings", section_timings_json);
      (* [stale_since_ts] is the wall-clock of the FIRST failure of
         the current outage; null when the snapshot is fresh.
         Consumers should prefer this over [computed_at_unix] for
         "how long stale?" reasoning under partial-degradation, since
         [computed_at_unix] under an error now points at the failure
         time of the latest refresh attempt, not the last good
         data. *)
      ("stale_since_ts", stale_since_ts);
    ]

let mark_full_health_refresh_requested () =
  with_full_health_snapshot_lock (fun () -> full_health_refresh_requested := true)

let full_health_snapshot_state () =
  with_full_health_snapshot_lock (fun () ->
      ( !full_health_snapshot,
        !full_health_refresh_in_flight,
        !full_health_refresh_started_at,
        !full_health_refresh_requested ))

let make_cached_full_health_json ?(listener = "http/1.1") request =
  let now = Unix.gettimeofday () in
  let snapshot, _refresh_in_flight, _refresh_started_at, _refresh_requested =
    full_health_snapshot_state ()
  in
  let needs_refresh =
    match snapshot with
    | None -> true
    | Some snapshot -> snapshot_is_stale ~now snapshot
  in
  if needs_refresh then mark_full_health_refresh_requested ();
  let snapshot, refresh_in_flight, refresh_started_at, refresh_requested =
    full_health_snapshot_state ()
  in
  let fields =
    match snapshot with
    | Some snapshot -> snapshot.fields
    | None -> full_health_placeholder_fields ()
  in
  Tool_args.ok_assoc
    (make_health_probe_fields ~listener ~health_detail:"full" request
     @ fields
     @ [
         ( "full_health_snapshot",
           full_health_snapshot_metadata ~now ~refresh_in_flight
             ~refresh_started_at ~refresh_requested snapshot );
       ])

let start_full_health_snapshot_refresh_loop ~sw ~clock =
  let request = Httpun.Request.create `GET "/health?full=1" in
  Proactive_refresh.start
    ~sw
    ~clock
    ~config:
      {
        (Proactive_refresh.default_config
           ~label:"full_health_snapshot"
           ~interval_s:full_health_refresh_interval_sec)
        with
        timeout_s = full_health_refresh_timeout_sec;
        on_error = Some mark_full_health_snapshot_error;
        warm_delay_s = 0.5;
        warn_first_failure = false;
      }
    (* /health probe (5KB probe payload) was measured at 4-8s cold.
       Even though [Proactive_refresh] runs [compute] on its own
       fiber, that fiber lives on the Eio main domain — so the 6-10s
       fleet meta scan inside [compute_full_health_snapshot_for_refresh]
       blocked every other HTTP fiber for the duration (Eio cooperative
       scheduling: no yield points inside the synchronous compute).

       Offload to a worker domain via [Domain_pool_ref].  The probe
       payload is served from the cached snapshot; refresh runs off
       the main domain so concurrent HTTP requests are not stalled. *)
    ~compute:(fun () ->
      Domain_pool_ref.submit_io_or_inline (fun () ->
        compute_full_health_snapshot_for_refresh request))
    ~on_result:store_full_health_snapshot

module For_testing = struct
  let reset_full_health_snapshot () =
    with_full_health_snapshot_lock (fun () ->
        full_health_snapshot := None;
        full_health_refresh_in_flight := false;
        full_health_refresh_started_at := None;
        full_health_refresh_requested := false;
        full_health_consecutive_failures := 0)

  let refresh_full_health_snapshot_now ?(listener = "http/1.1") request =
    refresh_full_health_snapshot_sync ~listener request

  let mark_full_health_snapshot_error = mark_full_health_snapshot_error

  let full_health_refresh_timing () =
    ( full_health_refresh_interval_sec,
      full_health_refresh_timeout_sec,
      full_health_snapshot_ttl_sec )
end

let full_health_requested request =
  Server_utils.bool_query_param request "full" ~default:false

let make_health_response_json ?(listener = "http/1.1") request =
  if full_health_requested request then make_cached_full_health_json ~listener request
  else make_health_probe_json ~listener request

(** Health check handler *)
let health_handler request reqd =
  Http.Response.json_value (make_health_response_json request) reqd

(** Liveness probe: responds 200 as soon as the HTTP accept loop is running.
    Does not depend on server_state initialization.
    Kubernetes/Railway liveness probe target. *)
let liveness_handler _request reqd =
  let startup = Server_startup_state.to_yojson () in
  Http.Response.json_value
    (`Assoc
       [
         ("live", `Bool true);
         ("startup", startup);
       ])
    reqd

(** Readiness probe: responds 200 only when server_state is initialized. *)
let readiness_handler _request reqd =
  let current = Server_startup_state.(!state) in
  if current.state_ready then
    Http.Response.json_value
      (`Assoc
         [
           ("ready", `Bool true);
           ("phase", `String (Server_startup_state.phase_to_string current.phase));
           ("backend_mode", `String current.backend_mode);
         ])
      reqd
  else
    Http.Response.json_value ~status:`Service_unavailable
      (`Assoc
         [
           ("ready", `Bool false);
           ("phase", `String (Server_startup_state.phase_to_string current.phase));
           ("elapsed_sec", `Float (Server_startup_state.elapsed_since_start ()));
         ])
      reqd

let board_post_detail_json ~include_moderation ~blind_votes ~config ~voter
    ~response_format ~post_id =
  match Board_dispatch.get_post ~post_id with
  | Error err ->
      (* Render a human-readable message (e.g. "Post not found: <id>") via the
         shared Board_tool.board_error_to_string, matching the 404 contract in
         the .mli and the convention already used for board errors in
         server_routes_http_routes_activity.ml. The derived [show_board_error]
         leaked the internal OCaml constructor name ("Post_not_found(...)") into
         the public HTTP body. *)
      (`Not_found, Printf.sprintf {|{"error":"%s"}|}
         (String.escaped (Board_tool.board_error_to_string err)))
  | Ok post ->
      let author = Board.Agent_id.to_string post.author in
      let author_karma = Board_dispatch.get_agent_karma ~agent_name:author in
      let comments =
        match Board_dispatch.get_comments ~post_id with
        | Ok cs -> cs
        | Error err ->
            Log.Server.warn "board_post_detail: get_comments failed for %s: %s"
              post_id (Board_types.show_board_error err);
            []
      in
      let current_vote = board_current_vote_for_post ~voter ~post_id in
      let reaction_targets =
        (Board.Reaction_post, post_id)
        :: List.map
             (fun (comment : Board.comment) ->
                (Board.Reaction_comment, Board.Comment_id.to_string comment.id))
             comments
      in
      let reaction_rows = board_reactions_batch ~targets:reaction_targets ~voter in
      let reactions_for = board_reactions_lookup reaction_rows in
      let reactions = reactions_for (Board.Reaction_post, post_id) in
      let contributor_quality =
        board_contributor_quality_lookup ?config () author
      in
      let post_json =
        board_post_dashboard_json ~include_moderation ~blind_votes ?current_vote
          ?contributor_quality ~reactions ~author_karma post
      in
      let comments_json =
        `List (List.map (fun (comment : Board.comment) ->
          let comment_id = Board.Comment_id.to_string comment.id in
          let current_vote = board_current_vote_for_comment ~voter ~comment_id in
          let reactions = reactions_for (Board.Reaction_comment, comment_id) in
          board_comment_dashboard_json ~include_moderation ~blind_votes
            ?current_vote ~reactions comment
        ) comments)
      in
      let json =
        if String.equal (String.lowercase_ascii (String.trim response_format)) "flat" then
          match post_json with
          | `Assoc fields -> `Assoc (fields @ [ ("comments", comments_json) ])
          | _ -> `Assoc [ ("post", post_json); ("comments", comments_json) ]
        else
          `Assoc [ ("post", post_json); ("comments", comments_json) ]
      in
      (`OK, Yojson.Safe.to_string json)

(** CORS preflight handler *)
let options_handler request reqd =
  let origin = get_origin request in
  let headers = Httpun.Headers.of_list (
    ("content-length", "0") :: cors_preflight_headers origin
  ) in
  let response = Httpun.Response.create ~headers `No_content in
  Httpun.Reqd.respond_with_string reqd response ""
