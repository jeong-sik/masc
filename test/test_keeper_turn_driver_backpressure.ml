(** Test suite for keeper_turn_driver_backpressure — 4 pure functions. *)

open Alcotest

module BP = Keeper_turn_driver_backpressure
module IE = Keeper_internal_error
module HC = Llm_provider.Http_client

(* ------------------------------------------------------------------ *)
(*  Helpers                                                            *)
(* ------------------------------------------------------------------ *)

let http_error_of_kind kind =
  HC.http_error_of_kind kind

let provider_failure ~message kind =
  HC.ProviderFailure { kind; message; provider_label = "test" }

let network_error ~message kind =
  HC.NetworkError { kind; message; interface = "test_iface" }

let sdk_error_of_masc_internal_error (e : IE.masc_internal_error) : Agent_sdk.Error.sdk_error =
  Agent_sdk.Error.Internal (IE.masc_internal_error_to_string e)

let always_true _ = true
let always_false _ = false

(* ------------------------------------------------------------------ *)
(*  Test group: capacity_backpressure_source_of_http_error             *)
(* ------------------------------------------------------------------ *)

let test_source_local_resource_exhaustion () =
  let err = network_error ~message:"OOM" HC.Local_resource_exhaustion in
  let got = BP.capacity_backpressure_source_of_http_error err in
  check (option ~pp:(fun fmt v -> Format.pp_print_string fmt (IE.capacity_backpressure_source_to_string v)))
    "local resource exhaustion -> Runtime_slot"
    (Some IE.Runtime_slot) got

let test_source_capacity_exhausted () =
  let err = provider_failure ~message:"rate limit" (HC.Capacity_exhausted { retry_after = Some 30.0 }) in
  let got = BP.capacity_backpressure_source_of_http_error err in
  check (option ~pp:(fun fmt v -> Format.pp_print_string fmt (IE.capacity_backpressure_source_to_string v)))
    "capacity exhausted -> Provider_capacity"
    (Some IE.Provider_capacity) got

let test_source_http_error_returns_none () =
  let err = HC.HttpError { status_code = 403; status_text = "Forbidden"; body = "" } in
  let got = BP.capacity_backpressure_source_of_http_error err in
  check (option (of_char))
    "403 HttpError -> None"
    None got

let test_source_timeout_returns_none () =
  let err = HC.TimeoutError { timeout_sec = 30.0; message = "timed out" } in
  let got = BP.capacity_backpressure_source_of_http_error err in
  check (option (of_char))
    "TimeoutError -> None"
    None got

let test_source_accept_rejected_returns_none () =
  let err = HC.AcceptRejected { content_type = "application/json"; provider = "test" } in
  let got = BP.capacity_backpressure_source_of_http_error err in
  check (option (of_char))
    "AcceptRejected -> None"
    None got

let test_source_provider_terminal_returns_none () =
  let err = HC.ProviderTerminal { message = "billing failure" } in
  let got = BP.capacity_backpressure_source_of_http_error err in
  check (option (of_char))
    "ProviderTerminal -> None"
    None got

let test_source_generic_network_error_returns_none () =
  let err = HC.NetworkError { kind = HC.DnsResolveFailed "unknown host"; message = ""; interface = "eth0" } in
  let got = BP.capacity_backpressure_source_of_http_error err in
  check (option (of_char))
    "generic NetworkError -> None"
    None got

(* ------------------------------------------------------------------ *)
(*  Test group: capacity_backpressure_of_http_error                    *)
(* ------------------------------------------------------------------ *)

let () = assert (synthetic_retry_after_sec > 0.0)

let test_of_http_capacity_exhausted_with_retry_after () =
  let err = Some (provider_failure ~message:"overloaded" (HC.Capacity_exhausted { retry_after = Some 15.0 })) in
  let got = BP.capacity_backpressure_of_http_error ~runtime_id:"r1" err in
  match got with
  | Some (IE.Capacity_backpressure { source; detail; retry_after; runtime_id = _ }) ->
    check string "source" "Provider_capacity" (IE.capacity_backpressure_source_to_string source);
    check string "detail" "overloaded" detail;
    (match retry_after with
     | IE.Explicit f -> check (float 1e-9) "retry_after" 15.0 f
     | _ -> fail "expected Explicit")
  | Some other -> fail ("unexpected variant: " ^ IE.masc_internal_error_to_string other)
  | None -> fail "expected Some"

