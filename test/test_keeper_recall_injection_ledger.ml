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
  in
  check
    "empty fact keys is []"
    (empty |> member "injected_fact_keys" |> to_list = []);
  (* Deterministic round-trip: serialise then re-parse is structurally equal. *)
  let round_trip = Yojson.Safe.from_string (Yojson.Safe.to_string j) in
  check "round-trip equal" (Yojson.Safe.equal j round_trip);
  if !failed > 0
  then (
    Printf.printf "\n%d check(s) failed\n%!" !failed;
    exit 1)
  else Printf.printf "\nall checks passed\n%!"
;;
