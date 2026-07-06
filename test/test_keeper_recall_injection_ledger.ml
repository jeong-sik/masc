(* RFC-0264 P2: unit tests for the recall-injection ledger record serialiser and
   retention maintenance hook. The serialiser checks are pure; retention checks
   use a temporary dated JSONL tree to keep append-time pruning out of the hot
   path. *)

module Ledger = Masc.Keeper_recall_injection_ledger
open Yojson.Safe.Util

let failed = ref 0

let check name cond =
  if cond then Printf.printf "[PASS] %s\n%!" name
  else (
    incr failed;
    Printf.printf "[FAIL] %s\n%!" name)

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
   | Ok record ->
     check "typed decoder preserves keeper_id" (record.keeper_id = "alpha");
     check "typed decoder preserves trace_id" (record.trace_id = "trace-1");
     check "typed decoder preserves turn" (record.turn = 3);
     check
       "typed decoder preserves fact keys"
       (record.injected_fact_keys = [ "fact one"; "fact two" ])
   | Error _ -> check "typed decoder accepts own schema" false);
  (match Ledger.record_of_json_result (`Assoc []) with
   | Error (`Missing_field "keeper_id") -> check "missing keeper_id is visible" true
   | _ -> check "missing keeper_id is visible" false);
  (match
     Ledger.record_of_json_result
       (`Assoc
         [ "keeper_id", `String "alpha"
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
         ; "trace_id", `String ""
         ; "turn", `Int 7
         ; "injected_fact_keys", `List []
         ; "injected_episode_keys", `List []
         ])
   with
   | Error (`Invalid_field "trace_id") -> check "empty trace_id is visible" true
   | _ -> check "empty trace_id is visible" false);
  check
    "known recall failure label stays stable"
    (Ledger.bounded_failure_reason_label "prompt_render_error"
     = "prompt_render_error");
  check
    "unknown recall failure label is bounded"
    (Ledger.bounded_failure_reason_label "free-form provider detail"
     = Ledger.failure_reason_unknown_label);
  test_append_does_not_prune_old_day_file ();
  test_prune_older_than_removes_old_day_file ();
  if !failed > 0
  then (
    Printf.printf "\n%d check(s) failed\n%!" !failed;
    exit 1)
  else Printf.printf "\nall checks passed\n%!"
;;
