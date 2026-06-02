open Alcotest

(** RFC-0085 PR-6 — Verify Host_config exposes env-derived path fields
    so Config_dir_resolver and other callers can route through
    [Host_config.from_env ()] instead of importing
    [Env_config_core.base_path_raw_opt] / [config_dir_opt] /
    [personas_dir_opt] / [normalize_masc_base_path_input] directly.

    Phase 1 (this PR): introduce the surface.  Phase 2 (follow-up PR)
    migrates [Config_dir_resolver] callers and deletes the
    [Env_config_core] path-related exports. *)

let with_env key value f =
  let original = Sys.getenv_opt key in
  (match value with
   | Some v -> Unix.putenv key v
   | None ->
     (* Best-effort unset by setting to empty; host () trims so this acts
        as None on the read path. *)
     Unix.putenv key "");
  let restore () =
    match original with
    | Some v -> Unix.putenv key v
    | None -> Unix.putenv key ""
  in
  Fun.protect ~finally:restore f
;;

let test_base_path_field_reads_env () =
  with_env "MASC_BASE_PATH" (Some "/some/base/path") (fun () ->
    let h = Host_config.host () in
    check (option string) "base_path field reflects env" (Some "/some/base/path") h.base_path)
;;

let test_config_dir_field_reads_env () =
  with_env "MASC_CONFIG_DIR" (Some "/etc/masc") (fun () ->
    let h = Host_config.host () in
    check (option string) "config_dir field reflects env" (Some "/etc/masc") h.config_dir)
;;

let test_data_dir_field_reads_env () =
  with_env "MASC_DATA_DIR" (Some "/var/lib/masc") (fun () ->
    let h = Host_config.host () in
    check (option string) "data_dir field reflects env" (Some "/var/lib/masc") h.data_dir)
;;

let test_personas_dir_field_reads_env () =
  with_env "MASC_PERSONAS_DIR" (Some "/etc/masc/personas") (fun () ->
    let h = Host_config.host () in
    check
      (option string)
      "personas_dir field reflects env"
      (Some "/etc/masc/personas")
      h.personas_dir)
;;

let test_empty_env_yields_none () =
  with_env "MASC_BASE_PATH" (Some "") (fun () ->
    let h = Host_config.host () in
    check (option string) "empty MASC_BASE_PATH -> None" None h.base_path)
;;

let test_from_env_is_alias_for_host () =
  (* from_env should produce an equal record to host () when env is the same. *)
  let h1 = Host_config.host () in
  let h2 = Host_config.from_env () in
  check bool "from_env equals host ()" true (Host_config.equal h1 h2)
;;

let () =
  run
    "rfc-0085-pr-6-host-config-from-env"
    [ ( "env-derived fields"
      , [ test_case "base_path" `Quick test_base_path_field_reads_env
        ; test_case "config_dir" `Quick test_config_dir_field_reads_env
        ; test_case "data_dir" `Quick test_data_dir_field_reads_env
        ; test_case "personas_dir" `Quick test_personas_dir_field_reads_env
        ] )
    ; ( "empty env semantics"
      , [ test_case "empty -> None" `Quick test_empty_env_yields_none ] )
    ; ( "surface aliases"
      , [ test_case "from_env = host ()" `Quick test_from_env_is_alias_for_host ] )
    ]
;;
