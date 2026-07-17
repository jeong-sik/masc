(* RFC-0264 P2 / masc#25052: unit tests for the recall-injection ledger record
   serialiser, the v2 delta schema, and retention maintenance. The serialiser
   checks are pure; retention checks use a temporary dated JSONL tree to keep
   append-time pruning out of the hot path. *)

module Ledger = Masc.Keeper_recall_injection_ledger
open Yojson.Safe.Util

let failed = ref 0

let check name cond =
  if cond then Printf.printf "[PASS] %s\n%!" name
  else (
    incr failed;
    Printf.printf "[FAIL] %s\n%!" name)

let check_string_list name expected actual =
  check
    name
    (List.sort String.compare expected = List.sort String.compare actual)

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

let with_temp_masc_root name f =
  let path = Filename.temp_file name "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)

let old_recall_file_path ~masc_root ~retention_days =
  let old_ts =
    Unix.gettimeofday ()
    -. (float_of_int (retention_days + 5) *. Masc_time_constants.day)
  in
  let old_tm = Unix.gmtime old_ts in
  let old_month =
    Printf.sprintf "%04d-%02d" (old_tm.Unix.tm_year + 1900) (old_tm.Unix.tm_mon + 1)
  in
  let old_day = Printf.sprintf "%02d.jsonl" old_tm.Unix.tm_mday in
  let old_month_dir = Filename.concat (Ledger.base_dir ~masc_root) old_month in
  Fs_compat.mkdir_p old_month_dir;
  Filename.concat old_month_dir old_day

let write_old_recall_file ~masc_root ~retention_days =
  let old_file = old_recall_file_path ~masc_root ~retention_days in
  let old_row =
    Ledger.to_json
      ~keeper_id:"old-keeper"
      ~trace_id:"old-trace"
      ~turn:1
      ~injected_fact_keys:[ "old-fact" ]
      ~injected_episode_keys:[]
      ~n_facts_in_store:1
      ~now:0.0
      ()
    |> Yojson.Safe.to_string
  in
  Fs_compat.append_file old_file (old_row ^ "\n");
  old_file

let test_append_does_not_prune_old_day_file () =
  with_temp_masc_root "recall-ledger-append-no-prune" @@ fun masc_root ->
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let retention_days = 30 in
  let old_file = write_old_recall_file ~masc_root ~retention_days in
  Ledger.append
    ~masc_root
    ~keeper_id:"alpha"
    ~trace_id:"trace-retention"
    ~turn:1
    ~injected_fact_keys:[ "fact" ]
    ~injected_episode_keys:[]
    ~n_facts_in_store:1
    ~now:1234.5
    ();
  check "append does not prune old recall file" (Sys.file_exists old_file);
  let store = Dated_jsonl.create ~base_dir:(Ledger.base_dir ~masc_root) () in
  check
    "current recall row survives append without retention"
    (Dated_jsonl.read_recent store 10 |> List.length > 0)

let test_prune_older_than_removes_old_day_file () =
  with_temp_masc_root "recall-ledger-retention-manual" @@ fun masc_root ->
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let retention_days = 30 in
  let old_file = write_old_recall_file ~masc_root ~retention_days in
  (match Ledger.prune_older_than ~masc_root ~retention_days with
   | Ok deleted -> check "manual retention reports prune count" (deleted >= 1)
   | Error label ->
     check
       ("manual retention should not fail: " ^ Ledger.string_of_prune_error label)
       false);
  check "manual retention removes old recall file" (not (Sys.file_exists old_file))

(* ── v2 delta append, via a temp masc_root + Eio (append is the only path
   that touches the process-local Delta_state registry and Dated_jsonl I/O) ─ *)

(* This file predates Alcotest (see the [check] harness above) and uses a
   plain exit-code runner, so a decode failure while building a fixture is a
   hard test-writer bug, not a data condition under test -- [failwith] is the
   right escape here, not another [check] row. *)
let fixture_fail msg = failwith msg

let read_all_records ~masc_root =
  let store = Dated_jsonl.create ~base_dir:(Ledger.base_dir ~masc_root) () in
  Dated_jsonl.read_recent store 1000
  |> List.map (fun json ->
    match Ledger.record_of_json_result json with
    | Ok record -> record
    | Error _ -> fixture_fail "unexpected decode failure in ledger fixture")
;;

