(* RFC-0264 P2: unit tests for the recall-injection ledger record serialiser.
   Pure, deterministic, no I/O — verifies the JSON shape that recall_outcome_eval
   (P3) will join against, and that the record round-trips. *)

module Ledger = Masc.Keeper_recall_injection_ledger
open Yojson.Safe.Util

let failed = ref 0

let check name cond =
  if cond then Printf.printf "[PASS] %s\n%!" name
  else (
    incr failed;
    Printf.printf "[FAIL] %s\n%!" name)

let tmpdir name =
  let path = Filename.temp_file name "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path

let write_old_recall_file masc_root =
  let old_month =
    Filename.concat (Filename.concat masc_root "recall_injections") "2020-01"
  in
  Fs_compat.mkdir_p old_month;
  let old_file = Filename.concat old_month "15.jsonl" in
  Fs_compat.append_file old_file "{\"old\":true}\n";
  old_file

let test_append_retention_prunes_old_day_file () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let masc_root = tmpdir "recall-ledger-retention-append" in
  let old_file = write_old_recall_file masc_root in
  Ledger.append
    ~retention_days:30
    ~masc_root
    ~keeper_id:"alpha"
    ~trace_id:"trace-retention"
    ~turn:1
    ~injected_fact_keys:[ "fact" ]
    ~injected_episode_keys:[]
    ~n_facts_in_store:1
    ~now:1234.5
    ();
  check "append retention prunes old recall file" false (Sys.file_exists old_file);
  let store =
    Dated_jsonl.create
      ~base_dir:(Filename.concat masc_root "recall_injections")
      ()
  in
  check "current recall row survives append retention" true
    (Dated_jsonl.read_recent store 10 |> List.length > 0)

let test_prune_older_than_removes_old_day_file () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let masc_root = tmpdir "recall-ledger-retention-manual" in
  let old_file = write_old_recall_file masc_root in
  let deleted = Ledger.prune_older_than ~masc_root ~retention_days:30 in
  check "manual retention reports deletion" true (deleted >= 1);
  check "manual retention removes old recall file" false (Sys.file_exists old_file)

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
  test_append_retention_prunes_old_day_file ();
  test_prune_older_than_removes_old_day_file ();
  if !failed > 0
  then (
    Printf.printf "\n%d check(s) failed\n%!" !failed;
    exit 1)
  else Printf.printf "\nall checks passed\n%!"
;;
