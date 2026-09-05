(** A store this build cannot decode is settled once, at boot: examined
    without being touched, refused unless the operator accepted the
    quarantine, and moved aside only then (RFC-0420). *)

open Alcotest
open Masc
module R = Keeper_store_boot_reconcile
module B = Server_bootstrap_loops

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
  (* Preparation checks the config base path against its realpath; on macOS
     the temp dir is reached through the /var -> /private/var symlink. *)
  let root = Unix.realpath (Filename.temp_dir "store-boot-reconcile-" "") in
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

(* One sound meta, one meta that is not a current snapshot, and one memory
   snapshot that is not JSON. *)
type fixture =
  { sound_meta : string
  ; broken_meta : string
  ; broken_snapshot : string
  }

let seed config =
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
  { sound_meta; broken_meta; broken_snapshot }
;;

let stores_of undecodable =
  List.map (fun (u : R.undecodable) -> R.store_to_string u.R.store) undecodable
;;

let test_examine_reads_and_moves_nothing () =
  with_workspace
  @@ fun config ->
  let fixture = seed config in
  let examination = R.examine config in
  check int "readable" 1 examination.R.readable;
  check (list string) "both broken stores are named, meta first"
    [ "keeper_meta"; "memory_current" ]
    (stores_of examination.R.undecodable);
  List.iter
    (fun (u : R.undecodable) ->
       check bool (u.R.path ^ " is still where it was") true (Sys.file_exists u.R.path);
       check bool (u.R.path ^ " says why") true (String.length u.R.rejection > 0))
    examination.R.undecodable;
  check (list string) "the paths are the seeded files"
    [ fixture.broken_meta; fixture.broken_snapshot ]
    (List.map (fun (u : R.undecodable) -> u.R.path) examination.R.undecodable);
  let again = R.examine config in
  check (list string) "a second look gives the same answer"
    (List.map (fun (u : R.undecodable) -> u.R.path) examination.R.undecodable)
    (List.map (fun (u : R.undecodable) -> u.R.path) again.R.undecodable);
  check int "and no rejected copy appeared" 0
    (Sys.readdir (Filename.dirname fixture.broken_snapshot)
     |> Array.to_list
     |> List.filter (fun name -> String_util.contains_substring name ".rejected-")
     |> List.length)
;;

let test_admit_refuses_only_undecodable_without_the_flag () =
  let clean = { R.readable = 3; undecodable = [] } in
  let broken =
    { R.readable = 1
    ; undecodable =
        [ { R.store = R.Memory_current
          ; keeper = "sound"
          ; path = "/w/sound.memory-current.json"
          ; rejection = "invalid JSON"
          }
        ]
    }
  in
  (match R.admit ~accept_quarantine:false clean with
   | Ok admitted -> check int "nothing undecodable passes without the flag" 3 admitted.R.readable
   | Error _ -> fail "a clean examination was refused");
  (match R.admit ~accept_quarantine:false broken with
   | Error refused ->
     check (list string) "the refusal names the store" [ "memory_current" ] (stores_of refused)
   | Ok _ -> fail "an undecodable store passed without the flag");
  match R.admit ~accept_quarantine:true broken with
  | Ok admitted ->
    check int "the flag lets the undecodable store through to quarantine" 1
      (List.length admitted.R.undecodable)
  | Error _ -> fail "the flag did not admit the quarantine"
;;

let test_refusal_names_each_store_and_both_ways_forward () =
  let text =
    R.refusal_to_string
      [ { R.store = R.Keeper_meta
        ; keeper = "broken"
        ; path = "/w/.masc/keepers/broken.json"
        ; rejection = "field set mismatch (missing: trace_id)"
        }
      ; { R.store = R.Memory_current
        ; keeper = "sound"
        ; path = "/w/config/keepers/sound.memory-current.json"
        ; rejection = "invalid JSON: Line 1"
        }
      ]
  in
  let has needle = check bool ("mentions " ^ needle) true (String_util.contains_substring text needle) in
  has "boot refused: 2 store(s)";
  has "keeper_meta keeper=broken path=/w/.masc/keepers/broken.json: field set mismatch (missing: trace_id)";
  has "memory_current keeper=sound path=/w/config/keepers/sound.memory-current.json: invalid JSON: Line 1";
  has "validate-stores";
  has "--accept-store-quarantine";
  check int "one line per store plus the heading and the ways forward" 4
    (List.length (String.split_on_char '\n' text))
