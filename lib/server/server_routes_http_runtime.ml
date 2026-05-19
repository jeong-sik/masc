
open Server_utils
open Server_auth

open Server_routes_http_common

module Http = Http_server_eio

let is_dashboard_spa_deep_link path =
  starts_with ~prefix:"/dashboard/" path
  && not (starts_with ~prefix:"/dashboard/assets/" path)
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
let server_start_time = Unix.gettimeofday ()

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
      ~allow_legacy_accept:Server_routes_http_common.allow_legacy_accept ~host
      ~base_url:(Printf.sprintf "http://%s:%d" host port) ()
  in
  Transport_read_model.websocket_discovery_json ctx

let transport_json request =
  let (host, port) = advertised_host_port request in
  let ctx =
    Transport_read_model.make_http_context ~include_configured:true
      ~allow_legacy_accept:Server_routes_http_common.allow_legacy_accept ~host
      ~base_url:(Printf.sprintf "http://%s:%d" host port) ()
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

let health_path_diagnostics () =
  match current_server_state_opt () with
  | Some state ->
      Server_base_path_diagnostics.detect
        ?input_base_path:((Host_config.from_env ()).base_path_raw)
        ?env_masc_base_path:((Host_config.from_env ()).base_path_raw)
        ~effective_base_path:state.room_config.base_path
        ~effective_masc_root:(Coord.masc_root_dir state.room_config)
        ()
  | None ->
      let effective_base_path = default_base_path () in
      let effective_masc_root = Common.masc_dir_from_base_path ~base_path:effective_base_path in
      Server_base_path_diagnostics.detect
        ?input_base_path:((Host_config.from_env ()).base_path_raw)
        ?env_masc_base_path:((Host_config.from_env ()).base_path_raw)
        ~effective_base_path ~effective_masc_root ()

let health_uptime_secs () =
  (* NDT-OK: /health exposes wall-clock process uptime for operators; no
     persisted state transition or scheduler decision depends on this value. *)
  int_of_float (Unix.gettimeofday () -. server_start_time)

let health_uptime_string uptime_secs =
  if uptime_secs < 60 then Printf.sprintf "%ds" uptime_secs
  else if uptime_secs < 3600 then
    Printf.sprintf "%dm %ds" (uptime_secs / 60) (uptime_secs mod 60)
  else Printf.sprintf "%dh %dm" (uptime_secs / 3600) ((uptime_secs mod 3600) / 60)

