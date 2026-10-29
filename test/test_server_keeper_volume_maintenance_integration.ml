open Alcotest
open Masc

module Fs = Keeper_volume_filesystem
module Watch = Keeper_volume_filesystem_watch
module Sweep = Server_keeper_volume_maintenance

(* Stop only the periodic observer after its first complete sweep. The service
   switch still joins any children the sweep may have forked. *)
exception First_sweep_finished

module One_sweep_clock = struct
  type t = unit
  type time = float

  let now () = 0.
  let sleep_until () _ = raise First_sweep_finished
end

let one_sweep_clock : float Eio.Time.clock_ty Eio.Resource.t =
  Eio.Resource.T ((), Eio.Time.Pi.clock (module One_sweep_clock))
;;

let write_file path body =
  Out_channel.with_open_bin path (fun channel -> output_string channel body)
;;

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.unsetenv name
;;

let volume_name kind keeper =
  let result =
    match kind with
    | Watch.Work -> Keeper_sandbox_microvm.work_volume_name ~keeper_name:keeper
    | Watch.Build -> Keeper_sandbox_microvm.build_volume_name ~keeper_name:keeper
  in
  match result with Ok name -> name | Error detail -> fail detail
;;

let image_bytes ~damaged =
  let start = Fs.superblock_offset in
  let bytes = Bytes.make (start + Fs.superblock_size) '\000' in
  Bytes.set_uint16_le bytes (start + 0x38) 0xEF53;
  Bytes.set_uint16_le bytes (start + 0x3A) (if damaged then 0x0002 else 0x0001);
  if damaged then Bytes.set_int32_le bytes (start + 0x194) 1l;
  Bytes.to_string bytes
;;

let inspect_json name source =
  Yojson.Safe.to_string
    (`List
       [ `Assoc
           [ "configuration",
             `Assoc
               [ "name", `String name; "format", `String "ext4"; "source", `String source ]
           ]
       ])
;;

let fake_container ~bin ~calls volumes =
  let path = Filename.concat bin "container" in
  Out_channel.with_open_bin path (fun out ->
    Printf.fprintf out "#!/bin/sh\nprintf '%%s\\n' \"$*\" >> %s\ncase \"$*\" in\n"
      (Filename.quote calls);
    List.iter
      (fun (name, source, _) ->
         Printf.fprintf out "  %s) printf '%%s\\n' %s ;;\n"
           (Filename.quote ("volume inspect " ^ name))
           (Filename.quote (inspect_json name source)))
      volumes;
    output_string out "  *) exit 91 ;;\nesac\n");
  Unix.chmod path 0o700
;;

