(** Unit tests for [Compaction_llm_summarizer] (RFC-0313-adjacent W2).

    Covers the pure surface: structured-plan parsing/validation
    ([plan_of_json]) and plan application ([apply]). The provider call in
    [make] needs an Eio context + live provider and is exercised by
    integration, not here. *)

open Masc
module C = Compaction_llm_summarizer

let plan_json ~summary ~kept ~summarized ~dropped : Yojson.Safe.t =
  let ints xs = `List (List.map (fun i -> `Int i) xs) in
  `Assoc
    [ "summary", `String summary
    ; "kept_indices", ints kept
    ; "summarized_indices", ints summarized
    ; "dropped_indices", ints dropped
    ]

let is_ok = function Ok _ -> true | Error _ -> false
let is_error = function Ok _ -> false | Error _ -> true

(* -- plan_of_json: valid partition accepted -- *)

let test_valid_partition_accepted () =
  let json = plan_json ~summary:"folded" ~kept:[ 3; 4 ] ~summarized:[ 0; 1 ] ~dropped:[ 2 ] in
  Alcotest.(check bool)
    "a full disjoint partition of [0,5) parses"
    true
    (is_ok (C.plan_of_json ~message_count:5 json))

let test_all_kept_accepted () =
  let json = plan_json ~summary:"n/a" ~kept:[ 0; 1; 2 ] ~summarized:[] ~dropped:[] in
  Alcotest.(check bool)
    "kept covering everything parses (summary unused but required non-empty)"
    true
    (is_ok (C.plan_of_json ~message_count:3 json))

let test_drop_only_with_kept_accepted () =
  let json = plan_json ~summary:"unused" ~kept:[ 1 ] ~summarized:[] ~dropped:[ 0 ] in
  Alcotest.(check bool)
    "drop-only plans are valid when at least one message remains"
    true
    (is_ok (C.plan_of_json ~message_count:2 json))

(* -- plan_of_json: structural violations rejected (no silent repair) -- *)

let test_out_of_range_rejected () =
  let json = plan_json ~summary:"x" ~kept:[ 0; 1 ] ~summarized:[ 5 ] ~dropped:[] in
  Alcotest.(check bool)
    "an index >= message_count is rejected"
    true
    (is_error (C.plan_of_json ~message_count:2 json))

let test_negative_rejected () =
  let json = plan_json ~summary:"x" ~kept:[ -1; 0 ] ~summarized:[ 1 ] ~dropped:[] in
  Alcotest.(check bool)
    "a negative index is rejected"
    true
    (is_error (C.plan_of_json ~message_count:2 json))

let test_duplicate_rejected () =
  let json = plan_json ~summary:"x" ~kept:[ 0; 1 ] ~summarized:[ 1 ] ~dropped:[] in
  Alcotest.(check bool)
    "an index appearing in two lists is rejected"
    true
    (is_error (C.plan_of_json ~message_count:2 json))

let test_missing_index_rejected () =
  let json = plan_json ~summary:"x" ~kept:[ 0 ] ~summarized:[] ~dropped:[] in
  Alcotest.(check bool)
    "a partition that omits an in-range index is rejected"
    true
    (is_error (C.plan_of_json ~message_count:2 json))

let test_all_dropped_rejected () =
  let json = plan_json ~summary:"S" ~kept:[] ~summarized:[] ~dropped:[ 0; 1 ] in
  Alcotest.(check bool)
    "a non-empty working set must not compact to empty output"
    true
    (is_error (C.plan_of_json ~message_count:2 json))

let test_empty_summary_rejected () =
  let json = plan_json ~summary:"   " ~kept:[ 0; 1 ] ~summarized:[] ~dropped:[] in
  Alcotest.(check bool)
    "a blank summary is rejected"
    true
    (is_error (C.plan_of_json ~message_count:2 json))

let test_missing_field_rejected () =
  let json = `Assoc [ "summary", `String "x"; "kept_indices", `List [] ] in
  Alcotest.(check bool)
    "a plan missing summarized_indices/dropped_indices is rejected"
    true
    (is_error (C.plan_of_json ~message_count:0 json))

(* -- apply: reconstruction honours the plan -- *)

let msg role text = Agent_sdk.Types.text_message role text
let texts (ms : Agent_sdk.Types.message list) =
  List.map (fun m -> Agent_sdk.Types.text_of_message m) ms

let sample =
  [ msg Agent_sdk.Types.User "u0"
  ; msg Agent_sdk.Types.Assistant "a1"
  ; msg Agent_sdk.Types.Tool "t2"
  ; msg Agent_sdk.Types.User "u3"
  ]

let test_apply_keeps_summarizes_drops () =
  (* kept: 3 ; summarized: 0,1 ; dropped: 2 *)
  let json = plan_json ~summary:"S" ~kept:[ 3 ] ~summarized:[ 0; 1 ] ~dropped:[ 2 ] in
  match C.plan_of_json ~message_count:4 json with
  | Error e -> Alcotest.failf "expected valid plan, got %s" e
  | Ok plan ->
    let out = C.apply plan ~messages:sample in
    let out_texts = texts out in
    (* summary replaces indices 0,1 at position of first summarized (0);
       index 2 dropped; index 3 kept. Result: [summary; u3]. *)
    Alcotest.(check int) "two messages remain" 2 (List.length out);
    Alcotest.(check bool)
      "first is the compaction summary"
      true
      (match out_texts with
       | s :: _ -> Astring.String.is_infix ~affix:"S" s
                   && Astring.String.is_prefix ~affix:"[COMPACTION_SUMMARY]" s
       | [] -> false);
    Alcotest.(check (list string))
      "kept message survives verbatim after the summary"
      [ "u3" ]
      (List.tl out_texts)

let test_apply_all_kept_is_identity () =
  let json = plan_json ~summary:"unused" ~kept:[ 0; 1; 2; 3 ] ~summarized:[] ~dropped:[] in
  match C.plan_of_json ~message_count:4 json with
  | Error e -> Alcotest.failf "expected valid plan, got %s" e
  | Ok plan ->
    let out = C.apply plan ~messages:sample in
    Alcotest.(check (list string))
      "all-kept leaves the working set unchanged"
      (texts sample)
      (texts out)

let () =
  Alcotest.run "compaction_llm_summarizer"
    [ ( "plan_of_json"
      , [ Alcotest.test_case "valid partition accepted" `Quick test_valid_partition_accepted
        ; Alcotest.test_case "all kept accepted" `Quick test_all_kept_accepted
        ; Alcotest.test_case "drop-only with kept accepted" `Quick
            test_drop_only_with_kept_accepted
        ; Alcotest.test_case "out of range rejected" `Quick test_out_of_range_rejected
        ; Alcotest.test_case "negative rejected" `Quick test_negative_rejected
        ; Alcotest.test_case "duplicate rejected" `Quick test_duplicate_rejected
        ; Alcotest.test_case "missing index rejected" `Quick test_missing_index_rejected
        ; Alcotest.test_case "all dropped rejected" `Quick test_all_dropped_rejected
        ; Alcotest.test_case "empty summary rejected" `Quick test_empty_summary_rejected
        ; Alcotest.test_case "missing field rejected" `Quick test_missing_field_rejected
        ] )
    ; ( "apply"
      , [ Alcotest.test_case "keeps/summarizes/drops" `Quick test_apply_keeps_summarizes_drops
        ; Alcotest.test_case "all-kept is identity" `Quick test_apply_all_kept_is_identity
        ] )
    ]
