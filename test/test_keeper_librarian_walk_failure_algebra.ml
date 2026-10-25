(* Pure port of the walk-failure combination boundary: the shared evidence
   algebra that admission reads after a refused Librarian walk. No server,
   no fixture keeper, no files - only values and JSON roundtrips through the
   public API of [Keeper_exact_walk_failure] and
   [Keeper_librarian_input_refusal].

   The suite links through [exact_output_fixture] like its Librarian
   siblings and opens [Masc] so the wrapped library's modules resolve.

   Two boundaries had no test of their own:

   - [Input_refusal.union] returns the distinct causes in canonical
     constructor order regardless of slot order, and unknown wire tokens
     never become size evidence ([of_string] None).
   - [combine] folds slot evidence into one verdict where
     [provider_input_refusals] is order-independent while
     [measured_cli_capacity] keeps the larger limit and [invalid_output]
     poisons the size verdict; [after_cli_fallback] must drop a prior
     measured limit before folding the fallback walk's CLI observations. *)

open Masc

module S = Keeper_exact_walk_failure
module I = Keeper_librarian_input_refusal
module EO = Agent_core.Exact_output

let refusals evidence = List.map I.to_string evidence.S.provider_input_refusals

(* Build real typed host causes, never diagnostic text: a provider refusal
   from the API walk, and a Codex app-server input_too_large RPC error whose
   payload is the only structurally witnessed measured-limit source. *)
let provider_refusal (refusal : EO.provider_refusal) =
  EO.Provider_response_refused
    { http_status = 400; refusal; retry_after_s = None }

let named refusal = S.of_cause (provider_refusal refusal)

let measured runtime_id actual max_chars =
  S.of_cli_failure
    (Keeper_lane_cli_oneshot.Execution_failed
       { runtime_id
       ; cause = Fusion_official_client.Codex_failure
           (Runtime_codex_app_server.Rpc_error
              { method_ = "turn/start"
              ; code = Some (-32602)
              ; message = "input too large"
              ; data = Some
                  (`Assoc [ "input_error_code", `String "input_too_large"
                          ; "actual_chars", `Int actual
                          ; "max_chars", `Int max_chars ] ) } ) } )

let max_of evidence =
  match evidence.S.measured_cli_capacity with
  | Some { Keeper_lane_cli_oneshot.capacity = { max_chars; _ }; _ } -> Some max_chars
  | None -> None

let test_union_canonical_order () =
  let check label left right expected =
    Alcotest.(check (list string)) label
      (List.map I.to_string expected)
      (List.map I.to_string (I.union left right))
  in
  check "left slot order is canonicalized"
    [I.Input_capacity; I.Context_overflow] [I.Context_overflow]
    [I.Context_overflow; I.Input_capacity];
  check "right slot order is canonicalized"
    [I.Input_capacity] [I.Request_body_refused; I.Context_overflow]
    [I.Context_overflow; I.Input_capacity; I.Request_body_refused];
  check "duplicates collapse across slots"
    [I.Input_capacity; I.Request_body_refused] [I.Request_body_refused; I.Input_capacity]
    [I.Input_capacity; I.Request_body_refused]

let test_union_duplicates () =
  Alcotest.(check (list string)) "duplicate causes appear once"
    [ "context_overflow"; "input_capacity" ]
    (List.map I.to_string
       (I.union [ I.Input_capacity; I.Context_overflow; I.Input_capacity ]
          [ I.Context_overflow ]))

let test_of_string_boundary () =
  Alcotest.(check (option string)) "known token decodes" (Some "input_capacity")
    (Option.map I.to_string (I.of_string "input_capacity"));
  Alcotest.(check bool) "unknown token is not size evidence" true
    (match I.of_string "quota" with None -> true | Some _ -> false);
  Alcotest.(check bool) "empty token is not size evidence" true
    (match I.of_string "" with None -> true | Some _ -> false)

let test_combine_refusal_order_independence () =
  let left = named EO.Input_capacity in
  let right = named EO.Context_overflow in
  Alcotest.(check (list string)) "combine is order independent"
    (refusals (S.combine left right))
    (refusals (S.combine right left));
  Alcotest.(check bool) "combined evidence still answers size" true
    (S.refuses_input_capacity (S.combine left right))

let test_combine_keeps_larger_cli_limit () =
  Alcotest.(check (option int)) "larger measured limit survives" (Some 21)
    (max_of (S.combine (measured "cli-primary" 21 17) (measured "cli-secondary" 25 21)));
  Alcotest.(check (option int)) "smaller-first order keeps the same limit" (Some 21)
    (max_of (S.combine (measured "cli-secondary" 25 21) (measured "cli-primary" 21 17)))

let test_invalid_output_poisons_size () =
  let evidence = S.combine (named EO.Context_overflow) S.invalid_output in
  Alcotest.(check bool) "invalid output blocks the size verdict" false
    (S.refuses_input_capacity evidence);
  Alcotest.(check bool) "invalid output blocks a smaller range" false
    (S.shows_range_size evidence)

let test_named_causes_survive_the_receipt_codec () =
  List.iter (fun cause ->
      let original = S.of_cause cause in
      let decoded =
        match S.api_observation cause |> S.api_observation_to_yojson
              |> S.api_observation_of_yojson with
        | Ok observed -> S.of_api_observation observed
        | Error detail -> Alcotest.fail detail
      in
      Alcotest.(check bool) "named actual causes survive the strict receipt codec" true
        (original = decoded))
    [ provider_refusal EO.Context_overflow
    ; provider_refusal EO.Input_capacity
    ; provider_refusal EO.Request_body_refused ]

let test_after_cli_fallback_drops_prior_limit () =
  let prior = S.combine (named EO.Input_capacity) (measured "cli-primary" 23 17) in
  let fallback =
    Keeper_lane_cli_oneshot.Execution_failed
      { runtime_id = "cli-secondary"
      ; cause = Fusion_official_client.Missing_reply }
  in
  let evidence = S.after_cli_fallback ~prior [ fallback ] in
  Alcotest.(check bool) "the prior measured limit is dropped" true
    (match evidence.S.measured_cli_capacity with None -> true | Some _ -> false);
  Alcotest.(check bool) "the fallback walk still reads less" true
    (S.shows_range_size evidence);
  Alcotest.(check bool) "named refusals survive the fallback" true
    (S.refuses_input_capacity evidence)

let () =
  Alcotest.run "Librarian walk-failure algebra"
    [ "refusal tokens"
    , [ Alcotest.test_case "union canonicalizes slot order" `Quick
          test_union_canonical_order
      ; Alcotest.test_case "union collapses duplicates" `Quick test_union_duplicates
      ; Alcotest.test_case "of_string unknown boundary" `Quick test_of_string_boundary ]
    ; "combine algebra"
    , [ Alcotest.test_case "refusals are order independent" `Quick
          test_combine_refusal_order_independence
      ; Alcotest.test_case "larger measured CLI limit survives" `Quick
          test_combine_keeps_larger_cli_limit
      ; Alcotest.test_case "invalid output poisons the size verdict" `Quick
          test_invalid_output_poisons_size
      ; Alcotest.test_case "named causes survive the receipt codec" `Quick
          test_named_causes_survive_the_receipt_codec ]
    ; "fallback"
    , [ Alcotest.test_case "after_cli_fallback drops the prior limit" `Quick
          test_after_cli_fallback_drops_prior_limit ] ]
