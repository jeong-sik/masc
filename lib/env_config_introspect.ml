(** Env_config_introspect — root-level config introspection wrapper.

    The canonical category definitions, masking rules, and source attribution
    live in [Env_config_snapshot] inside the [masc_config] sub-library. This
    wrapper adds root-runtime metadata that is only available from the main
    server library, which already depends on [masc_mcp.config] in [lib/dune]. *)

let server_meta () =
  let git_commit =
    match Sys.getenv_opt "MASC_BUILD_GIT_COMMIT" with
    | Some c when String.trim c <> "" -> Some (String.trim c)
    | _ -> None
  in
  `Assoc
    [ "version", `String Version.version
    ; "git_commit", Json_util.string_opt_to_json git_commit
    ; "ocaml_version", `String Sys.ocaml_version
    ; "uptime_seconds", `Float (Server_startup_state.elapsed_since_start ())
    ; "pid", `Int (Unix.getpid ())
    ]
;;

let to_json () =
  Env_config_snapshot.to_json
    ~server_meta:(server_meta ())
    ~generated_at:(Types.now_iso ())
    ()
;;

let to_json_filtered ?cat () =
  Env_config_snapshot.to_json
    ?cat
    ~server_meta:(server_meta ())
    ~generated_at:(Types.now_iso ())
    ()
;;
