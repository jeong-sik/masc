
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
let json_rpc_error code message =
  Printf.sprintf
    {|{"jsonrpc":"2.0","error":{"code":%d,"message":"%s"},"id":null}|}
    code
    (String.escaped message)

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
      id_is_null && (code = Some (-32700) || code = Some (-32600))
  | _ -> false

(** Server start time for uptime calculation *)
(* server_start_time moved to [Server_routes_http_runtime_health_helpers]
   (godfile decomp). *)

let server_start_time = Server_routes_http_runtime_health_helpers.server_start_time
let configured_http_port () =
  Env_config_core.masc_http_port_int ()

let configured_http_host () =
  Env_config_core.masc_host ()

let advertised_host_port request =
  let (host, port) =
    parse_host_port
      (Httpun.Headers.get request.Httpun.Request.headers "host")
      (configured_http_host ()) (configured_http_port ())
  in
  (Transport_read_model.normalize_advertised_host host, port)

let websocket_discovery_json request =
  let (host, port) = advertised_host_port request in
  let ctx =
    Transport_read_model.make_http_context ~include_configured:true
      ~host ~base_url:(Printf.sprintf "http://%s:%d" host port) ()
  in
  Transport_read_model.websocket_discovery_json ctx

let transport_json request =
  let (host, port) = advertised_host_port request in
  let ctx =
    Transport_read_model.make_http_context ~include_configured:true
      ~host ~base_url:(Printf.sprintf "http://%s:%d" host port) ()
  in
  Transport_read_model.transport_status_json ctx

let agent_card_json request =
  let (host, port) = advertised_host_port request in
  let base_url = Printf.sprintf "http://%s:%d" host port in
  let build = Build_identity.current () in
  `Assoc
    [
      ("schema", `String "masc.agent_card.v1");
      ("name", `String "MASC-MCP");
      ("description", `String "MASC multi-agent coordination MCP server");
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
            ("coordination", `Bool true);
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
let make_health_probe_fields ?(listener = "http/1.1") ?full_health_url
    ?(health_detail = "probe") request =
  let uptime_secs = health_uptime_secs () in
  let build = Build_identity.current () in
  let full_health_url_fields =
    match full_health_url with
    | Some url -> [ ("full_health_url", `String url) ]
    | None -> []
  in
  [
      ("server", `String "masc-mcp");
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
      ("paths", Server_base_path_diagnostics.to_yojson (health_path_diagnostics ()));
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
  let base_path = current_room_base_path_opt () in
  let phase_counts = keeper_phase_counts ?base_path () in
  let keeper_fibers = phase_counts.running in
  let paused_keepers_json =
    compute_section ~name:"paused_keepers" ?section_timings_ref paused_keepers_health_json
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
      (fun () -> keeper_fleet_safety_health_json ~phase_counts ~paused_keepers_json ())
  in
  let cdal_health_json =
    compute_section ~name:"cdal" ?section_timings_ref cdal_health_json
  in
  Tool_args.ok_assoc [
    ("server", `String "masc-mcp");
    ("version", `String build.release_version);
    ("release_version", `String build.release_version);
    ("build", Build_identity.to_yojson build);
    ("health_detail", `String "full");
    ("protocol", protocol_json ~listener);
    ("transport", transport_json request);
    ("http_listener", Transport_metrics.http_listener_json ());
    ("paths", Server_base_path_diagnostics.to_yojson path_diagnostics);
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
    ("keeper_fibers", `Int keeper_fibers);
    ( "keeper_fd_pressure"
    , Keeper_fd_pressure.runtime_state_json ~active_keepers:keeper_fibers
        ~starting_keepers:0 ~requested_keepers:24 () );
    ("fd_accountant", fd_accountant_json);
    ("keeper_fleet_safety", keeper_fleet_safety);
    ("keeper_reaction_ledger", reaction_ledger_json);
    (* Paused-keeper visibility: a keeper with [meta.paused = true] does not
       run turns, and auto-paused keepers may no longer have a live registry
       entry. The dashboard "깨우기" button now auto-resumes paused keepers,
       but ops still need a quick count without scraping /metrics. List names
       so an operator can correlate with the cause encoded in their
       last_blocker_class. *)
    (key_paused_keepers, paused_keepers_json);
    ("cdal", cdal_health_json);
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
      `Bool keeper_config_schema_blocking );
    (* P2 silent-failure fix: lazy_task_boot_guard fires when a keeper
       startup task exceeds the boot timeout (server_bootstrap_loops.ml:116).
       The Prometheus counter `masc_lazy_task_boot_guard_fired_total`
       was already incremented but `/health` did not surface it, so an
       operator hitting /health would see "ok" while keepers had
       silently failed to start.  Exposing the cumulative count here
       lets dashboards / health probes alert on a non-zero value. *)
    ("lazy_task_boot_guard_fires_total",
     `Int (int_of_float
             (Prometheus.metric_total "masc_lazy_task_boot_guard_fired_total")));
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
  Stdlib.Mutex.lock full_health_snapshot_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock full_health_snapshot_mu)
    f