let test_append_writes_delta_row_and_updates_registry () =
  with_temp_masc_root "recall-ledger-delta-append" @@ fun masc_root ->
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Ledger.For_testing.reset_delta_state ();
  Ledger.append
    ~masc_root
    ~keeper_id:"gamma"
    ~trace_id:"trace-g"
    ~turn:1
    ~injected_fact_keys:[ "x"; "y" ]
    ~injected_episode_keys:[]
    ~n_facts_in_store:2
    ~now:1.0
    ();
  Ledger.append
    ~masc_root
    ~keeper_id:"gamma"
    ~trace_id:"trace-g"
    ~turn:2
    ~injected_fact_keys:[ "y"; "z" ]
    ~injected_episode_keys:[ "trace-g:g0" ]
    ~n_facts_in_store:2
    ~now:2.0
    ();
  match read_all_records ~masc_root with
  | [ first; second ] ->
    (match first.payload with
     | Ledger.Delta { added_fact_keys; removed_fact_keys; _ } ->
       check_string_list
         "first append (fresh registry) is a full accounting: added = [x; y]"
         [ "x"; "y" ]
         added_fact_keys;
       check "first append has no removals (nothing prior)" (removed_fact_keys = [])
     | Ledger.Full_snapshot _ ->
       check "first append is tagged Delta, not Full_snapshot" false);
    (match second.payload with
     | Ledger.Delta
         { added_fact_keys; removed_fact_keys; added_episode_keys; removed_episode_keys; _ } ->
       check_string_list "second append adds only the new key" [ "z" ] added_fact_keys;
       check_string_list "second append removes only the dropped key" [ "x" ] removed_fact_keys;
       check_string_list "second append adds the new episode key" [ "trace-g:g0" ]
         added_episode_keys;
       check "second append removes no episode keys" (removed_episode_keys = [])
     | Ledger.Full_snapshot _ ->
       check "second append is tagged Delta, not Full_snapshot" false)
  | rows ->
    check (Printf.sprintf "expected exactly 2 rows, got %d" (List.length rows)) false
;;

let test_append_no_change_produces_empty_delta_regardless_of_store_size () =
  with_temp_masc_root "recall-ledger-delta-nochange" @@ fun masc_root ->
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Ledger.For_testing.reset_delta_state ();
  let small = List.init 10 (fun i -> Printf.sprintf "fact-%d" i) in
  let large = List.init 1000 (fun i -> Printf.sprintf "fact-%d" i) in
  let row_bytes_of_second_append ~keeper_id ~facts =
    Ledger.append
      ~masc_root
      ~keeper_id
      ~trace_id:"trace-1"
      ~turn:1
      ~injected_fact_keys:facts
      ~injected_episode_keys:[]
      ~n_facts_in_store:(List.length facts)
      ~now:1.0
      ();
    Ledger.append
      ~masc_root
      ~keeper_id
      ~trace_id:"trace-1"
      ~turn:2
      ~injected_fact_keys:facts
      ~injected_episode_keys:[]
      ~n_facts_in_store:(List.length facts)
      ~now:2.0
      ();
    let store = Dated_jsonl.create ~base_dir:(Ledger.base_dir ~masc_root) () in
    match Dated_jsonl.read_recent_lines store 2 with
    | [ _first; second_line ] -> String.length second_line
    | lines -> fixture_fail (Printf.sprintf "expected 2 lines, got %d" (List.length lines))
  in
  let small_bytes = row_bytes_of_second_append ~keeper_id:"small-store-keeper" ~facts:small in
  let large_bytes = row_bytes_of_second_append ~keeper_id:"large-store-keeper" ~facts:large in
  (* Both second rows are empty-delta rows (nothing changed since turn 1):
     their byte size must be governed by the fixed field overhead, not by
     store size. A generous 3x margin absorbs keeper_id/trace_id string
     length differences without hiding a real O(store_size) regression
     (which would make [large_bytes] roughly 100x [small_bytes], not ~1x). *)
  check
    (Printf.sprintf
       "unchanged-set row bytes independent of store size (small=%d large=%d)"
       small_bytes
       large_bytes)
    (large_bytes < small_bytes * 3)
;;

