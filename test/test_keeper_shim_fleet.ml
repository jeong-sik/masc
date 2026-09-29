open Alcotest
open Masc

let with_workspace f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun _sw ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "keeper-shim-fleet-" "" in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      Workspace.invalidate_initialized_cache ();
      Fs_compat.remove_tree base_path;
      Fs_compat.clear_fs ())
    (fun () ->
      let state = Mcp_server.For_testing.create_state ~base_path in
      let config = Mcp_server.workspace_config state in
      ignore (Workspace.init config ~agent_name:None);
      Fs_compat.mkdir_p (Workspace.keepers_runtime_dir config);
      Server_auth.For_testing.restore_server_state (Some state);
      f config)
;;

(* An empty keeper directory is a complete read: the answer is the server's
   release and an empty list, not an error and not a missing key. *)
let test_a_workspace_without_keepers_is_an_empty_list () =
  with_workspace @@ fun config ->
  match Keeper_shim_fleet.json ~config with
  | Error error -> fail (Keeper_shim_fleet.error_detail error)
  | Ok json ->
    let member name = Yojson.Safe.Util.member name json in
    check string "the server's own release" Build_version.current
      (Yojson.Safe.Util.to_string (member "server_release"));
    check int "no keepers, no rows" 0
      (List.length (Yojson.Safe.Util.to_list (member "keepers")))
;;

(* A keeper directory that cannot be read must not read as an empty fleet. A
   file at the directory path fails the real census deterministically. *)
let test_an_unreadable_census_refuses_the_whole_answer () =
  with_workspace @@ fun config ->
  let path = Workspace.keepers_runtime_dir config in
  let retained = path ^ ".fixture-retained" in
  Unix.rename path retained;
  Out_channel.with_open_bin path (fun out -> output_string out "not a directory");
  Fun.protect
    ~finally:(fun () ->
      Sys.remove path;
      Unix.rename retained path)
    (fun () ->
      let result = Keeper_shim_fleet.json ~config in
      match result with
      | Error (Keeper_shim_fleet.Keeper_names_unread _) -> ()
      | Error (Keeper_shim_fleet.Keeper_meta_unread _) ->
        fail "the census failed before any meta was read"
      | Ok _ -> fail "an unreadable census answered as a fleet")
;;

let save path bytes =
  Out_channel.with_open_bin path (fun out -> output_string out bytes)
;;

let meta_path config name =
  Filename.concat (Workspace.keepers_runtime_dir config) (name ^ ".json")
;;

let persist_meta config name =
  let json = Masc_test_deps.current_meta_json_fixture ~name () in
  save (meta_path config name) (Yojson.Safe.to_string json)
;;

let declare config name profile extra =
  let dir = Filename.concat config.Workspace.base_path ".masc/config/keepers" in
  Fs_compat.mkdir_p dir;
  save (Filename.concat dir (name ^ ".toml"))
    (Printf.sprintf
       "[keeper]\ninstructions = \"fleet fixture\"\nsandbox_profile = %S\nsandbox_image = %S\n%s"
       profile Keeper_sandbox_image_version.base_embedded.name extra)
;;

let fleet config =
  match Keeper_shim_fleet.json ~config with
  | Error error -> fail (Keeper_shim_fleet.error_detail error)
  | Ok json -> Yojson.Safe.Util.(member "keepers" json |> to_list)
;;

let field = Yojson.Safe.Util.member
let string_field name json = Yojson.Safe.Util.to_string (field name json)

let endpoint : Exec_ssh_endpoint.t =
  { name = "fleet-box"; host = "fleet.invalid"; user = "masc"; port = 22
  ; identity_file = ".masc/ssh/key"; known_hosts_file = ".masc/ssh/known-hosts"
  ; remote_root = "/srv/masc"; connect_timeout_sec = 1
  ; max_concurrent_sessions = 1; env_allowlist = []; capabilities = []
  ; private_home = false; allowed_paths = [] }
;;

