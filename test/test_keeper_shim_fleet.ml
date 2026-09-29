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
      let result =
        try Keeper_shim_fleet.json ~config with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (Keeper_shim_fleet.Keeper_names_unread (Printexc.to_string exn))
      in
      match result with
      | Error (Keeper_shim_fleet.Keeper_names_unread _) -> ()
      | Error (Keeper_shim_fleet.Keeper_meta_unread _) ->
        fail "the census failed before any meta was read"
      | Ok _ -> fail "an unreadable census answered as a fleet")
;;

let () =
  run "Keeper shim fleet"
    [ ( "projection"
      , [ test_case "no keepers is an empty list" `Quick
            test_a_workspace_without_keepers_is_an_empty_list
        ; test_case "an unreadable census refuses the answer" `Quick
            test_an_unreadable_census_refuses_the_whole_answer
        ] )
    ]
;;