;;

let test_undecodable_stores_are_moved_aside_once () =
  with_workspace
  @@ fun config ->
  let fixture = seed config in
  let report = R.quarantine ~now:1_700_000_000.0 config (R.examine config) in
  check int "examined" 3 report.R.examined;
  check int "readable" 1 report.R.readable;
  check int "quarantined" 2 (List.length report.R.quarantined);
  check int "failed" 0 (List.length report.R.failed);
  check bool "the broken meta is gone from its path" false (Sys.file_exists fixture.broken_meta);
  check bool "the broken snapshot is gone from its path" false
    (Sys.file_exists fixture.broken_snapshot);
  List.iter
    (fun (q : R.quarantined) ->
       check bool (q.R.path ^ " kept as bytes") true (Sys.file_exists q.R.rejected_path);
       check bool (q.R.path ^ " says why") true (String.length q.R.rejection > 0))
    report.R.quarantined;
  check (list string) "both stores are named"
    [ "keeper_meta"; "memory_current" ]
    (List.map (fun (q : R.quarantined) -> R.store_to_string q.R.store) report.R.quarantined);
  check bool "the sound meta still reads" true
    (Result.is_ok (Keeper_meta_store.validate_current_meta_file_result fixture.sound_meta));
  let again = R.examine config in
  check int "a second boot finds nothing to move" 0 (List.length again.R.undecodable);
  check int "and still reads the sound meta" 1 again.R.readable;
  let counted = R.quarantine ~now:1_700_000_001.0 config again in
  check int "quarantine with nothing undecodable only counts" 1 counted.R.examined;
  check int "and moves nothing" 0 (List.length counted.R.quarantined)
;;

(* The whole preparation, as the server runs it: refused without the flag with
   the file untouched, moved aside with it. *)
let test_preparation_refuses_then_moves_aside_with_the_flag () =
  with_workspace
  @@ fun config ->
  let fixture = seed config in
  Fun.protect
    ~finally:B.For_testing.reset_keeper_persistence_lifecycle
    (fun () ->
       B.For_testing.reset_keeper_persistence_lifecycle ();
       (match B.prepare_keeper_persistence ~accept_store_quarantine:false ~config () with
        | Error (B.Store_quarantine_refused undecodable) ->
          check (list string) "the refusal names both stores"
            [ "keeper_meta"; "memory_current" ]
            (stores_of undecodable);
          check bool "the broken snapshot is untouched" true
            (Sys.file_exists fixture.broken_snapshot);
          check bool "the broken meta is untouched" true (Sys.file_exists fixture.broken_meta);
          check bool "the refusal text reaches the operator" true
            (String_util.contains_substring
               (B.keeper_persistence_prepare_error_to_string
                  (B.Store_quarantine_refused undecodable))
               fixture.broken_snapshot)
        | Error error ->
          failf "preparation failed for another reason: %s"
            (B.keeper_persistence_prepare_error_to_string error)
        | Ok _ -> fail "preparation went on past an undecodable store without the flag");
       B.For_testing.reset_keeper_persistence_lifecycle ();
       match B.prepare_keeper_persistence ~accept_store_quarantine:true ~config () with
       | Ok _ ->
         check bool "with the flag the broken snapshot is moved aside" false
           (Sys.file_exists fixture.broken_snapshot);
         check bool "and the broken meta too" false (Sys.file_exists fixture.broken_meta)
       | Error error ->
         failf "preparation with the flag failed: %s"
           (B.keeper_persistence_prepare_error_to_string error))
;;

let () =
  run
    "keeper store boot reconcile"
    [ ( "examine"
      , [ test_case "reads every store and moves nothing" `Quick
            test_examine_reads_and_moves_nothing
        ] )
    ; ( "admit"
      , [ test_case "refuses only undecodable stores without the flag" `Quick
            test_admit_refuses_only_undecodable_without_the_flag
        ; test_case "the refusal names each store and both ways forward" `Quick
            test_refusal_names_each_store_and_both_ways_forward
        ] )
    ; ( "quarantine"
      , [ test_case "undecodable stores are moved aside once" `Quick
            test_undecodable_stores_are_moved_aside_once
        ] )
    ; ( "preparation"
      , [ test_case "refuses without the flag and moves aside with it" `Quick
            test_preparation_refuses_then_moves_aside_with_the_flag
        ] )
    ]
;;