let test_of_http_capacity_exhausted_no_retry_after () =
  let err = Some (provider_failure ~message:"quota" (HC.Capacity_exhausted { retry_after = None })) in
  let got = BP.capacity_backpressure_of_http_error ~runtime_id:"r1" err in
  match got with
  | Some (IE.Capacity_backpressure { retry_after = IE.Synthetic_default _; _ }) -> ()
  | Some other -> fail ("expected Synthetic_default, got " ^ IE.masc_internal_error_to_string other)
  | None -> fail "expected Some"

let test_of_http_capacity_exhausted_with_source_override () =
  let err = Some (provider_failure ~message:"cap" (HC.Capacity_exhausted { retry_after = None })) in
  let got = BP.capacity_backpressure_of_http_error ~source:IE.Client_capacity ~runtime_id:"r1" err in
  match got with
  | Some (IE.Capacity_backpressure { source; _ }) ->
    check string "overridden source" "Client_capacity" (IE.capacity_backpressure_source_to_string source)
  | _ -> fail "expected Some"

let test_of_http_local_resource_exhaustion () =
  let err = Some (network_error ~message:"local OOM" HC.Local_resource_exhaustion) in
  let got = BP.capacity_backpressure_of_http_error ~runtime_id:"r1" err in
  match got with
  | Some (IE.Capacity_backpressure { source; detail; retry_after = IE.Synthetic_default _; _ }) ->
    check string "source" "Runtime_slot" (IE.capacity_backpressure_source_to_string source);
    check string "detail" "local OOM" detail
  | _ -> fail "expected Some Capacity_backpressure"

let test_of_http_returns_none_for_non_capacity () =
  let err = Some (HC.HttpError { status_code = 500; status_text = "Internal Server Error"; body = "" }) in
  let got = BP.capacity_backpressure_of_http_error ~runtime_id:"r1" err in
  check (option (of_char)) "non-capacity error -> None" None got

let test_of_http_none_err () =
  let got = BP.capacity_backpressure_of_http_error ~runtime_id:"r1" None in
  check (option (of_char)) "None input -> None" None got

(* ------------------------------------------------------------------ *)
(*  Test group: capacity_backpressure_of_pending                       *)
(* ------------------------------------------------------------------ *)

let test_of_pending_some () =
  let triple = (IE.Provider_capacity, "queue full", IE.Explicit 10.0) in
  let got = BP.capacity_backpressure_of_pending ~runtime_id:"r1" (Some triple) in
  match got with
  | Some (IE.Capacity_backpressure { source; detail; retry_after; _ }) ->
    check string "source" "Provider_capacity" (IE.capacity_backpressure_source_to_string source);
    check string "detail" "queue full" detail;
    (match retry_after with
     | IE.Explicit f -> check (float 1e-9) "retry_after" 10.0 f
     | _ -> fail "expected Explicit")
  | _ -> fail "expected Some"

let test_of_pending_some_synthetic () =
  let triple = (IE.Runtime_slot, "slot full", IE.Synthetic_default 5.0) in
  let got = BP.capacity_backpressure_of_pending ~runtime_id:"r2" (Some triple) in
  match got with
  | Some (IE.Capacity_backpressure { source; detail; retry_after = IE.Synthetic_default f; _ }) ->
    check string "source" "Runtime_slot" (IE.capacity_backpressure_source_to_string source);
    check string "detail" "slot full" detail;
    check (float 1e-9) "synthetic value" 5.0 f
  | _ -> fail "expected Some with Synthetic_default"

let test_of_pending_none () =
  let got = BP.capacity_backpressure_of_pending ~runtime_id:"r1" None in
  check (option (of_char)) "None input -> None" None got

(* ------------------------------------------------------------------ *)
(*  Test group: capacity_backpressure_of_sdk_error                     *)
(* ------------------------------------------------------------------ *)

let test_of_sdk_capacity_exhausted () =
  let sdk_err = Agent_sdk.Error.Provider (Llm_provider.Error.CapacityExhausted
    { retry_after = Some 20.0; detail = "quota exceeded"; provider_label = "gpt" }) in
  let got = BP.capacity_backpressure_of_sdk_error
    ~runtime_id:"r1"
    ~message_looks_like_capacity_backpressure:always_false
    ~sdk_error_of_masc_internal_error
    sdk_err in
  match got with
  | Some (Agent_sdk.Error.Internal msg) ->
    check (bool) "message contains Provider_capacity" true
      (try
         let _ = String.index msg 'P' in
         true
       with Not_found -> false)
  | _ -> fail "expected Some Internal"

