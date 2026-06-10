(** Unit tests for [Keeper_turn_driver_backpressure].

    Covers HTTP error classification, SDK error classification,
    pending backpressure construction, and synthetic backoff logging
    (PR #20698). *)

open Keeper_turn_driver_backpressure
open Keeper_internal_error

(* ════════════════════════════════════════════════════════════════
   Helpers
   ════════════════════════════════════════════════════════════════ *)

let capacity_source_to_string = function
  | `Provider_capacity -> "Provider_capacity"
  | `Runtime_slot -> "Runtime_slot"

let retry_after_to_string = function
  | `Explicit f -> Printf.sprintf "Explicit(%f)" f
  | `Synthetic_default f -> Printf.sprintf "Synthetic_default(%f)" f
  | `No_retry_hint -> "No_retry_hint"

(* ════════════════════════════════════════════════════════════════
   HTTP error classification
   ════════════════════════════════════════════════════════════════ *)

let http_error_test ~name ~error ~expected_source ~expected_retry =
  let open Llm_provider.Http_client in
  let http_err = Http_error (error, None) in
  let result = capacity_backpressure_source_of_http_error http_err in
  let pass = match result with
    | Some (source, retry_after) ->
      capacity_source_to_string source = expected_source
      && retry_after_to_string retry_after = expected_retry
    | None -> false
  in
  Alcotest.(check bool) name true pass

let http_none_test ~name ~error =
  let open Llm_provider.Http_client in
  let http_err = Http_error (error, None) in
  let result = capacity_backpressure_source_of_http_error http_err in
  Alcotest.(check bool) name true (result = None)

(* Site 1: HTTP Provider_capacity with retry_after=None → Synthetic_default *)
let test_http_capacity_exhausted_no_retry () =
  http_error_test
    ~name:"HTTP CapacityExhausted, No retry_after → Synthetic_default"
    ~error:(`Provider_capacity (`CapacityExhausted None))
    ~expected_source:"Provider_capacity"
    ~expected_retry:"Synthetic_default(5.000000)"

(* Site 2: HTTP Runtime_slot with Local_resource_exhaustion → Synthetic_default *)
let test_http_local_resource_exhaustion () =
  http_error_test
    ~name:"HTTP Local_resource_exhaustion → Synthetic_default"
    ~error:(`Runtime_slot (`Local_resource_exhaustion None))
    ~expected_source:"Runtime_slot"
    ~expected_retry:"Synthetic_default(5.000000)"

(* HTTP CapacityExhausted with explicit retry_after → Explicit *)
let test_http_capacity_exhausted_explicit_retry () =
  http_error_test
    ~name:"HTTP CapacityExhausted with retry_after → Explicit"
    ~error:(`Provider_capacity (`CapacityExhausted (Some 3.0)))
    ~expected_source:"Provider_capacity"
    ~expected_retry:"Explicit(3.000000)"

(* HTTP error that is NOT capacity-related → None *)
let test_http_non_capacity_errors () =
  http_none_test
    ~name:"HTTP HttpError → None"
    ~error:(`Provider_capacity (`HttpError None));
  http_none_test
    ~name:"HTTP NetworkError → None"
    ~error:(`Network_error None);
  http_none_test
    ~name:"HTTP Timeout → None"
    ~error:(`Timeout None);
  http_none_test
    ~name:"HTTP Auth error → None"
    ~error:(`Auth None)

(* ════════════════════════════════════════════════════════════════
   SDK error classification
   ════════════════════════════════════════════════════════════════ *)

let sdk_error_test ~name ~error ~expected_source ~expected_retry =
  let sdk_err = Sdk_error error in
  let result = capacity_backpressure_source_of_http_error sdk_err in
  let pass = match result with
    | Some (source, retry_after) ->
      capacity_source_to_string source = expected_source
      && retry_after_to_string retry_after = expected_retry
    | None -> false
  in
  Alcotest.(check bool) name true pass

let sdk_none_test ~name ~error =
  let sdk_err = Sdk_error error in
  let result = capacity_backpressure_source_of_http_error sdk_err in
  Alcotest.(check bool) name true (result = None)

(* SDK Provider_capacity with retry_after=None → Synthetic_default *)
let test_sdk_capacity_exhausted_no_retry () =
  sdk_error_test
    ~name:"SDK CapacityExhausted, No retry_after → Synthetic_default"
    ~error:(`Provider_capacity (`CapacityExhausted None))
    ~expected_source:"Provider_capacity"
    ~expected_retry:"Synthetic_default(5.000000)"

(* SDK Runtime_slot with Local_resource_exhaustion → Synthetic_default *)
let test_sdk_local_resource_exhaustion () =
  sdk_error_test
    ~name:"SDK Local_resource_exhaustion → Synthetic_default"
    ~error:(`Runtime_slot (`Local_resource_exhaustion None))
    ~expected_source:"Runtime_slot"
    ~expected_retry:"Synthetic_default(5.000000)"

(* SDK non-capacity errors → None *)
let test_sdk_non_capacity_errors () =
  sdk_none_test
    ~name:"SDK ChannelError → None"
    ~error:(`Channel_error None);
  sdk_none_test
    ~name:"SDK ProtocolError → None"
    ~error:(`Protocol_error None);
  sdk_none_test
    ~name:"SDK AuthError → None"
    ~error:(`Auth_error None)

(* ════════════════════════════════════════════════════════════════
   Pending backpressure construction
   ════════════════════════════════════════════════════════════════ *)

let test_pending_backpressure_construction () =
  let source = `Provider_capacity in
  let retry_after = `Explicit 2.5 in
  let pending = make_pending_backpressure ~source ~retry_after in
  Alcotest.(check bool)
    "pending_backpressure is Some when fields are valid" true
    (Option.is_some pending)

let test_pending_backpressure_fields () =
  let source = `Runtime_slot in
  let retry_after = `Synthetic_default 10.0 in
  let open Option in
  let* pending = make_pending_backpressure ~source ~retry_after in
  let retrieved = get_backpressure_source pending in
  Alcotest.(check bool) "retrieved source matches input" true
    (retrieved = source);
  Alcotest.(check bool) "backpressure_is_active is true initially" true
    (backpressure_is_active pending);
  Some ()

(* Synthetic backoff logging *)
let test_synthetic_backoff_logging () =
  let source = `Runtime_slot in
  let delay = 5.0 in
  let log = synthetic_backoff_log_message ~source ~delay in
  Alcotest.(check bool) "synthetic backoff log contains source" true
    (String.is_substring ~substring:"Runtime_slot" log);
  Alcotest.(check bool) "synthetic backoff log contains delay" true
    (String.is_substring ~substring:"5.0" log)

(* No_retry_hint classification *)
let test_no_retry_hint () =
  let source = `Provider_capacity in
  let retry_after = `No_retry_hint in
  let pending = make_pending_backpressure ~source ~retry_after in
  Alcotest.(check bool) "pending is None when retry is No_retry_hint" true
    (Option.is_none pending)

(* ════════════════════════════════════════════════════════════════
   Suite
   ════════════════════════════════════════════════════════════════ *)

let suite =
  let open Alcotest in
  "keeper_turn_driver_backpressure", [
    test_case "HTTP CapacityExhausted, No retry → Synthetic_default" `Quick
      test_http_capacity_exhausted_no_retry;
    test_case "HTTP Local_resource_exhaustion → Synthetic_default" `Quick
      test_http_local_resource_exhaustion;
    test_case "HTTP CapacityExhausted with retry_after → Explicit" `Quick
      test_http_capacity_exhausted_explicit_retry;
    test_case "HTTP non-capacity errors → None" `Quick
      test_http_non_capacity_errors;
    test_case "SDK CapacityExhausted, No retry → Synthetic_default" `Quick
      test_sdk_capacity_exhausted_no_retry;
    test_case "SDK Local_resource_exhaustion → Synthetic_default" `Quick
      test_sdk_local_resource_exhaustion;
    test_case "SDK non-capacity errors → None" `Quick
      test_sdk_non_capacity_errors;
    test_case "Pending backpressure construction" `Quick
      test_pending_backpressure_construction;
    test_case "Pending backpressure field retrieval" `Quick
      test_pending_backpressure_fields;
    test_case "Synthetic backoff log message" `Quick
      test_synthetic_backoff_logging;
    test_case "No_retry_hint returns None" `Quick
      test_no_retry_hint;
  ]