open Alcotest

module KTP = Masc_mcp.Keeper_types_profile

(** Validate that every .toml file in config/keepers/ parses successfully
    with the OCaml TOML parser.  This catches syntax that is valid standard
    TOML but unsupported by our minimal parser (e.g. multi-line arrays before
    the fix).  Runs as part of [dune test], so CI will fail before deploy. *)

let test_all_keeper_tomls_parse () =
  let relative_config_dir = "config/keepers" in
  let config_dir =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some repo_root -> Filename.concat repo_root relative_config_dir
    | None -> relative_config_dir
  in
  if not (Sys.file_exists config_dir && Sys.is_directory config_dir) then
    fail
      (Printf.sprintf
         "Could not locate %s (resolved to %s)"
         relative_config_dir config_dir)
  else
    let files =
      Sys.readdir config_dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".toml")
      |> List.sort String.compare
    in
    check bool "at least one toml file" true (List.length files > 0);
    List.iter (fun f ->
      let path = Filename.concat config_dir f in
      match KTP.load_keeper_toml path with
      | Ok _ -> ()
      | Error e ->
        fail (Printf.sprintf "%s: %s" f e)
    ) files

let test_named_keeper_docker_defaults () =
  let config_dir =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some repo_root -> Filename.concat repo_root "config/keepers"
    | None -> "config/keepers"
  in
  let expect_keeper name =
    let path = Filename.concat config_dir (name ^ ".toml") in
    match KTP.load_keeper_toml path with
    | Error e -> fail (Printf.sprintf "%s: %s" name e)
    | Ok (_loaded_name, defaults) ->
        check (option string) (name ^ " persona_name") (Some name)
          defaults.persona_name;
        check (option string) (name ^ " sandbox_profile") (Some "docker")
          (Option.map KTP.sandbox_profile_to_string defaults.sandbox_profile);
        check (option string) (name ^ " network_mode") (Some "none")
          (Option.map KTP.network_mode_to_string defaults.network_mode)
  in
  List.iter expect_keeper [ "sangsu"; "sojin"; "verdict" ]

let () =
  run "Keeper TOML Config Validation"
    [
      ( "config/keepers",
        [
          test_case "all toml files parse" `Quick test_all_keeper_tomls_parse;
          test_case "named keepers default to docker" `Quick
            test_named_keeper_docker_defaults;
        ] );
    ]
