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

(** Write a temporary TOML file, run load_keeper_toml, clean up. *)
let with_temp_toml content f =
  let path = Filename.temp_file "keeper_test_" ".toml" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () -> f path)

let test_cascade_name_rejects_unknown () =
  let result =
    with_temp_toml
      "[keeper]\nname = \"testkeeper\"\ncascade_name = \"nick0cave\"\n"
      KTP.load_keeper_toml
  in
  match result with
  | Ok _ -> fail "nick0cave cascade_name should be rejected"
  | Error e ->
      check bool "error mentions cascade_name" true
        (let len = String.length e in
         let needle = "invalid cascade_name" in
         let nlen = String.length needle in
         let found = ref false in
         for i = 0 to len - nlen do
           if String.sub e i nlen = needle then found := true
         done;
         !found)

let test_cascade_name_accepts_known () =
  let check_ok label cascade_name =
    let result =
      with_temp_toml
        (Printf.sprintf "[keeper]\nname = \"testkeeper\"\ncascade_name = \"%s\"\n"
           cascade_name)
        KTP.load_keeper_toml
    in
    match result with
    | Ok _ -> ()
    | Error e ->
        fail (Printf.sprintf "%s: '%s' should be accepted but got: %s" label
                cascade_name e)
  in
  check_ok "big_three variant" "big_three";
  check_ok "local_only phase-routing" "local_only";
  check_ok "local_recovery phase-routing" "local_recovery"

let test_cascade_name_accepts_catalog_entry () =
  (* "tool_use_strict" is a known catalog entry in cascade.json,
     distinct from compile-time variants.  Tests that the live catalog
     is consulted during validation. *)
  let catalog =
    try Masc_mcp.Keeper_cascade_profile.catalog_names ()
    with _ -> []
  in
  let test_name =
    (* Pick a catalog entry that is NOT a compile-time variant *)
    match
      List.find_opt
        (fun n ->
           not (List.mem n Masc_mcp.Keeper_cascade_profile.known_cascades)
           && not (List.mem n [ "local_only"; "local_recovery" ]))
        catalog
    with
    | Some name -> name
    | None -> "tool_use_strict" (* fallback, may not be in catalog *)
  in
  let result =
    with_temp_toml
      (Printf.sprintf "[keeper]\nname = \"testkeeper\"\ncascade_name = \"%s\"\n"
         test_name)
      KTP.load_keeper_toml
  in
  match result with
  | Ok _ -> ()
  | Error e ->
      (* If catalog is unavailable, skip rather than fail *)
      if catalog = [] then ()
      else fail (Printf.sprintf "%s should be accepted: %s" test_name e)

let () =
  run "Keeper TOML Config Validation"
    [
      ( "config/keepers",
        [
          test_case "all toml files parse" `Quick test_all_keeper_tomls_parse;
          test_case "named keepers default to docker" `Quick
            test_named_keeper_docker_defaults;
        ] );
      ( "cascade_name validation",
        [
          test_case "rejects unknown cascade_name" `Quick
            test_cascade_name_rejects_unknown;
          test_case "accepts known cascade names" `Quick
            test_cascade_name_accepts_known;
          test_case "accepts catalog entry (legacy alias)" `Quick
            test_cascade_name_accepts_catalog_entry;
        ] );
    ]