let protocol_json ~listener =
  `Assoc
    [
      ("default", `String mcp_protocol_version_default);
      ("listener", `String listener);
      ( "supported",
        `List (List.map (fun v -> `String v) mcp_protocol_versions) );
    ]

let quick_gc_json () =
  (* Keep health probes cheap under live keeper load. [Gc.stat] can force a
     full major-cycle sync across domains; [Gc.quick_stat] exposes the same
     operator-facing counters without walking the heap. *)
  let s = Gc.quick_stat () in
  `Assoc
    [
      ("minor_collections", `Int s.minor_collections);
      ("major_collections", `Int s.major_collections);
      ("compactions", `Int s.compactions);
      ("heap_words", `Int s.heap_words);
      ("live_words", `Int s.live_words);
      ("minor_heap_size", `Int (let c = Gc.get () in c.minor_heap_size));
    ]

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

type paused_keeper_scan = {
  names : string list;
  autoboot_enabled_names : string list;
  details : Yojson.Safe.t list;
  read_errors : (string * string) list;
}

let sorted_unique_strings values = List.sort_uniq String.compare values

let json_float_opt = function
  | Some value -> `Float value
  | None -> `Null

let json_string_opt = function
  | Some value -> `String value
  | None -> `Null

let effective_autoboot_enabled name (meta : Keeper_types.keeper_meta) =
  match (Keeper_types_profile.load_keeper_profile_defaults name).autoboot_enabled with
  | Some value -> value
  | None -> meta.autoboot_enabled

let blocker_class_string (info : Keeper_types.blocker_info option) =
  match info with
  | Some info -> Some (Keeper_types.blocker_class_to_string info.klass)
  | None -> None

let blocker_detail (info : Keeper_types.blocker_info option) =
  match info with
  | Some { detail; _ } when String.trim detail <> "" -> Some detail
  | Some _ | None -> None

let pause_elapsed_sec now (meta : Keeper_types.keeper_meta) =
  match Coord_resilience.Time.parse_iso8601_opt meta.updated_at with
  | Some updated_ts when updated_ts > 0.0 -> Some (max 0.0 (now -. updated_ts))
  | Some _ | None -> None

let pause_kind (meta : Keeper_types.keeper_meta) =
  if Keeper_supervisor_types.paused_meta_requires_reconcile_recovery meta then
    "reconcile_gated"
  else
    match meta.auto_resume_after_sec with
    | Some _ -> "auto_recoverable"
    | None -> "operator_paused"

let paused_keeper_detail_json ~now ~name ~(autoboot_enabled : bool)
    (meta : Keeper_types.keeper_meta) =
  let elapsed = pause_elapsed_sec now meta in
  let remaining =
    match (meta.auto_resume_after_sec, elapsed) with
    | Some resume_after, Some elapsed -> Some (max 0.0 (resume_after -. elapsed))
    | Some resume_after, None -> Some resume_after
    | None, _ -> None
  in
  let last_blocker = meta.runtime.last_blocker in
  `Assoc [
    ("name", `String name);
    ("autoboot_enabled", `Bool autoboot_enabled);
    ("pause_kind", `String (pause_kind meta));
    ("auto_resume_after_sec", json_float_opt meta.auto_resume_after_sec);
    ("paused_elapsed_sec", json_float_opt elapsed);
    ("auto_resume_remaining_sec", json_float_opt remaining);
    ("last_blocker_class", json_string_opt (blocker_class_string last_blocker));
    ("last_blocker_detail", json_string_opt (blocker_detail last_blocker));
    ( "missing_pause_root_cause",
      `Bool
        (Option.is_some meta.auto_resume_after_sec
         && Option.is_none meta.runtime.last_blocker) );
  ]

let running_paused_keeper_names () =
  Keeper_registry.all ()
  |> List.filter_map (fun (e : Keeper_registry.registry_entry) ->
       if e.meta.paused then Some e.name else None)
  |> sorted_unique_strings

let durable_paused_keeper_scan config =
  (* NDT-OK: HTTP health snapshots report wall-clock pause age; state transitions remain ledger-driven. *)
  let now = Unix.gettimeofday () in
  Keeper_types.keeper_names config
  |> List.fold_left
       (fun acc name ->
         match Keeper_types.read_meta config name with
         | Ok (Some meta) when meta.paused ->
             let autoboot_enabled = effective_autoboot_enabled name meta in
             {
               acc with
               names = meta.name :: acc.names;
               autoboot_enabled_names =
                 (if autoboot_enabled then meta.name :: acc.autoboot_enabled_names
                  else acc.autoboot_enabled_names);
               details =
                 paused_keeper_detail_json ~now ~name:meta.name ~autoboot_enabled meta
                 :: acc.details;
             }
         | Ok (Some _) | Ok None -> acc
         | Error err ->
             { acc with read_errors = (name, err) :: acc.read_errors })
       { names = []; autoboot_enabled_names = []; details = []; read_errors = [] }
  |> fun scan ->
  {
    names = sorted_unique_strings scan.names;
    autoboot_enabled_names = sorted_unique_strings scan.autoboot_enabled_names;
    details =
      List.sort
        (fun left right ->
          let name = function
            | `Assoc fields -> (
              match List.assoc_opt "name" fields with
              | Some (`String value) -> value
              | _ -> "" )
            | _ -> ""
          in
          String.compare (name left) (name right))
        scan.details;
    read_errors = List.sort (fun (a, _) (b, _) -> String.compare a b) scan.read_errors;
  }

let paused_keepers_health_json () =
  let running_names = running_paused_keeper_names () in
  let durable_scan =
    match current_server_state_opt () with
    | Some state -> durable_paused_keeper_scan state.Mcp_server.room_config
    | None -> { names = []; autoboot_enabled_names = []; details = []; read_errors = [] }
  in
  let names = sorted_unique_strings (running_names @ durable_scan.names) in
  `Assoc [
    ("count", `Int (List.length names));
    ("names", `List (List.map (fun name -> `String name) names));
    ("running_count", `Int (List.length running_names));
    ("running_names", `List (List.map (fun name -> `String name) running_names));
    ("durable_count", `Int (List.length durable_scan.names));
    ("durable_names", `List (List.map (fun name -> `String name) durable_scan.names));
    ( "autoboot_enabled_count",
      `Int (List.length durable_scan.autoboot_enabled_names) );
    ( "autoboot_enabled_names",
      `List (List.map (fun name -> `String name) durable_scan.autoboot_enabled_names) );
    ("details", `List durable_scan.details);
    ("read_error_count", `Int (List.length durable_scan.read_errors));
    ( "read_errors",
      `List
        (List.map
           (fun (keeper, error) ->
             `Assoc [ ("keeper", `String keeper); ("error", `String error) ])
           durable_scan.read_errors) );
  ]

type autoboot_keeper_scan = {
  autoboot_names : string list;
  read_errors : (string * string) list;
}

let autoboot_enabled_keeper_scan config =
  sorted_unique_strings (Keeper_types.configured_keeper_names config @ Keeper_types.keeper_names config)
  |> List.fold_left
       (fun acc name ->
         match Keeper_types.read_meta config name with
         | Ok (Some meta) ->
             if effective_autoboot_enabled name meta then
               { acc with autoboot_names = meta.name :: acc.autoboot_names }
             else acc
         | Ok None ->
             if Keeper_meta_store.declarative_autoboot_enabled_by_default name then
               { acc with autoboot_names = name :: acc.autoboot_names }
             else acc
         | Error err ->
             {
               autoboot_names = name :: acc.autoboot_names;
               read_errors = (name, err) :: acc.read_errors;
             })
       { autoboot_names = []; read_errors = [] }
  |> fun scan ->
  {
    autoboot_names = sorted_unique_strings scan.autoboot_names;
    read_errors = List.sort (fun (a, _) (b, _) -> String.compare a b) scan.read_errors;
  }

type keeper_phase_counts =
  { running : int
  ; failing : int
  ; executable : int
  }

let keeper_phase_counts ?base_path () =
  Keeper_registry.all ?base_path ()
  |> List.fold_left
       (fun acc (entry : Keeper_registry.registry_entry) ->
          let executable =
            if Keeper_state_machine.can_execute_turn entry.phase then acc.executable + 1
            else acc.executable
          in
          match entry.phase with
          | Keeper_state_machine.Running ->
            { acc with running = acc.running + 1; executable }
          | Keeper_state_machine.Failing ->
            { acc with failing = acc.failing + 1; executable }
          | Keeper_state_machine.Offline
          | Keeper_state_machine.Overflowed
          | Keeper_state_machine.Compacting
          | Keeper_state_machine.HandingOff
          | Keeper_state_machine.Draining
          | Keeper_state_machine.Paused
          | Keeper_state_machine.Stopped
          | Keeper_state_machine.Crashed
          | Keeper_state_machine.Restarting
          | Keeper_state_machine.Dead
          | Keeper_state_machine.Zombie -> { acc with executable })
       { running = 0; failing = 0; executable = 0 }

let keeper_fleet_safety_health_json ~phase_counts ~paused_keepers_json =
  let bootable_names, autoboot_scan =
    match current_server_state_opt () with
    | Some state ->
        (try
           ( Keeper_runtime.bootable_keeper_names state.Mcp_server.room_config,
             autoboot_enabled_keeper_scan state.Mcp_server.room_config )
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
             Log.Keeper.warn
               "health: failed to compute bootable keeper names: %s"
               (Printexc.to_string exn);
             ([], { autoboot_names = []; read_errors = [] }))
    | None -> ([], { autoboot_names = []; read_errors = [] })
  in
  let bootable_count = List.length bootable_names in
  let target_count = List.length autoboot_scan.autoboot_names in
  let minimum_running_fibers =
    if target_count <= 1 then target_count else 2
  in
  let no_running_fibers = target_count > 0 && phase_counts.running = 0 in
  let no_executable_keeper_fibers = target_count > 0 && phase_counts.executable = 0 in
  let low_running_fiber_margin =
    target_count > 1 && phase_counts.running < minimum_running_fibers
  in
  let reaction_capacity_shortfall_count = max 0 (target_count - phase_counts.running) in
  let reaction_capacity_below_target =
    target_count > 0 && reaction_capacity_shortfall_count > 0
  in
  let executable_reaction_capacity_shortfall_count =
    max 0 (target_count - phase_counts.executable)
  in
  let executable_reaction_capacity_below_target =
    target_count > 0 && executable_reaction_capacity_shortfall_count > 0
  in
  let status =
    if no_executable_keeper_fibers then "blocked"
    else if no_running_fibers then "degraded"
    else if low_running_fiber_margin then "degraded"
    else if reaction_capacity_below_target then "degraded"
    else "ok"
  in
  let paused_total_count =
    match paused_keepers_json with
    | `Assoc fields ->
        (match List.assoc_opt "count" fields with
       | Some (`Int count) -> count
       | _ -> 0)
    | _ -> 0
  in
  let paused_autoboot_count =
    match paused_keepers_json with
    | `Assoc fields ->
        (match List.assoc_opt "autoboot_enabled_count" fields with
         | Some (`Int count) -> count
         | _ -> 0)
    | _ -> 0
  in
  let blocked_count =
    if no_executable_keeper_fibers then executable_reaction_capacity_shortfall_count
    else if no_running_fibers || low_running_fiber_margin || reaction_capacity_below_target
    then
      reaction_capacity_shortfall_count
    else 0
  in
  let blocker =
    if no_executable_keeper_fibers then Some "no_executable_keeper_fibers"
    else if no_running_fibers then Some "no_healthy_running_keeper_fibers"
    else if low_running_fiber_margin then Some "low_running_fiber_margin"
    else if reaction_capacity_below_target then Some "reaction_capacity_below_target"
    else if paused_autoboot_count > 0 then Some "durable_paused_autoboot_enabled"
    else None
  in
  `Assoc
    [ "status", `String status
    ; ("blocker", json_string_opt blocker)
    ; "bootable_keeper_count", `Int bootable_count
    ; ( "bootable_keeper_names"
      , `List (List.map (fun name -> `String name) bootable_names) )
    ; "autoboot_enabled_keeper_count", `Int target_count
    ; ( "autoboot_enabled_keeper_names"
      , `List (List.map (fun name -> `String name) autoboot_scan.autoboot_names) )
    ; "autoboot_enabled_read_error_count", `Int (List.length autoboot_scan.read_errors)
    ; ( "autoboot_enabled_read_errors"
      , `List
          (List.map
             (fun (keeper, error) ->
               `Assoc [ ("keeper", `String keeper); ("error", `String error) ])
             autoboot_scan.read_errors) )
    ; "running_keeper_fiber_count", `Int phase_counts.running
    ; "healthy_running_keeper_fiber_count", `Int phase_counts.running
    ; "failing_keeper_fiber_count", `Int phase_counts.failing
    ; "executable_keeper_fiber_count", `Int phase_counts.executable
    ; "effective_reaction_capacity_count", `Int phase_counts.running
    ; "executable_reaction_capacity_count", `Int phase_counts.executable
    ; "target_reaction_capacity_count", `Int target_count
    ; "minimum_running_fibers", `Int minimum_running_fibers
    ; "no_running_fibers", `Bool no_running_fibers
    ; "no_executable_keeper_fibers", `Bool no_executable_keeper_fibers
    ; "low_running_fiber_margin", `Bool low_running_fiber_margin
    ; "reaction_capacity_below_target", `Bool reaction_capacity_below_target
    ; "reaction_capacity_shortfall_count", `Int reaction_capacity_shortfall_count
    ; ( "executable_reaction_capacity_below_target"
      , `Bool executable_reaction_capacity_below_target )
    ; ( "executable_reaction_capacity_shortfall_count"
      , `Int executable_reaction_capacity_shortfall_count )
    ; "paused_keeper_count", `Int paused_total_count
    ; "paused_autoboot_enabled_keeper_count", `Int paused_autoboot_count
    ; "blocked_count", `Int blocked_count
    ; "blocked_keepers", `Int blocked_count
    ; ( "operator_action_required"
      , `Bool
          (no_executable_keeper_fibers
           || no_running_fibers
           || low_running_fiber_margin
           || reaction_capacity_below_target) )
    ]

let take limit values =
  let rec loop remaining acc = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | value :: rest -> loop (remaining - 1) (value :: acc) rest
  in
  loop limit [] values
;;

let keeper_reaction_ledger_health_json () =
  match current_server_state_opt () with
  | None ->
    `Assoc
      [ "schema", `String "keeper.reaction_ledger.fleet_summary.v1"
      ; "status", `String "unavailable"
      ; "operator_action_required", `Bool false
      ; "keeper_count", `Int 0
      ; "keeper_names", `List []
      ; "scanned_row_limit_per_keeper", `Int 20
      ; "row_count", `Int 0
      ; "stimulus_count", `Int 0
      ; "reaction_count", `Int 0
      ; "pending_stimulus_count", `Int 0
      ; "pending_by_keeper", `List []
      ; "read_error_count", `Int 0
      ; "keepers", `List []
      ]
  | Some state ->
    let config = state.Mcp_server.room_config in
    let keeper_names =
      try Keeper_types.keeper_names config |> sorted_unique_strings |> take 64 with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Log.Keeper.warn
          "health: failed to compute keeper reaction ledger names: %s"
          (Printexc.to_string exn);
        []
    in
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path:config.base_path
      ~keeper_names
      ~limit_per_keeper:20
;;

let paused_keeper_count = function
  | `Assoc fields ->
      (match List.assoc_opt "count" fields with
       | Some (`Int count) -> count
       | _ -> 0)
  | _ -> 0
;;

let bool_field name = function
  | `Assoc fields ->
      (match List.assoc_opt name fields with
       | Some (`Bool value) -> value
       | _ -> false)
  | _ -> false
;;

(* Scope keeper counts to the active workspace's base_path so a running
   keeper from another workspace cannot mask a local outage in fleet
   safety. `bootable_keeper_count` is already derived from
   `state.room_config`, so the running count must use the same scope. *)
let current_room_base_path_opt () =
  match current_server_state_opt () with
  | Some state -> Some state.Mcp_server.room_config.base_path
  | None -> None

let keeper_fleet_runtime_resolution_base_fields () =
  let base_path = current_room_base_path_opt () in
  let phase_counts = keeper_phase_counts ?base_path () in
  let keeper_fibers = phase_counts.running in
  let paused_keepers_json = paused_keepers_health_json () in
  let reaction_ledger_json = keeper_reaction_ledger_health_json () in
  let fleet_safety =
    keeper_fleet_safety_health_json ~phase_counts ~paused_keepers_json
  in
  [ "keeper_fibers", `Int keeper_fibers
  ; "paused_keepers", `Int (paused_keeper_count paused_keepers_json)
  ; "keeper_fleet_no_fibers", `Bool (bool_field "no_running_fibers" fleet_safety)
  ; ( "keeper_fd_pressure"
    , Keeper_fd_pressure.runtime_state_json ~active_keepers:keeper_fibers
        ~starting_keepers:0 ~requested_keepers:24 () )
  ; "keeper_fleet_safety", fleet_safety
  ; "keeper_reaction_ledger", reaction_ledger_json
  ]
;;

let fd_accountant_snapshot_json () =
  let snapshot = Fd_accountant.fd_snapshot () in
  let per_kind =
    snapshot.per_kind
    |> List.map (fun (kind, in_flight) ->
      let kind_name = Fd_accountant.kind_to_string kind in
      `Assoc
        [ "kind", `String kind_name
        ; "in_flight", `Int in_flight
        ; "configured_concurrency", `Int (Fd_accountant.configured_concurrency ~kind)
        ; "effective_concurrency", `Int (Fd_accountant.effective_concurrency ~kind)
        ])
  in
  `Assoc
    [ "fd_open", `Int snapshot.fd_open
    ; "fd_limit", `Int snapshot.fd_limit
    ; "pressure_active", `Bool snapshot.pressure_active
    ; "per_kind", `List per_kind
    ]
;;

let keeper_fleet_runtime_resolution_fields () =
  keeper_fleet_runtime_resolution_base_fields ()
  @ [ "fd_accountant", fd_accountant_snapshot_json () ]
;;

let cdal_health_json () =
  try Cdal_runtime_health.snapshot_json () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      Tool_args.error_assoc
        [
          ("component", `String "cdal");
          ("error", `String (Printexc.to_string exn));
        ]

let make_health_json ?(listener = "http/1.1") request =
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
  let base_path = current_room_base_path_opt () in
  let phase_counts = keeper_phase_counts ?base_path () in
  let keeper_fibers = phase_counts.running in
  let paused_keepers_json = paused_keepers_health_json () in
  let reaction_ledger_json = keeper_reaction_ledger_health_json () in
  Tool_args.ok_assoc [
    ("server", `String "masc-mcp");
    ("version", `String build.release_version);
    ("release_version", `String build.release_version);
    ("build", Build_identity.to_yojson build);
    ("health_detail", `String "full");
    ("protocol", protocol_json ~listener);
    ("transport", transport_json request);
    ("http_listener", Transport_metrics.http_listener_json ());
    ("paths", Server_base_path_diagnostics.to_yojson (health_path_diagnostics ()));
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
    ("fd_accountant", fd_accountant_snapshot_json ());
    ( "keeper_fleet_safety"
    , keeper_fleet_safety_health_json ~phase_counts
        ~paused_keepers_json );
    ("keeper_reaction_ledger", reaction_ledger_json);
    (* Paused-keeper visibility: a keeper with [meta.paused = true] does not
       run turns, and auto-paused keepers may no longer have a live registry
       entry. The dashboard "깨우기" button now auto-resumes paused keepers,
       but ops still need a quick count without scraping /metrics. List names
       so an operator can correlate with the cause encoded in their
       last_blocker_class. *)
    (key_paused_keepers, paused_keepers_json);
    ("cdal", cdal_health_json ());
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
}

let full_health_snapshot_ttl_sec = 2.0

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
  Float.max Env_config_runtime.Dashboard.full_health_refresh_timeout_sec
    Env_config_runtime.Dashboard.shell_timeout_sec
;;

let full_health_critical_failure_threshold =
  Env_config_runtime.Dashboard.full_health_critical_failure_threshold
;;

let full_health_refresh_interval_sec =
  Float.max 30.0 (full_health_refresh_timeout_sec +. 5.0)
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

let full_health_component_placeholder ?error ~status component =
  let error_fields =
    match error with
    | Some error -> [ ("error", `String error) ]
    | None -> []
  in
  `Assoc
    ([
       ("component", `String component);
       ("status", `String status);
       ("component_timed_out", `Bool false);
     ]
     @ error_fields)

let full_health_placeholder_fields ?error ?(status = "warming") () =
  [
    ( "feature_flags",
      full_health_component_placeholder ?error ~status "feature_flags" );
    ("keeper_fibers", `Int 0);
    ( "keeper_fd_pressure",
      full_health_component_placeholder ?error ~status "keeper_fd_pressure" );
    ( "fd_accountant",
      full_health_component_placeholder ?error ~status "fd_accountant" );
    ( "keeper_fleet_safety",
      full_health_component_placeholder ?error ~status "keeper_fleet_safety" );
    ( "keeper_reaction_ledger",
      full_health_component_placeholder ?error ~status "keeper_reaction_ledger" );
    ( "paused_keepers",
      `Assoc
        [
          ("status", `String status);
          ("count", `Int 0);
          ("names", `List []);
          ("component_timed_out", `Bool false);
        ] );
    ("cdal", full_health_component_placeholder ?error ~status "cdal");
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
  try
    let fields = cached_full_health_fields (make_health_json ~listener request) in
    let finished_at = Unix.gettimeofday () in
    {
      fields;
      computed_at = finished_at;
      duration_ms = duration_ms ~started_at ~finished_at;
      error = None;
      stale_since_ts = None;
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

let full_health_refresh_timeout_error error =
  String_util.contains_substring error "refresh_timeout label=full_health_snapshot"

let mark_full_health_snapshot_error exn =
  let now = Unix.gettimeofday () in
  let error = Printexc.to_string exn in
  with_full_health_snapshot_lock (fun () ->
      (* Partial degradation: preserve the last successful snapshot's
         per-component [fields] and overwrite only the [error] /
         [stale_since_ts] / refresh-bookkeeping signals.  If we have
         no prior snapshot (warm path on cold boot), fall back to the
         all-error placeholder so the field set stays well-typed. *)
      let preserved_fields, prior_stale_since =
        match !full_health_snapshot with
        | Some s when Option.is_none s.error ->
            (* Previous snapshot was clean — keep its component
               fields, this is a fresh failure so [stale_since_ts]
               starts at [now]. *)
            (s.fields, None)
        | Some s ->
            (* Previous snapshot was already an error placeholder —
               keep whatever [fields] it had (which may itself be
               preserved last-good data from an even earlier
               success) and DO NOT overwrite the [stale_since_ts]
               timestamp.  This pins [stale_since_ts] to the FIRST
               failure of the current outage. *)
            (s.fields, s.stale_since_ts)
        | None ->
            (* Cold boot — no prior snapshot.  Fall back to the
               original all-error placeholder behaviour. *)
            (full_health_placeholder_fields ~error ~status:"error" (), None)
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
            computed_at = now;
            duration_ms = 0;
            error = Some error;
            stale_since_ts;
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
  `Assoc
    [
      ("status", `String status);
      ("snapshot_age_ms", snapshot_age_ms);
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
    (full_health_refresh_interval_sec, full_health_refresh_timeout_sec)
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