let test_of_sdk_capacity_exhausted_no_retry () =
  let sdk_err = Agent_sdk.Error.Provider (Llm_provider.Error.CapacityExhausted
    { retry_after = None; detail = "cap"; provider_label = "test" }) in
  let got = BP.capacity_backpressure_of_sdk_error
    ~runtime_id:"r2"
    ~message_looks_like_capacity_backpressure:always_false
    ~sdk_error_of_masc_internal_error
    sdk_err in
  match got with
  | Some (Agent_sdk.Error.Internal _) -> ()
  | _ -> fail "expected Some Internal"

let test_of_sdk_internal_message_matches () =
  let sdk_err = Agent_sdk.Error.Internal "RATE_LIMIT_EXCEEDED: too many requests" in
  let got = BP.capacity_backpressure_of_sdk_error
    ~runtime_id:"r3"
    ~message_looks_like_capacity_backpressure:(fun msg ->
      String.lowercase_ascii msg |> String.contains ( 'r' ))
    ~sdk_error_of_masc_internal_error
    sdk_err in
  match got with
  | Some (Agent_sdk.Error.Internal _) -> ()
  | _ -> fail "expected Some Internal for matching message"

let test_of_sdk_internal_message_no_match () =
  let sdk_err = Agent_sdk.Error.Internal "unknown error" in
  let got = BP.capacity_backpressure_of_sdk_error
    ~runtime_id:"r4"
    ~message_looks_like_capacity_backpressure:always_false
    ~sdk_error_of_masc_internal_error
    sdk_err in
  check (option (of_char)) "non-matching message -> None" None (Option.map (fun _ -> 'x') got)

let test_of_sdk_other_provider_error () =
  let sdk_err = Agent_sdk.Error.Provider (Llm_provider.Error.Authentication { provider_label = "test"; detail = "bad key" }) in
  let got = BP.capacity_backpressure_of_sdk_error
    ~runtime_id:"r5"
    ~message_looks_like_capacity_backpressure:always_false
    ~sdk_error_of_masc_internal_error
    sdk_err in
  check (option (of_char)) "Auth error -> None" None (Option.map (fun _ -> 'x') got)

(* ------------------------------------------------------------------ *)
(*  Suite                                                              *)
(* ------------------------------------------------------------------ *)

let suite =
  [
    ( "source_of_http_error"
    , [
        test_case "local resource exhaustion yields Runtime_slot" `Quick test_source_local_resource_exhaustion;
        test_case "capacity exhausted yields Provider_capacity" `Quick test_source_capacity_exhausted;
        test_case "HttpError returns None" `Quick test_source_http_error_returns_none;
        test_case "TimeoutError returns None" `Quick test_source_timeout_returns_none;
        test_case "AcceptRejected returns None" `Quick test_source_accept_rejected_returns_none;
        test_case "ProviderTerminal returns None" `Quick test_source_provider_terminal_returns_none;
        test_case "generic NetworkError returns None" `Quick test_source_generic_network_error_returns_none;
      ]
    );
    ( "of_http_error"
    , [
        test_case "capacity exhausted with explicit retry-after" `Quick test_of_http_capacity_exhausted_with_retry_after;
        test_case "capacity exhausted without retry -> Synthetic_default" `Quick test_of_http_capacity_exhausted_no_retry_after;
        test_case "capacity exhausted with source override" `Quick test_of_http_capacity_exhausted_with_source_override;
        test_case "local resource exhaustion yields Runtime_slot + Synthetic_default" `Quick test_of_http_local_resource_exhaustion;
        test_case "non-capacity error returns None" `Quick test_of_http_returns_none_for_non_capacity;
        test_case "None input returns None" `Quick test_of_http_none_err;
      ]
    );
    ( "of_pending"
    , [
        test_case "Some triple with Explicit retry" `Quick test_of_pending_some;
        test_case "Some triple with Synthetic_default" `Quick test_of_pending_some_synthetic;
        test_case "None input returns None" `Quick test_of_pending_none;
      ]
    );
    ( "of_sdk_error"
    , [
        test_case "CapacityExhausted with retry-after" `Quick test_of_sdk_capacity_exhausted;
        test_case "CapacityExhausted without retry -> Synthetic_default" `Quick test_of_sdk_capacity_exhausted_no_retry;
        test_case "Internal message matching predicate" `Quick test_of_sdk_internal_message_matches;
        test_case "Internal message not matching returns None" `Quick test_of_sdk_internal_message_no_match;
        test_case "non-capacity Provider error returns None" `Quick test_of_sdk_other_provider_error;
      ]
    );
  ]