let full_health_cached_field_names =
  [
    "feature_flags";
    "keeper_fibers";
    "keeper_fd_pressure";
    "fd_accountant";
    "keeper_fleet_safety";
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
  | `Assoc fields -> List.filter (fun (name, _) -> full_health_field_is_cached name) fields
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
         Prometheus critical-edge signal ONLY when we cross the
         configured threshold on this exact failure.  Subsequent
         failures past the threshold do not re-emit — operators
         get one structural alert per outage, not a noisy stream
         scaling with the failure count. *)
      incr full_health_consecutive_failures;
      if !full_health_consecutive_failures
         = full_health_critical_failure_threshold
      then
        Prometheus.inc_counter
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
          (match snapshot.error with Some error -> `String error | None -> `Null),
          stale_since_ts_json,
          status )
  in
  let stale_reason =
    match full_health_snapshot_stale_reason ~now snapshot with
    | Some reason -> `String reason
    | None -> `Null
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
      }
    ~compute:(fun () -> compute_full_health_snapshot_for_refresh request)
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
  Http.Response.json
    (Yojson.Safe.to_string (make_health_response_json request))
    reqd

(** Liveness probe: responds 200 as soon as the HTTP accept loop is running.
    Does not depend on server_state initialization.
    Kubernetes/Railway liveness probe target. *)
let liveness_handler _request reqd =
  let startup = Server_startup_state.to_yojson () in
  let body =
    Yojson.Safe.to_string
      (`Assoc
         [
           ("live", `Bool true);
           ("startup", startup);
         ])
  in
  Http.Response.json body reqd

(** Readiness probe: responds 200 only when server_state is initialized. *)
let readiness_handler _request reqd =
  let current = Server_startup_state.(!state) in
  if current.state_ready then
    Http.Response.json
      (Yojson.Safe.to_string
         (`Assoc
            [
              ("ready", `Bool true);
              ("phase", `String (Server_startup_state.phase_to_string current.phase));
              ("backend_mode", `String current.backend_mode);
            ]))
      reqd
  else
    Http.Response.json ~status:`Service_unavailable
      (Yojson.Safe.to_string
         (`Assoc
            [
              ("ready", `Bool false);
              ("phase", `String (Server_startup_state.phase_to_string current.phase));
              ("elapsed_sec", `Float (Server_startup_state.elapsed_since_start ()));
            ]))
      reqd

let board_post_detail_json ~include_moderation ~blind_votes ~config ~voter
    ~response_format ~post_id =
  match Board_dispatch.get_post ~post_id with
  | Error err ->
      (`Not_found, Printf.sprintf {|{"error":"%s"}|}
         (String.escaped (Board_types.show_board_error err)))
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