let test_profiles_are_sorted_without_probing_or_preparing_ssh () =
  with_workspace @@ fun config ->
  List.iter (persist_meta config) [ "z-ssh"; "a-docker"; "m-guest" ];
  declare config "a-docker" "docker" "";
  declare config "m-guest" "microvm" "microvm_backend = \"apple_container\"\n";
  declare config "z-ssh" "remote_ssh" "remote_endpoint = \"fleet-box\"\n";
  save (Filename.concat config.base_path ".masc/config/runtime.toml")
    (Exec_ssh_endpoint.to_toml endpoint);
  let marker = Filename.concat config.base_path "ssh-was-executed" in
  let stub = Filename.concat config.base_path "ssh-stub" in
  save stub (Printf.sprintf "#!/bin/sh\ntouch %s\nexit 1\n" (Filename.quote marker));
  Unix.chmod stub 0o700;
  Keeper_sandbox_ssh.For_testing.set_ssh_bin_override (Some stub);
  Fun.protect
    ~finally:(fun () -> Keeper_sandbox_ssh.For_testing.set_ssh_bin_override None)
    (fun () ->
      Masc_test_deps.with_process_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" (Some "true")
        (fun () ->
          let control_dir = Config_dir_resolver.run_ssh_dir ~base_path:config.base_path in
          check bool "no control directory before the read" false (Sys.file_exists control_dir);
          let rows = fleet config in
          check (list string) "sorted persisted owners" [ "a-docker"; "m-guest"; "z-ssh" ]
            (List.map (string_field "keeper") rows);
          (match rows with
           | [ docker; guest; ssh ] ->
             check bool "docker has no shim" true (field "probe" docker = `Null);
             check string "guest lane" "microvm_remote" (string_field "lane" guest);
             check string "guest not asked" "not_asked" (string_field "state" (field "probe" guest));
             check string "SSH lane" "remote_ssh" (string_field "lane" ssh);
             check string "SSH not asked" "not_asked" (string_field "state" (field "probe" ssh));
             check string "SSH endpoint" endpoint.name (string_field "endpoint" ssh)
           | _ -> fail "one row per persisted owner");
          check bool "no SSH command executed" false (Sys.file_exists marker);
          check bool "no SSH control directory created" false (Sys.file_exists control_dir)))
;;

let test_absent_store_is_not_created () =
  with_workspace @@ fun config ->
  let path = Workspace.keepers_runtime_dir config in
  Unix.rmdir path;
  check int "absent store is empty" 0 (List.length (fleet config));
  check bool "read did not create the store" false (Sys.file_exists path)
;;

let test_bad_meta_refuses_without_repair () =
  with_workspace @@ fun config ->
  persist_meta config "healthy";
  declare config "healthy" "docker" "";
  let json = Masc_test_deps.current_meta_json_fixture ~name:"broken" () in
  let off_canon =
    match json with
    | `Assoc fields ->
      `Assoc (("last_proactive_outcome", `String "not-one-of-the-outcomes")
              :: List.remove_assoc "last_proactive_outcome" fields)
    | _ -> fail "fixture must be an object"
  in
  let path = meta_path config "broken" in
  List.iter
    (fun bytes ->
      save path bytes;
      (match Keeper_shim_fleet.json ~config with
       | Error (Keeper_shim_fleet.Keeper_meta_unread { keeper = "broken"; _ }) -> ()
       | Error error -> fail (Keeper_shim_fleet.error_detail error)
       | Ok _ -> fail "bad metadata cannot produce a partial fleet");
      check string "metadata bytes unchanged" bytes
        (In_channel.with_open_bin path In_channel.input_all))
    [ Yojson.Safe.to_string off_canon; "{not json" ]
;;

let test_metadata_owner_must_match_its_filename () =
  with_workspace @@ fun config ->
  save (meta_path config "claimed")
    (Yojson.Safe.to_string (Masc_test_deps.current_meta_json_fixture ~name:"other" ()));
  match Keeper_shim_fleet.json ~config with
  | Error (Keeper_shim_fleet.Keeper_meta_unread { keeper = "claimed"; _ }) -> ()
  | Error error -> fail (Keeper_shim_fleet.error_detail error)
  | Ok _ -> fail "a file cannot claim another keeper's endpoint"
;;

let () =
  run "Keeper shim fleet"
    [ ( "projection"
      , [ test_case "no keepers is an empty list" `Quick
            test_a_workspace_without_keepers_is_an_empty_list
        ; test_case "an unreadable census refuses the answer" `Quick
            test_an_unreadable_census_refuses_the_whole_answer
        ; test_case "profiles are observations, not SSH preparation" `Quick
            test_profiles_are_sorted_without_probing_or_preparing_ssh
        ; test_case "absent store is not created" `Quick test_absent_store_is_not_created
        ; test_case "bad metadata is refused without repair" `Quick test_bad_meta_refuses_without_repair
        ; test_case "metadata owner matches filename" `Quick test_metadata_owner_must_match_its_filename
        ] )
    ]
;;
