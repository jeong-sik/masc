open Alcotest

(** RFC-0084 PR-10 — Typed Dispatch_outcome.t sum invariants.

    Pins:
    - 2 variant arms exactly (cardinality drift guard). The sum was
      collapsed from 5 to 2 arms after the dropped arms
      (Rejected_by_capability / Rejected_by_pre_hook / Handler_error)
      were confirmed to have zero producers.
    - Round-trip: every arm.to_string |> of_string |> to_string preserves the label
    - String vocabulary parity (handled / no_handler)
*)

let test_all_arms_cardinality () =
  (check int)
    "Dispatch_outcome.all_arms enumerates 2 variants (RFC-0084 §6 D3)"
    2
    (List.length Dispatch_outcome.all_arms)
;;

let test_to_string_labels () =
  let labels =
    List.map Dispatch_outcome.to_string Dispatch_outcome.all_arms
  in
  let expected = [ "handled"; "no_handler" ] in
  (check (list string))
    "to_string vocabulary matches the 2-arm label set"
    expected
    labels
;;

let test_round_trip_string_label () =
  List.iter
    (fun arm ->
      let label = Dispatch_outcome.to_string arm in
      match Dispatch_outcome.of_string label with
      | Some arm' ->
        let label' = Dispatch_outcome.to_string arm' in
        (check string)
          (Printf.sprintf "round-trip label preserved for %s" label)
          label
          label'
      | None ->
        failf "round-trip: of_string %S returned None" label)
    Dispatch_outcome.all_arms
;;

let test_of_string_unknown_returns_none () =
  (check (option string))
    "of_string on unknown label returns None"
    None
    (Option.map
       Dispatch_outcome.to_string
       (Dispatch_outcome.of_string "_unknown_outcome_label_"))
;;

let test_string_vocabulary_parity () =
  (* Dispatch wraps emit outcome strings "handled" and "no_handler".
     Both must remain valid arms in the typed sum so the otel_metric_store
     counter label set is preserved. *)
  (check bool)
    "handled present in typed sum"
    true
    (Option.is_some (Dispatch_outcome.of_string "handled"));
  (check bool)
    "no_handler present in typed sum"
    true
    (Option.is_some (Dispatch_outcome.of_string "no_handler"))
;;

let () =
  Alcotest.run
    "RFC-0084 PR-10 Dispatch_outcome typed"
    [ ( "dispatch-outcome"
      , [ test_case "all-arms-cardinality" `Quick test_all_arms_cardinality
        ; test_case "to-string-labels" `Quick test_to_string_labels
        ; test_case "round-trip-string-label" `Quick test_round_trip_string_label
        ; test_case "of-string-unknown-returns-none" `Quick test_of_string_unknown_returns_none
        ; test_case "string-vocabulary-parity" `Quick test_string_vocabulary_parity
        ] )
    ]
;;