let test_materialize_replays_legacy_and_delta_rows () =
  let full ~keeper_id ~trace_id ~turn ~fact_keys ~episode_keys =
    { Ledger.keeper_id
    ; trace_id
    ; turn
    ; ts = Some (float_of_int turn)
    ; failure_reason = None
    ; n_facts_in_store = None
    ; n_episodes_in_store = None
    ; payload = Ledger.Full_snapshot { fact_keys; episode_keys }
    }
  in
  let delta
        ~keeper_id
        ~trace_id
        ~turn
        ~added_fact_keys
        ~removed_fact_keys
        ~added_episode_keys
        ~removed_episode_keys
    =
    { Ledger.keeper_id
    ; trace_id
    ; turn
    ; ts = Some (float_of_int turn)
    ; failure_reason = None
    ; n_facts_in_store = None
    ; n_episodes_in_store = None
    ; payload =
        Ledger.Delta
          { added_fact_keys
          ; removed_fact_keys
          ; added_episode_keys
          ; removed_episode_keys
          ; content_hash =
              Ledger.content_hash_of ~fact_keys:added_fact_keys ~episode_keys:added_episode_keys
          }
    }
  in
  let records =
    [ full ~keeper_id:"k" ~trace_id:"t1" ~turn:1 ~fact_keys:[ "a"; "b" ] ~episode_keys:[]
    ; delta
        ~keeper_id:"k"
        ~trace_id:"t1"
        ~turn:2
        ~added_fact_keys:[ "c" ]
        ~removed_fact_keys:[ "a" ]
        ~added_episode_keys:[ "t1:g0" ]
        ~removed_episode_keys:[]
    ]
  in
  match Ledger.materialize records with
  | [ first; second ] ->
    check_string_list "genesis snapshot materializes to its own list" [ "a"; "b" ]
      first.fact_keys;
    check_string_list "delta row materializes to (prior + added) - removed" [ "b"; "c" ]
      second.fact_keys;
    check_string_list "delta row materializes episode keys" [ "t1:g0" ] second.episode_keys
  | rows -> check (Printf.sprintf "expected 2 materialized rows, got %d" (List.length rows)) false
;;

let test_materialize_keeps_keepers_independent () =
  let row keeper_id turn keys =
    { Ledger.keeper_id
    ; trace_id = "t"
    ; turn
    ; ts = None
    ; failure_reason = None
    ; n_facts_in_store = None
    ; n_episodes_in_store = None
    ; payload = Ledger.Full_snapshot { fact_keys = keys; episode_keys = [] }
    }
  in
  let records = [ row "keeper-a" 1 [ "shared" ]; row "keeper-b" 1 [ "other" ] ] in
  match Ledger.materialize records with
  | [ a; b ] ->
    check_string_list "keeper-a materializes its own set only" [ "shared" ] a.fact_keys;
    check_string_list "keeper-b materializes its own set only" [ "other" ] b.fact_keys
  | rows -> check (Printf.sprintf "expected 2 materialized rows, got %d" (List.length rows)) false
;;

