open Alcotest

module KAP = Masc_mcp.Keeper_alerting_path
module KT = Masc_mcp.Keeper_types
module KTU = Masc_mcp.Keeper_turn_up_args
module KGH = Masc_mcp.Keeper_gh_env

let make_meta ?(allowed_paths = []) ~name () =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "test");
        ("sandbox_profile", `String "local");
        ("network_mode", `String "inherit");
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

let with_env key value f =
  let prior = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let with_temp_config f =
  with_temp_dir "keeper_allowed_paths_" (fun dir ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    f (Masc_mcp.Coord.default_config dir))

let ensure_dir path =
  let rec loop p =
    if p = "" || p = "." || p = "/" then ()
    else if Sys.file_exists p then ()
    else (
      loop (Filename.dirname p);
      Unix.mkdir p 0o755)
  in
  loop path

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  n_len = 0 || loop 0

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
        ~github_identity:None
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
        ~github_identity:None
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
        ~github_identity:None
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
        ~github_identity:None
        ~sandbox_profile:KT.Docker
        ~network_mode:KT.Network_inherit
        ~allowed_paths:["workspace/outside"]
    with
    | Ok () -> fail "expected docker path rejection"
    | Error err ->
        check bool "error mentions rejected path" true
          (String.contains err 'w'))

let test_hard_mode_requires_docker_none_identity () =
  with_env "MASC_KEEPER_SANDBOX_HARD_MODE" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_RELAX_FS" "false" @@ fun () ->
  with_temp_config (fun config ->
    let validate ~github_identity ~sandbox_profile ~network_mode () =
      KTU.validate_sandbox_settings
        ~config
        ~keeper_name:"keeper"
        ~github_identity
        ~sandbox_profile
        ~network_mode
        ~allowed_paths:[]
    in
    (match
       validate ~github_identity:None
         ~sandbox_profile:KT.Local ~network_mode:KT.Network_inherit ()
     with
     | Ok () -> fail "expected hard mode to reject local profile"
     | Error err ->
         check string "requires docker"
           "MASC_KEEPER_SANDBOX_HARD_MODE requires sandbox_profile=docker"
           err);
    (match
       validate ~github_identity:(Some "anyang-keepers")
         ~sandbox_profile:KT.Docker ~network_mode:KT.Network_inherit ()
     with
     | Ok () -> fail "expected hard mode to reject network inherit"
     | Error err ->
         check string "requires network none"
           "MASC_KEEPER_SANDBOX_HARD_MODE requires network_mode=none; git/gh egress is brokered by structured tools"
           err);
    (match
       validate ~github_identity:None
         ~sandbox_profile:KT.Docker ~network_mode:KT.Network_none ()
     with
     | Ok () -> fail "expected hard mode to reject missing github_identity"
     | Error err ->
         check bool "requires effective identity" true
           (contains_substring err "effective GitHub identity");
         check bool "points at root bundle" true
           (contains_substring err "github-identities/root/gh"));
    ensure_dir (KGH.root_gh_config_dir config);
    (match
       validate ~github_identity:None
         ~sandbox_profile:KT.Docker ~network_mode:KT.Network_none ()
     with
     | Ok () -> ()
     | Error err -> fail ("expected root fallback to validate: " ^ err));
    (match
       validate ~github_identity:(Some "anyang-keepers")
         ~sandbox_profile:KT.Docker ~network_mode:KT.Network_none ()
     with
     | Ok () -> ()
     | Error err -> fail ("expected hard mode settings to validate: " ^ err)))

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
          test_case "hard mode requires docker none identity" `Quick
            test_hard_mode_requires_docker_none_identity;
        ] );
    ]
