(** /health probe building blocks, extracted from
    [server_routes_http_runtime.ml] (godfile decomp).

    Small self-contained JSON+diagnostics helpers used by the
    [/health] probe response builder:

    - [server_start_time] — captured at sibling module init via
      [Unix.gettimeofday]. Operators see process uptime against
      this constant (NDT-OK: no scheduler decision depends on it).
    - [health_path_diagnostics] — resolves base-path inputs
      ([Host_config.from_env]) against effective config to surface
      mis-mapping in operator output. Falls back to
      [Common.masc_dir_from_base_path] when no server state is
      live (boot path).
    - [health_uptime_secs] — process uptime in seconds (int).
    - [health_uptime_string] — pretty-prints uptime as `<sec>s`,
      `<min>m <sec>s`, or `<hour>h <min>m`.
    - [protocol_json ~listener] — MCP protocol version negotiation
      summary keyed by listener.
    - [quick_gc_json] — operator-facing GC counter summary. Uses
      [Gc.quick_stat] (not [Gc.stat]) so health probes don't trigger
      a full major-cycle sync under live keeper load. *)

open Server_routes_http_common

let server_start_time = Unix.gettimeofday ()

let health_path_diagnostics () =
  match current_server_state_opt () with
  | Some state ->
      let config = Mcp_server.workspace_config state in
      Server_base_path_diagnostics.detect
        ?input_base_path:((Host_config.from_env ()).base_path_raw)
        ?env_masc_base_path:((Host_config.from_env ()).base_path_raw)
        ~effective_base_path:config.base_path
        ~effective_masc_root:(Workspace.masc_root_dir config)
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
  else if uptime_secs < Masc_time_constants.hour_int then
    Printf.sprintf "%dm %ds" (uptime_secs / 60) (uptime_secs mod 60)
  else
    Printf.sprintf
      "%dh %dm"
      (uptime_secs / Masc_time_constants.hour_int)
      ((uptime_secs mod Masc_time_constants.hour_int) / 60)

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
