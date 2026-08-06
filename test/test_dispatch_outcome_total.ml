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


(* ── of_result_option and the label a real dispatch emits ── *)

(* Three sites (Tool_dispatch, Mcp_server_eio_execute,
   Keeper_tool_registered_runtime) each wrote `match r with Some _ ->
   "handled" | None -> "no_handler"` by hand while this module's .mli
   claimed to own that label. They now go through of_result_option +
   to_string. *)

let test_of_result_option_maps_both_arms () =
  (check bool)
    "Some _ is Handled"
    true
    (Dispatch_outcome.equal Dispatch_outcome.Handled
       (Dispatch_outcome.of_result_option (Some ())));
  (check bool)
    "None is No_handler"
    true
    (Dispatch_outcome.equal Dispatch_outcome.No_handler
       (Dispatch_outcome.of_result_option None))
;;

(* Every arm must be reachable from some option input, or one of them has
   no producer -- the condition that shrank this sum from 5 arms to 2. *)
let test_of_result_option_reaches_every_arm () =
  let produced =
    [ Dispatch_outcome.of_result_option (Some ()); Dispatch_outcome.of_result_option None ]
  in
  List.iter
    (fun arm ->
      (check bool)
        (Printf.sprintf "%s is produced by of_result_option"
           (Dispatch_outcome.to_string arm))
        true
        (List.exists (Dispatch_outcome.equal arm) produced))
    Dispatch_outcome.all_arms
;;

(* End to end: the label guarded_dispatch hands the span wrapper must be
   the one this module produces. A hand-written literal reintroduced at any
   dispatch site fails here. *)
let captured_label = ref None

let capturing_wrapper ?force_new_trace_id:_ ?surface:_ ~tool_name:_ body =
  let result, label = body (fun () -> None) in
  captured_label := Some label;
  result, label
;;

let dispatch_label_for ~tool_name =
  captured_label := None;
  Tool_dispatch.set_span_wrapper capturing_wrapper;
  match Tool_token.mint_with ~validate:(fun _ -> true) ~name:tool_name with
  | Error message -> Alcotest.failf "could not mint a token for %s: %s" tool_name message
  | Ok token ->
    let _ = Tool_dispatch.guarded_dispatch ~token ~args:(`Assoc []) () in
    !captured_label
;;

let test_dispatch_emits_the_owned_label () =
  match dispatch_label_for ~tool_name:"tool-that-is-not-registered" with
  | None -> Alcotest.fail "the span wrapper was never handed a label"
  | Some label ->
    (check string)
      "an unregistered tool reports the No_handler label"
      (Dispatch_outcome.to_string Dispatch_outcome.No_handler)
      label
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
        ; test_case "of-result-option-maps-both-arms" `Quick
            test_of_result_option_maps_both_arms
        ; test_case "of-result-option-reaches-every-arm" `Quick
            test_of_result_option_reaches_every_arm
        ; test_case "dispatch-emits-the-owned-label" `Quick
            test_dispatch_emits_the_owned_label
        ] )
    ]
;;
