(** Unit tests for Attempt_state — the shared retry/attempt record from #8930. *)

open Masc_mcp.Attempt_state

let test_make_next_resets_on_new_generation () =
  let previous =
    make_next
      ~now:100.0
      ~backoff_seconds:30.0
      ~generation:1
      ~last_result:Start_dispatched
      ~previous:None
  in
  Alcotest.(check int) "initial attempt_number" 1 previous.attempt_number;
  let next_same_gen =
    make_next
      ~now:200.0
      ~backoff_seconds:30.0
      ~generation:1
      ~last_result:Start_dispatched
      ~previous:(Some previous)
  in
  Alcotest.(check int) "continues within same generation" 2 next_same_gen.attempt_number;
  let next_new_gen =
    make_next
      ~now:300.0
      ~backoff_seconds:30.0
      ~generation:2
      ~last_result:Start_dispatched
      ~previous:(Some next_same_gen)
  in
  Alcotest.(check int) "resets on new generation" 1 next_new_gen.attempt_number;
  Alcotest.(check string) "attempt_id format" "2:1" next_new_gen.attempt_id
;;

let test_backoff_window () =
  let t =
    make_next
      ~now:100.0
      ~backoff_seconds:30.0
      ~generation:1
      ~last_result:Start_dispatched
      ~previous:None
  in
  Alcotest.(check bool) "within window → active" true (is_backoff_active ~now:120.0 t);
  Alcotest.(check bool) "at deadline → inactive" false (is_backoff_active ~now:130.0 t);
  Alcotest.(check bool) "past deadline → inactive" false (is_backoff_active ~now:131.0 t);
  let never_retries = { t with next_retry_unix = None } in
  Alcotest.(check bool) "None → inactive" false (is_backoff_active ~now:0.0 never_retries)
;;

let test_json_roundtrip_start_dispatched () =
  let t =
    make_next
      ~now:100.0
      ~backoff_seconds:30.0
      ~generation:7
      ~last_result:Start_dispatched
      ~previous:None
  in
  match of_json (to_json t) with
  | Some t' ->
    Alcotest.(check int) "gen" t.generation t'.generation;
    Alcotest.(check int) "num" t.attempt_number t'.attempt_number;
    Alcotest.(check string) "id" t.attempt_id t'.attempt_id;
    Alcotest.(check (option (float 0.001)))
      "next_retry"
      t.next_retry_unix
      t'.next_retry_unix;
    Alcotest.(check (float 0.001)) "updated" t.updated_unix t'.updated_unix
  | None -> Alcotest.fail "json roundtrip returned None"
;;

let test_json_roundtrip_failed_preserves_reason () =
  let t =
    make_next
      ~now:100.0
      ~backoff_seconds:30.0
      ~generation:1
      ~last_result:(Failed { reason = "shell exited 137" })
      ~previous:None
  in
  match of_json (to_json t) with
  | Some { last_result = Failed { reason }; _ } ->
    Alcotest.(check string) "preserved reason" "shell exited 137" reason
  | Some _ -> Alcotest.fail "last_result lost Failed constructor"
  | None -> Alcotest.fail "json roundtrip returned None"
;;

let test_result_of_string_strict () =
  Alcotest.(check bool)
    "known token → Some"
    true
    (result_of_string_opt "start_dispatched" <> None);
  Alcotest.(check bool)
    "unknown token → None"
    true
    (result_of_string_opt "mystery_state" = None);
  Alcotest.(check bool) "empty → None" true (result_of_string_opt "" = None)
;;

let test_of_json_rejects_missing_fields () =
  let half = `Assoc [ "generation", `Int 1; "attempt_number", `Int 1 ] in
  Alcotest.(check bool) "missing fields → None" true (of_json half = None);
  let bad_result =
    `Assoc
      [ "generation", `Int 1
      ; "attempt_number", `Int 1
      ; "attempt_id", `String "1:1"
      ; "last_result", `String "not_a_real_state"
      ; "next_retry_unix", `Null
      ; "updated_unix", `Float 100.0
      ]
  in
  Alcotest.(check bool) "unknown last_result → None" true (of_json bad_result = None)
;;

let () =
  Alcotest.run
    "attempt_state"
    [ ( "make_next"
      , [ Alcotest.test_case
            "resets on new generation"
            `Quick
            test_make_next_resets_on_new_generation
        ] )
    ; "backoff", [ Alcotest.test_case "window semantics" `Quick test_backoff_window ]
    ; ( "json"
      , [ Alcotest.test_case
            "roundtrip start_dispatched"
            `Quick
            test_json_roundtrip_start_dispatched
        ; Alcotest.test_case
            "roundtrip failed preserves reason"
            `Quick
            test_json_roundtrip_failed_preserves_reason
        ; Alcotest.test_case
            "rejects missing fields and unknown tokens"
            `Quick
            test_of_json_rejects_missing_fields
        ] )
    ; ( "result_of_string_opt"
      , [ Alcotest.test_case "strict parse" `Quick test_result_of_string_strict ] )
    ]
;;
