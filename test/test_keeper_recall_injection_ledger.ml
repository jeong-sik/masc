open Alcotest

module Ledger = Masc.Keeper_recall_injection_ledger

let with_temp_root f =
  let root = Filename.temp_dir "recall-ledger-v4-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () -> f root)
;;

let json_row ?(extra = []) ?(reset = false) ~version ~turn ~added ~removed () =
  `Assoc
    ([ "schema_version", `Int version
     ; "reset", `Bool reset
     ; "keeper_id", `String "keeper"
     ; "trace_id", `String "trace"
     ; "turn", `Int turn
     ; "added_fact_keys", `List (List.map (fun key -> `String key) added)
     ; "removed_fact_keys", `List (List.map (fun key -> `String key) removed)
     ; "content_hash", `String (Ledger.content_hash_of ~fact_keys:added)
     ; "n_facts_in_store", `Int (List.length added)
     ; "ts", `Float (float_of_int turn)
     ]
     @ extra)
;;

let require_record = function
  | Ok record -> record
  | Error _ -> fail "current ledger row did not decode"
;;

let read_records root =
  let store = Dated_jsonl.create ~base_dir:(Ledger.base_dir ~masc_root:root) () in
  Dated_jsonl.read_recent store 100
  |> List.map (fun json -> Ledger.record_of_json_result json |> require_record)
  |> List.sort (fun (left : Ledger.record) (right : Ledger.record) ->
    Int.compare left.turn right.turn)
;;

let test_current_schema_is_fact_only_and_strict () =
  let current =
    json_row ~version:4 ~turn:1 ~added:[ "a" ] ~removed:[] ()
  in
  (match Ledger.record_of_json_result current with
   | Ok record ->
     check bool "reset false" false record.delta.reset;
     check (list string) "added fact" [ "a" ] record.delta.added_fact_keys
   | Error _ -> fail "v4 row rejected");
  (match
     Ledger.record_of_json_result
       (json_row ~version:3 ~turn:1 ~added:[ "a" ] ~removed:[] ())
   with
   | Error (`Unsupported_schema_version 3) -> ()
   | Error _ -> fail "v3 rejected with wrong error"
   | Ok _ -> fail "v3 compatibility row accepted");
  match
    Ledger.record_of_json_result
      (json_row
         ~version:4
         ~turn:1
         ~added:[ "a" ]
         ~removed:[]
         ~extra:[ "added_episode_keys", `List [] ]
         ())
  with
  | Error (`Unexpected_field "added_episode_keys") -> ()
  | Error _ -> fail "episode field rejected with wrong error"
  | Ok _ -> fail "episode compatibility field accepted"
;;

let test_delta_primitives_and_hash_are_set_based () =
  let added, removed =
    Ledger.diff_keys
      ~previous:[ "a"; "b"; "b" ]
      ~current:[ "b"; "c" ]
  in
  check (list string) "added" [ "c" ] added;
  check (list string) "removed" [ "a" ] removed;
  check (list string) "replayed"
    [ "b"; "c" ]
    (Ledger.apply_delta ~previous:[ "a"; "b" ] ~added ~removed);
  check string "order-independent hash"
    (Ledger.content_hash_of ~fact_keys:[ "a"; "b" ])
    (Ledger.content_hash_of ~fact_keys:[ "b"; "a"; "a" ])
;;

let test_append_writes_fact_delta_and_restart_reset () =
  with_temp_root @@ fun root ->
  Ledger.For_testing.reset_delta_state ();
  Ledger.append
    ~masc_root:root
    ~keeper_id:"keeper"
    ~trace_id:"trace"
    ~turn:1
    ~injected_fact_keys:[ "a"; "b" ]
    ~n_facts_in_store:2
    ~now:1.0
    ();
  Ledger.append
    ~masc_root:root
    ~keeper_id:"keeper"
    ~trace_id:"trace"
    ~turn:2
    ~injected_fact_keys:[ "a"; "c" ]
    ~n_facts_in_store:2
    ~now:2.0
    ();
  Ledger.For_testing.reset_delta_state ();
  Ledger.append
    ~masc_root:root
    ~keeper_id:"keeper"
    ~trace_id:"trace"
    ~turn:3
    ~injected_fact_keys:[ "d" ]
    ~n_facts_in_store:1
    ~now:3.0
    ();
  match read_records root with
  | [ first; second; third ] ->
    check bool "first reset" true first.delta.reset;
    check (list string) "first baseline" [ "a"; "b" ] first.delta.added_fact_keys;
    check bool "second not reset" false second.delta.reset;
    check (list string) "second added" [ "c" ] second.delta.added_fact_keys;
    check (list string) "second removed" [ "b" ] second.delta.removed_fact_keys;
    check bool "restart reset" true third.delta.reset;
    let materialized = Ledger.materialize [ first; second; third ] in
    let last = List.nth materialized 2 in
    check (list string) "restart replaces durable replay state" [ "d" ] last.fact_keys
  | records -> failf "expected 3 records, got %d" (List.length records)
;;

let test_failure_reason_is_bounded () =
  check string "known reason"
    "read_error"
    (Ledger.bounded_failure_reason_label "read_error");
  check string "unknown reason"
    Ledger.failure_reason_unknown_label
    (Ledger.bounded_failure_reason_label "provider-secret-detail")
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run
    "keeper_recall_injection_ledger_v4"
    [ ( "fact-only"
      , [ test_case "strict current schema" `Quick
            test_current_schema_is_fact_only_and_strict
        ; test_case "delta and hash" `Quick
            test_delta_primitives_and_hash_are_set_based
        ; test_case "append and restart reset" `Quick
            test_append_writes_fact_delta_and_restart_reset
        ; test_case "bounded failure reason" `Quick
            test_failure_reason_is_bounded
        ] )
    ]
;;
