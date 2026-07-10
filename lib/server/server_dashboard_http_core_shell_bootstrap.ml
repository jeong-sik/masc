(** Dashboard shell bootstrap + paths JSON helpers, extracted from
    [server_dashboard_http_core.ml] (godfile decomp).

    Two helpers shipped as a bundle because [dashboard_shell_bootstrap_json]
    embeds the [dashboard_shell_paths_json] result, and both are the
    pre-warm path for the operator dashboard's shell surface:

    - [dashboard_shell_paths_json config] — discovers the resolution of
      the operator's base path through
      [Server_base_path_diagnostics.detect], threading both the
      env-resolved [Host_config.from_env ()] inputs and the
      effective config-derived paths. Returns the canonical
      diagnostics record as JSON.

    - [dashboard_shell_bootstrap_json config] — the "initializing"
      payload returned by the shell surface before any keeper data
      is available. Pins `project="initializing"`, zero counts for
      agents/tasks/keepers/total_runtimes, empty providers map, and
      null config_resolution/runtime_resolution. The
      caller wraps via [with_projection_diagnostics] tagged
      `surface="shell"` with `cache_state="initializing"` and
      `bootstrap_source="shell_prewarm"`. *)

let dashboard_shell_paths_json (config : Workspace.config) : Yojson.Safe.t =
  Server_base_path_diagnostics.detect
    ?input_base_path:((Host_config.from_env ()).base_path_raw)
    ?env_masc_base_path:((Host_config.from_env ()).base_path_raw)
    ~effective_base_path:config.base_path
    ~effective_masc_root:(Workspace.masc_root_dir config)
    ()
  |> Server_base_path_diagnostics.to_yojson
;;

let dashboard_shell_bootstrap_json (config : Workspace.config) : Yojson.Safe.t =
  let generated_at = Masc_domain.now_iso () in
  let started_at = Unix.gettimeofday () in
  `Assoc
    [ "generated_at", `String generated_at
    ; ( "status"
      , `Assoc [ "project", `String "initializing"; "generated_at", `String generated_at ]
      )
    ; "paths", dashboard_shell_paths_json config
    ; ( "counts"
      , `Assoc
          [ "agents", `Int 0
          ; "tasks", `Int 0
          ; "keepers", `Int 0
          ; "total_runtimes", `Int 0
          ] )
    ; "configured_keepers", `Int 0
    ; "providers", `Assoc []
    ; "config_resolution", `Null
    ; "runtime_resolution", `Null
    ]
  |> Server_dashboard_http_core_cache.with_projection_diagnostics
       ~surface:"shell"
       ~started_at
       ~extra:
         [ "cache_state", `String "initializing"
         ; "bootstrap_source", `String "shell_prewarm"
         ]
;;
