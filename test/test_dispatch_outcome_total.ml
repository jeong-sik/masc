open Alcotest

(** RFC-0084 PR-10 — Typed Dispatch_outcome.t 5-arm sum invariants.

    Pins:
    - 5 variant arms exactly (cardinality drift guard)
    - Round-trip: every arm.to_string |> of_string |> to_string preserves the label
    - classify_result_option matches the string-outcome contract used
      by PR-7/PR-8/PR-9 wraps
    - String vocabulary parity with PR-7~9 (handled / no_handler)
*)

let test_all_arms_cardinality () =
  (check int)
    "Dispatch_outcome.all_arms enumerates 5 variants (RFC-0084 §6 D3)"
    5
    (List.length Masc_mcp.Dispatch_outcome.all_arms)
;;

let test_to_string_labels () =
  let labels =
    List.map Masc_mcp.Dispatch_outcome.to_string Masc_mcp.Dispatch_outcome.all_arms
  in
  let expected =
    [ "handled"
    ; "rejected_by_capability"
    ; "rejected_by_pre_hook"
    ; "no_handler"
    ; "handler_error"
    ]
  in
  (check (list string))
    "to_string vocabulary matches the 5-arm label set"
    expected
    labels
;;

let test_round_trip_string_label () =
  List.iter
    (fun arm ->
      let label = Masc_mcp.Dispatch_outcome.to_string arm in
      match Masc_mcp.Dispatch_outcome.of_string label with
      | Some arm' ->
        let label' = Masc_mcp.Dispatch_outcome.to_string arm' in
        (check string)
          (Printf.sprintf "round-trip label preserved for %s" label)
          label
          label'
      | None ->
        failf "round-trip: of_string %S returned None" label)
    Masc_mcp.Dispatch_outcome.all_arms
;;

let test_of_string_unknown_returns_none () =
  (check (option string))
    "of_string on unknown label returns None"
    None
    (Option.map
       Masc_mcp.Dispatch_outcome.to_string
       (Masc_mcp.Dispatch_outcome.of_string "_unknown_outcome_label_"))
;;

let test_classify_some_is_handled () =
  match Masc_mcp.Dispatch_outcome.classify_result_option (Some 42) with
  | Masc_mcp.Dispatch_outcome.Handled -> ()
  | other ->
    failf
      "classify_result_option Some _ should be Handled, got %s"
      (Masc_mcp.Dispatch_outcome.to_string other)
;;

let test_classify_none_is_no_handler () =
  match Masc_mcp.Dispatch_outcome.classify_result_option None with
  | Masc_mcp.Dispatch_outcome.No_handler -> ()
  | other ->
    failf
      "classify_result_option None should be No_handler, got %s"
      (Masc_mcp.Dispatch_outcome.to_string other)
;;

let test_classify_with_exn_is_handler_error () =
  match
    Masc_mcp.Dispatch_outcome.classify_result_option ~exn:"oops" (Some 1)
  with
  | Masc_mcp.Dispatch_outcome.Handler_error { exn } ->
    (check string) "exn payload propagated" "oops" exn
  | other ->
    failf
      "classify_result_option ~exn:... should be Handler_error, got %s"
      (Masc_mcp.Dispatch_outcome.to_string other)
;;

let test_string_vocabulary_parity_with_pr7_8_9 () =
  (* PR-7 / PR-8 / PR-9 wraps emit outcome strings "handled" and "no_handler".
     Both must remain valid arms in the typed sum so PR-11 migration
     does not change the prometheus counter label set. *)
  (check bool)
    "handled present in typed sum"
    true
    (Option.is_some (Masc_mcp.Dispatch_outcome.of_string "handled"));
  (check bool)
    "no_handler present in typed sum"
    true
    (Option.is_some (Masc_mcp.Dispatch_outcome.of_string "no_handler"))
;;

let () =
  Alcotest.run
    "RFC-0084 PR-10 Dispatch_outcome typed"
    [ ( "dispatch-outcome"
      , [ test_case "all-arms-cardinality" `Quick test_all_arms_cardinality
        ; test_case "to-string-labels" `Quick test_to_string_labels
        ; test_case "round-trip-string-label" `Quick test_round_trip_string_label
        ; test_case "of-string-unknown-returns-none" `Quick test_of_string_unknown_returns_none
        ; test_case "classify-some-is-handled" `Quick test_classify_some_is_handled
        ; test_case "classify-none-is-no-handler" `Quick test_classify_none_is_no_handler
        ; test_case "classify-with-exn-is-handler-error" `Quick test_classify_with_exn_is_handler_error
        ; test_case "string-vocabulary-parity-with-pr7-8-9" `Quick test_string_vocabulary_parity_with_pr7_8_9
        ] )
    ]
;;