let seed_keeper config ~keepers_dir name =
  write_file (Filename.concat keepers_dir (name ^ ".toml"))
    "[keeper]\ninstructions = \"Observe the isolated fixture.\"\nsandbox_profile = \"microvm\"\nmicrovm_backend = \"apple_container\"\nsandbox_image = \"fixture-image\"\n";
  let meta =
    match Masc_test_deps.meta_of_json_fixture
            (`Assoc [ "name", `String name; "trace_id", `String ("trace-" ^ name) ]) with
    | Ok meta -> meta
    | Error detail -> fail detail
  in
  match Keeper_meta_store.replace_snapshot config meta with
  | Ok () -> ()
  | Error detail -> fail detail
;;

let test_running_sweep_does_not_mutate_volumes () =
  Eio_main.run @@ fun env ->
  let base = Filename.temp_dir ~temp_dir:"/tmp" "keeper-volume-observation-" "" in
  let bin = Filename.concat base "bin" in
  let config_dir = Filename.concat base ".masc/config" in
  let keepers_dir = Filename.concat config_dir "keepers" in
  let calls = Filename.concat base "container-calls" in
  let env_names = [ "PATH"; "MASC_BASE_PATH"; "MASC_CONFIG_DIR" ] in
  let old_env = List.map (fun name -> name, Sys.getenv_opt name) env_names in
  let old_fs = Fs_compat.get_fs_opt () in
  let process_installed = ref false in
  Fun.protect
    ~finally:(fun () ->
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ();
      Fun.protect
        ~finally:(fun () ->
          if !process_installed then Process_eio.reset_for_testing ();
          (match old_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ());
          List.iter (fun (name, value) -> restore_env name value) old_env;
          Config_dir_resolver.reset ())
        (fun () -> Fs_compat.remove_tree base))
    (fun () ->
      Unix.mkdir bin 0o700;
      Unix.putenv "PATH" bin;
      Unix.putenv "MASC_BASE_PATH" base;
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Config_dir_resolver.reset ();
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      if Process_eio.is_initialized () then fail "fixture requires a fresh process runtime";
      Process_eio.init ~cwd_default:(Eio.Stdenv.cwd env)
        ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
      process_installed := true;
      let resolved = Workspace.resolve_masc_base_path base in
      check string "workspace resolution stays in the isolated fixture"
        (Unix.realpath base) (Unix.realpath resolved);
      let config = Workspace.default_config base in
      check string "workspace config stays in the isolated fixture"
        (Unix.realpath base) (Unix.realpath config.base_path);
      ignore (Workspace.init config ~agent_name:None : string);
      Fs_compat.mkdir_p keepers_dir;
      let work_keeper = "volume-observe-work" in
      let build_keeper = "volume-observe-build" in
      let backup_keeper = "volume-observe-backup" in
      let fixture_keepers = [ work_keeper; build_keeper; backup_keeper ] in
      List.iter (seed_keeper config ~keepers_dir) fixture_keepers;
      let specs =
        [ work_keeper, Watch.Work, true
        ; work_keeper, Watch.Build, false
        ; build_keeper, Watch.Work, false
        ; build_keeper, Watch.Build, true
        ; backup_keeper, Watch.Work, true
        ; backup_keeper, Watch.Build, false
        ]
      in
      let volumes =
        List.map
          (fun (keeper, kind, damaged) ->
             let name = volume_name kind keeper in
             let image = Filename.concat base (name ^ ".img") in
             let bytes = image_bytes ~damaged in
             write_file image bytes;
             name, image, bytes)
          specs
      in
      let backup_image =
        Filename.concat base (volume_name Watch.Work backup_keeper ^ ".img")
      in
      let backup_path = backup_image ^ ".pre-repair" in
      let backup_bytes = "previous repair backup\000retained\n" in
      write_file backup_path backup_bytes;
      write_file calls "";
      fake_container ~bin ~calls volumes;
      check string "Board persistence stays in the isolated workspace"
        (Unix.realpath (Workspace.masc_dir config))
        (Unix.realpath (Filename.dirname (Board.persist_path ())));
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ();
      Board_dispatch.init_jsonl ();
      Eio.Switch.run (fun owners_sw ->
        (match Keeper_owner_registry.install_from_store ~sw:owners_sw
                 ~operation_runner:None ~on_turn_slot_released:None config with
         | Ok count -> check int "all fixture owners installed" 3 count
         | Error error -> fail (Keeper_owner_registry.install_error_to_string error));
        List.iter
          (fun keeper ->
             match Keeper_owner_registry.run_maintenance_if_idle ~defer_to_chat:true
                     ~base_path:base ~keeper_name:keeper (fun () -> ()) with
             | Ok (`Ran ()) -> ()
             | Ok (`Busy _) -> fail "fixture owner is not idle"
             | Error error -> fail (Keeper_owner_registry.command_error_to_string error))
          fixture_keepers;
        let owners =
          List.map
            (fun keeper ->
               match Keeper_owner_registry.get ~base_path:base ~keeper_name:keeper with
               | Ok owner -> keeper, owner
               | Error error -> fail (Keeper_owner_registry.lookup_error_to_string error))
            fixture_keepers
        in
        let maintenance_admissions = ref [] in
        Keeper_owner.For_testing.observe_state_changes ~sw:owners_sw (fun () ->
          List.iter
            (fun (keeper, owner) ->
               match Keeper_owner.turn_in_flight owner with
               | Some { lane = Keeper_owner.Maintenance; _ } ->
                 maintenance_admissions := keeper :: !maintenance_admissions
               | Some { lane = Keeper_owner.Autonomous | Keeper_owner.Chat_operation; _ }
               | None -> ())
            owners);
        Eio.Switch.run (fun service_sw ->
          Sweep.start ~sw:service_sw ~clock:one_sweep_clock ~config);
        check (list string) "no Owner maintenance admitted during the sweep"
          [] !maintenance_admissions);
      let posts = Board_dispatch.list_posts ~limit:20 () in
      check int "one actual Board post per damaged volume" 3 (List.length posts);
      let post_ids posts =
        List.map (fun (post : Board.post) -> Board.Post_id.to_string post.id) posts
        |> List.sort String.compare
      in
      let recorded_ids = post_ids posts in
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ();
      Board_dispatch.init_jsonl ();
      check (list string) "damage notices survive a Board reload" recorded_ids
        (post_ids (Board_dispatch.list_posts ~limit:20 ()));
      List.iter
        (fun (keeper, kind, damaged) ->
           let name = volume_name kind keeper in
           (match Watch.latest ~volume:name with
            | Some { result = Ok { state = Fs.Errors_recorded { count = 1; _ }; _ }; _ }
              when damaged -> ()
            | Some { result = Ok { state = Fs.Clean; _ }; _ } when not damaged -> ()
            | Some _ | None -> fail ("unexpected observation for " ^ name));
           if damaged then (
             let found =
               List.filter
                 (fun (post : Board.post) ->
                    Option.fold ~none:false
                      ~some:(fun meta -> Yojson.Safe.Util.member "volume" meta = `String name)
                      post.meta_json)
                 posts
             in
             match found with
             | [ post ] ->
               check bool "Board notice names paused automatic repair" true
                 (Astring.String.is_infix ~affix:"does not start automatic" post.body)
             | _ -> fail ("missing or duplicate Board notice for " ^ name)))
        specs;
      let actual =
        In_channel.with_open_bin calls In_channel.input_all
        |> String.split_on_char '\n'
        |> List.filter (fun line -> not (String.equal line ""))
        |> List.sort String.compare
      in
      let expected =
        List.map (fun (name, _, _) -> "volume inspect " ^ name) volumes
        |> List.sort String.compare
      in
      check (list string) "the fake runtime received only volume inspections" expected actual;
      List.iter
        (fun (_, image, before) ->
           check string "image bytes stayed unchanged" before
             (In_channel.with_open_bin image In_channel.input_all);
           let path = image ^ ".pre-repair" in
           if String.equal path backup_path
           then (
             check bool "previous repair backup remains" true (Sys.file_exists path);
             check string "previous repair backup is unchanged" backup_bytes
               (In_channel.with_open_bin path In_channel.input_all))
           else check bool "no new repair backup was created" false (Sys.file_exists path))
        volumes)
;;

let () =
  Mirage_crypto_rng_unix.use_default ();
  run "server_keeper_volume_maintenance_integration"
    [ "observation", [ test_case "real service observes without runtime mutation" `Quick
                         test_running_sweep_does_not_mutate_volumes ] ]
;;