let () =
  let j =
    Ledger.to_json
      ~keeper_id:"alpha"
      ~trace_id:"trace-1"
      ~turn:3
      ~injected_fact_keys:[ "fact one"; "fact two" ]
      ~injected_episode_keys:[ "trace-1:g0" ]
      ~n_facts_in_store:42
      ~now:1234.5
      ()
  in
  check "keeper_id" (j |> member "keeper_id" |> to_string = "alpha");
  check "trace_id" (j |> member "trace_id" |> to_string = "trace-1");
  check "turn" (j |> member "turn" |> to_int = 3);
  check "n_facts_in_store" (j |> member "n_facts_in_store" |> to_int = 42);
  check "ts" (j |> member "ts" |> to_number = 1234.5);
  check
    "injected_fact_keys preserved in order"
    (j |> member "injected_fact_keys" |> to_list |> List.map to_string
     = [ "fact one"; "fact two" ]);
  check
    "injected_episode_keys preserved"
    (j |> member "injected_episode_keys" |> to_list |> List.map to_string
     = [ "trace-1:g0" ]);
  check "failure_reason omitted by default" (j |> member "failure_reason" = `Null);
  let failure_json =
    Ledger.to_json
      ~failure_reason:"prompt_render_error"
      ~keeper_id:"alpha"
      ~trace_id:"trace-1"
      ~turn:3
      ~injected_fact_keys:[]
      ~injected_episode_keys:[]
      ~n_facts_in_store:42
      ~now:1234.5
      ()
  in
  check
    "failure_reason preserved when present"
    (failure_json |> member "failure_reason" |> to_string = "prompt_render_error");
  (* Empty key lists serialise to empty JSON arrays, not null. *)
  let empty =
    Ledger.to_json
      ~keeper_id:"k"
      ~trace_id:"t"
      ~turn:0
      ~injected_fact_keys:[]
      ~injected_episode_keys:[]
      ~n_facts_in_store:0
      ~now:0.0
      ()
  in
  check
    "empty fact keys is []"
    (empty |> member "injected_fact_keys" |> to_list = []);
  (* Deterministic round-trip: serialise then re-parse is structurally equal. *)
  let round_trip = Yojson.Safe.from_string (Yojson.Safe.to_string j) in
  check "round-trip equal" (Yojson.Safe.equal j round_trip);
  (match Ledger.record_of_json_result round_trip with
   | Ok { payload = Ledger.Full_snapshot { fact_keys; episode_keys }; keeper_id; trace_id; turn; _ } ->
     check "typed decoder preserves keeper_id" (keeper_id = "alpha");
     check "typed decoder preserves trace_id" (trace_id = "trace-1");
     check "typed decoder preserves turn" (turn = 3);
     check "typed decoder preserves fact keys" (fact_keys = [ "fact one"; "fact two" ]);
     check "typed decoder preserves episode keys" (episode_keys = [ "trace-1:g0" ])
   | Ok { payload = Ledger.Delta _; _ } ->
     check "legacy row decodes as Full_snapshot, not Delta" false
   | Error _ -> check "typed decoder accepts own schema" false);
  (match Ledger.record_of_json_result (`Assoc []) with
   | Error (`Missing_field "keeper_id") -> check "missing keeper_id is visible" true
   | _ -> check "missing keeper_id is visible" false);
  (match
     Ledger.record_of_json_result
       (`Assoc
         [ "keeper_id", `String "alpha"
         ; "trace_id", `String "trace-1"
         ; "turn", `Int 1
         ; "injected_fact_keys", `List [ `Int 1 ]
         ; "injected_episode_keys", `List []
         ])
   with
   | Error (`Invalid_field "injected_fact_keys") ->
     check "invalid fact key list is visible" true
   | _ -> check "invalid fact key list is visible" false);
  (match
     Ledger.record_of_json_result
       (`Assoc
         [ "keeper_id", `String "alpha"
         ; "trace_id", `String "trace-1"
         ; "turn", `Int 1
         ; "schema_version", `Int 99
         ; "injected_fact_keys", `List []
         ; "injected_episode_keys", `List []
         ])
   with
   | Error (`Unsupported_schema_version 99) ->
     check "unknown schema_version is a typed error, not a silent fallback" true
   | _ -> check "unknown schema_version is a typed error, not a silent fallback" false);
  check
    "known recall failure label stays stable"
    (Ledger.bounded_failure_reason_label "prompt_render_error"
     = "prompt_render_error");
  check
    "unknown recall failure label is bounded"
    (Ledger.bounded_failure_reason_label "free-form provider detail"
     = Ledger.failure_reason_unknown_label);
  (* Pure delta primitives: round-trip and direct cases. *)
  let added, removed = Ledger.diff_keys ~previous:[ "a"; "b" ] ~current:[ "b"; "c" ] in
  check_string_list "diff_keys added" [ "c" ] added;
  check_string_list "diff_keys removed" [ "a" ] removed;
  check_string_list
    "apply_delta reconstructs current from previous + diff_keys"
    [ "b"; "c" ]
    (Ledger.apply_delta ~previous:[ "a"; "b" ] ~added ~removed);
  check_string_list
    "diff_keys of identical sets is empty"
    []
    (fst (Ledger.diff_keys ~previous:[ "a"; "b" ] ~current:[ "b"; "a" ]));
  check
    "content_hash_of is order-independent"
    (Ledger.content_hash_of ~fact_keys:[ "a"; "b" ] ~episode_keys:[]
     = Ledger.content_hash_of ~fact_keys:[ "b"; "a" ] ~episode_keys:[]);
  check
    "content_hash_of distinguishes different sets"
    (Ledger.content_hash_of ~fact_keys:[ "a" ] ~episode_keys:[]
     <> Ledger.content_hash_of ~fact_keys:[ "a"; "b" ] ~episode_keys:[]);
  test_materialize_replays_legacy_and_delta_rows ();
  test_materialize_keeps_keepers_independent ();
  test_append_does_not_prune_old_day_file ();
  test_prune_older_than_removes_old_day_file ();
  test_append_writes_delta_row_and_updates_registry ();
  test_append_no_change_produces_empty_delta_regardless_of_store_size ();
  if !failed > 0
  then (
    Printf.printf "\n%d check(s) failed\n%!" !failed;
    exit 1)
  else Printf.printf "\nall checks passed\n%!"
;;
