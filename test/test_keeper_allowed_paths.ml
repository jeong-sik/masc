open Alcotest

module KAP = Masc_mcp.Keeper_alerting_path
module KT = Masc_mcp.Keeper_types
module KTU = Masc_mcp.Keeper_turn_up_args

let make_meta ?(allowed_paths = []) ~name () =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "test");
        ("allowed_paths", `List (List.map (fun path -> `String path) allowed_paths));
      ]
  in
  match KT.meta_of_json json with
  | Ok meta -> meta
  | Error err -> fail ("make_meta: " ^ err)

let sandbox_roots name =
  [ KAP.sandbox_path_of_keeper name ]

let with_temp_dir prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect
    ~finally:(fun () ->
      let rec rm dir =
        if Sys.file_exists dir then
          if Sys.is_directory dir then begin
            Sys.readdir dir |> Array.iter (fun name -> rm (Filename.concat dir name));
            Unix.rmdir dir
          end else
            Sys.remove dir
      in
      rm path)
    (fun () -> f path)

let with_temp_config f =
  with_temp_dir "keeper_allowed_paths_" (fun dir ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    f (Masc_mcp.Coord.default_config dir))

let test_empty_paths_default_to_sandbox_root () =
  let meta = make_meta ~name:"keeper" () in
  check (list string) "default read paths" (sandbox_roots "keeper")
    (KAP.effective_allowed_paths ~meta);
  check (list string) "default write paths" (sandbox_roots "keeper")
    (KAP.effective_write_allowed_paths ~meta)

let test_explicit_paths_append_to_sandbox_root () =
  let meta = make_meta ~name:"keeper" ~allowed_paths:["src/"; "docs/"] () in
  let expected = sandbox_roots "keeper" @ [ "src/"; "docs/" ] in
  check (list string) "read paths append explicit entries" expected
    (KAP.effective_allowed_paths ~meta);
  check (list string) "write paths append explicit entries" expected
    (KAP.effective_write_allowed_paths ~meta)

let test_playground_path_sanitizes_name () =
  let path = KAP.playground_path_of_keeper "my keeper/../../etc" in
  check string "special chars sanitized"
    ".masc/playground/my_keeper_.._.._etc/" path

let test_validate_rejects_star_wildcard () =
  with_temp_config (fun config ->
    match
      KTU.validate_sandbox_settings
        ~config
        ~keeper_name:"keeper"
        ~sandbox_profile:KT.Local
        ~network_mode:KT.Network_inherit
        ~allowed_paths:["*"]
    with
    | Ok () -> fail "expected wildcard rejection"
    | Error err ->
        check string "explicit rejection message"
          "allowed_paths=[\"*\"] is not supported; enumerate explicit paths instead"
          err)

let test_validate_local_rejects_network_none () =
  with_temp_config (fun config ->
    match
      KTU.validate_sandbox_settings
        ~config
        ~keeper_name:"keeper"
        ~sandbox_profile:KT.Local
        ~network_mode:KT.Network_none
        ~allowed_paths:[]
    with
    | Ok () -> fail "expected local network_mode rejection"
    | Error err ->
        check string "local requires inherit"
          "network_mode=none requires sandbox_profile=docker"
          err)

let test_validate_docker_allows_private_root_paths () =
  with_temp_config (fun config ->
    let allowed =
      [
        Masc_mcp.Keeper_turn_up_args.private_workspace_root_rel ~sandbox_profile:KT.Docker
          "keeper";
      ]
    in
    match
      KTU.validate_sandbox_settings
        ~config
        ~keeper_name:"keeper"
        ~sandbox_profile:KT.Docker
        ~network_mode:KT.Network_none
        ~allowed_paths:allowed
    with
    | Ok () -> ()
    | Error err -> fail ("expected docker private root to validate: " ^ err))

let test_validate_docker_rejects_paths_outside_private_root () =
  with_temp_config (fun config ->
    match
      KTU.validate_sandbox_settings
        ~config
        ~keeper_name:"keeper"
        ~sandbox_profile:KT.Docker
        ~network_mode:KT.Network_inherit
        ~allowed_paths:["workspace/outside"]
    with
    | Ok () -> fail "expected docker path rejection"
    | Error err ->
        check bool "error mentions rejected path" true
          (String.contains err 'w'))

let () =
  run "Keeper_allowed_paths"
    [
      ( "effective_paths",
        [
          test_case "empty paths default to sandbox root" `Quick
            test_empty_paths_default_to_sandbox_root;
          test_case "explicit paths append to sandbox root" `Quick
            test_explicit_paths_append_to_sandbox_root;
          test_case "playground path sanitizes name" `Quick
            test_playground_path_sanitizes_name;
        ] );
      ( "validation",
        [
          test_case "rejects wildcard full access" `Quick
            test_validate_rejects_star_wildcard;
          test_case "local rejects network none" `Quick
            test_validate_local_rejects_network_none;
          test_case "docker allows private root paths" `Quick
            test_validate_docker_allows_private_root_paths;
          test_case "docker rejects paths outside private root" `Quick
            test_validate_docker_rejects_paths_outside_private_root;
        ] );
    ]
