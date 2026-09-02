(** A store this build cannot decode is moved aside once, at boot, and
    every later read sees either a decodable file or none. *)

open Alcotest
open Masc
module R = Keeper_store_boot_reconcile

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
    Unix.unlink path
;;

let with_workspace operation =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let root = Filename.temp_dir "store-boot-reconcile-" "" in
  let config = Workspace.default_config root in
  ignore (Workspace.init config ~agent_name:(Some "test"));
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> operation config)
;;

let meta keeper_name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String keeper_name; "trace_id", `String "trace-reconcile" ])
  with
  | Ok meta -> meta
  | Error detail -> fail detail
;;

let write_bytes path bytes =
  Fs_compat.mkdir_p (Filename.dirname path);
  let oc = open_out_bin path in
  output_string oc bytes;
  close_out oc
;;

let test_undecodable_stores_are_moved_aside_once () =
  with_workspace
  @@ fun config ->
  (match Keeper_meta_store.replace_snapshot config (meta "sound") with
   | Ok () -> ()
   | Error detail -> fail detail);
  let sound_meta = Keeper_types_profile.keeper_meta_path config "sound" in
  let broken_meta = Keeper_types_profile.keeper_meta_path config "broken" in
  write_bytes broken_meta "{\"name\":\"broken\"}";
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path
  in
  let broken_snapshot =
    Keeper_memory_os_current.path_for_keepers_dir ~keepers_dir ~keeper_id:"sound"
  in
  write_bytes broken_snapshot "{ this is not a snapshot";
  let report = R.reconcile ~now:1_700_000_000.0 config in
  check int "examined" 3 report.R.examined;
  check int "readable" 1 report.R.readable;
  check int "quarantined" 2 (List.length report.R.quarantined);
  check int "failed" 0 (List.length report.R.failed);
  check bool "the broken meta is gone from its path" false (Sys.file_exists broken_meta);
  check bool "the broken snapshot is gone from its path" false
    (Sys.file_exists broken_snapshot);
  List.iter
    (fun (q : R.quarantined) ->
       check bool (q.R.path ^ " kept as bytes") true (Sys.file_exists q.R.rejected_path);
       check bool (q.R.path ^ " says why") true (String.length q.R.rejection > 0))
    report.R.quarantined;
  check (list string) "both stores are named"
    [ "keeper_meta"; "memory_current" ]
    (List.map (fun (q : R.quarantined) -> R.store_to_string q.R.store) report.R.quarantined);
  check bool "the sound meta still reads" true
    (Result.is_ok (Keeper_meta_store.validate_current_meta_file_result sound_meta));
  let again = R.reconcile ~now:1_700_000_001.0 config in
  check int "a second boot finds nothing to move" 0 (List.length again.R.quarantined);
  check int "and still reads the sound meta" 1 again.R.readable
;;

let () =
  run
    "keeper store boot reconcile"
    [ ( "boot"
      , [ test_case
            "undecodable stores are moved aside once"
            `Quick
            test_undecodable_stores_are_moved_aside_once
        ] )
    ]
;;
