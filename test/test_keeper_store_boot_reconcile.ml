(** A store this build cannot decode is settled once, at boot: examined
    without being touched, refused unless the operator accepted the
    quarantine, and moved aside only then (RFC-0420). The goal store is only
    read: boot logs one INFO line when it cannot read it, never refuses or
    moves it, and leaves its bytes as they were (RFC-0444 §2.4, criteria 3
    and 7). *)

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

let file_digest path = Digest.to_hex (Digest.file path)

(* goals.json as the #34459 hard cut left it: a row without
   [criterion_revision], in the file and in its .last-good mirror. Written
   raw so no writer of the store plants it. *)
let goal_bytes_without_criterion_revision () =
  let ts = Masc_domain.now_iso () in
  let goal =
    { Goal_store.id = "goal-before-the-hard-cut"
    ; criterion_revision = "fixture-criterion"
    ; title = "Goal before the hard cut"
    ; metric = None
    ; target_value = None
    ; due_date = None
    ; priority = 3
    ; phase = Goal_phase.Executing
    ; last_review_note = None
    ; last_review_at = None
    ; created_at = ts
    ; updated_at = ts
    }
  in
  let row =
    match Goal_store.goal_to_yojson goal with
    | `Assoc fields -> `Assoc (List.remove_assoc "criterion_revision" fields)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      fail "goal serializer returned a non-object"
  in
  Yojson.Safe.to_string
    (`Assoc [ "version", `Int 1; "updated_at", `String ts; "goals", `List [ row ] ])
;;

(* The line boot has to log for the seeded store, rendered from the store's
   own reader: refused on [criterion_revision], with the mirror refused too.
   Any other reading means the fixture is not the #34459 shape. *)
let unavailable_goal_store_line config =
  match Goal_store.load_source config with
  | Goal_store.Unavailable
      ({ Goal_store.reason = Goal_store.Schema_rejected { field; _ }
       ; mirror = Goal_store.Mirror_rejected _
       ; _
       } as unavailable) ->
    check string "the store refuses the missing field" "criterion_revision" field;
    Goal_store.unavailable_to_string unavailable
  | Goal_store.Unavailable unavailable ->
    failf "the goal store was refused another way: %s"
      (Goal_store.unavailable_to_string unavailable)
  | Goal_store.Available _ -> fail "the seeded goal store read as Available"
  | Goal_store.Uninitialized -> fail "the seeded goal store read as Uninitialized"
;;

(* [since_seq] is exclusive and the ring's first entry carries seq 0. *)
let ring_cursor () =
  match Log.Ring.recent ~limit:1 () with
  | entry :: _ -> entry.Log.Ring.seq
  | [] -> -1
;;

let keeper_info_lines_since cursor line =
  Log.Ring.recent ~limit:Log.Ring.capacity ~since_seq:cursor ~module_filter:"Keeper" ()
  |> List.filter (fun (entry : Log.Ring.entry) ->
    match entry.Log.Ring.level with
    | Log.Info -> String.equal entry.Log.Ring.message line
    | Log.Debug | Log.Warn | Log.Error -> false)
  |> List.length
;;

(* One sound meta, one meta that is not a current snapshot, one memory
   snapshot that is not JSON, and a goal store this build refuses in both
   its files. *)
type fixture =
  { sound_meta : string
  ; broken_meta : string
  ; broken_snapshot : string
  ; goals : string
  ; goals_mirror : string
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
  let goals = Goal_store.goals_path config in
  let goals_mirror = goals ^ ".last-good" in
  let goal_bytes = goal_bytes_without_criterion_revision () in
  write_bytes goals goal_bytes;
  write_bytes goals_mirror goal_bytes;
  { sound_meta; broken_meta; broken_snapshot; goals; goals_mirror }
;;

let goal_digests fixture = file_digest fixture.goals, file_digest fixture.goals_mirror

let check_goal_digests label fixture (goals, goals_mirror) =
  check string (label ^ ": goals.json digest") goals (file_digest fixture.goals);
  check string (label ^ ": .last-good digest") goals_mirror (file_digest fixture.goals_mirror)
;;

let stores_of undecodable =
  List.map (fun (u : R.undecodable) -> R.store_to_string u.R.store) undecodable
;;

let test_examine_reads_and_moves_nothing () =
  with_workspace
  @@ fun config ->
  let fixture = seed config in
  let digests = goal_digests fixture in
  let line = unavailable_goal_store_line config in
  let cursor = ring_cursor () in
  let examination = R.examine config in
  check int "readable" 1 examination.R.readable;
  check int "one INFO line for the unreadable goal store" 1
    (keeper_info_lines_since cursor line);
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
  check int "one INFO line per look" 2 (keeper_info_lines_since cursor line);
  check_goal_digests "after two looks" fixture digests;
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
  let digests = goal_digests fixture in
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
  check_goal_digests "after the quarantine" fixture digests;
  let again = R.examine config in
  check int "a second boot finds nothing to move" 0 (List.length again.R.undecodable);
  check int "and still reads the sound meta" 1 again.R.readable;
  let counted = R.quarantine ~now:1_700_000_001.0 config again in
  check int "quarantine with nothing undecodable only counts" 1 counted.R.examined;
  check int "and moves nothing" 0 (List.length counted.R.quarantined)
;;

(* The whole preparation, as the server runs it: refused without the flag with
   the file untouched, moved aside with it. The goal store gives one line per
   boot and keeps its bytes through both. *)
let test_preparation_refuses_then_moves_aside_with_the_flag () =
  with_workspace
  @@ fun config ->
  let fixture = seed config in
  let digests = goal_digests fixture in
  let line = unavailable_goal_store_line config in
  let cursor = ring_cursor () in
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
       check_goal_digests "after the refused boot" fixture digests;
       B.For_testing.reset_keeper_persistence_lifecycle ();
       match B.prepare_keeper_persistence ~accept_store_quarantine:true ~config () with
       | Ok _ ->
         check bool "with the flag the broken snapshot is moved aside" false
           (Sys.file_exists fixture.broken_snapshot);
         check bool "and the broken meta too" false (Sys.file_exists fixture.broken_meta);
         check_goal_digests "after the accepted quarantine" fixture digests;
         check int "one INFO line per boot, two boots" 2
           (keeper_info_lines_since cursor line)
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
