(** Unit tests for Keeper_turn_driver_backpressure — pure capacity backpressure
    classification functions. *)

open Keeper_turn_driver_backpressure
open Keeper_internal_error

(* ---- helpers ----------------------------------------------------------- *)

(* capacity_retry_after has no to_string in keeper_internal_error.mli *)
let fmt_retry_after = function
  | Explicit v -> Printf.sprintf "Explicit(%f)" v
  | Synthetic_default v -> Printf.sprintf "Synthetic_default(%f)" v
  | No_retry_hint -> "No_retry_hint"

let fmt_bp_src = capacity_backpressure_source_to_string

let mk_http_err ?(code = 429) ?(body = "") () =
  Llm_provider.Http_client.HttpError { code; body }

let mk_network_err ?(message = "net err")
    ?(kind = Llm_provider.Http_client.Unknown) () =
  Llm_provider.Http_client.NetworkError { message; kind }

let mk_timeout_err ?(message = "timeout") ?(phase = "test_phase") () =
  Llm_provider.Http_client.TimeoutError { message; phase }

let mk_provider_failure ?(message = "provider fail") kind =
  Llm_provider.Http_client.ProviderFailure { kind; message }

let mk_accept_rejected ?(scope = "test") ?(model = Some "gpt-4")
    ?(reason = "safety") () =
  Llm_provider.Http_client.AcceptRejected { scope; model; reason }

let mk_provider_terminal ?(kind = Llm_provider.Http_client.Unknown)
    ?(message = "terminal") () =
  Llm_provider.Http_client.ProviderTerminal { kind; message }

let mk_capacity_exhausted ?retry_after () =
  Llm_provider.Http_client.Capacity_exhausted { retry_after }

let mk_local_resource_exhaustion () =
  Llm_provider.Http_client.Local_resource_exhaustion

let runtime_id = "test-rt-001"

(* ---- capacity_backpressure_source_of_http_error ----------------------- *)

let bp_source_recognises_local_resource_exhaustion () =
  let err = mk_network_err ~kind:(mk_local_resource_exhaustion ()) () in
  Alcotest.(check (option (of_pp capacity_backpressure_source_to_string)))
    "Local_resource_exhaustion -> Runtime_slot"
    (Some Runtime_slot)
    (capacity_backpressure_source_of_http_error err)

let bp_source_recognises_capacity_exhausted () =
  let err = mk_provider_failure (mk_capacity_exhausted ()) in
  Alcotest.(check (option (of_pp capacity_backpressure_source_to_string)))
    "Capacity_exhausted -> Provider_capacity"
    (Some Provider_capacity)
    (capacity_backpressure_source_of_http_error err)

let bp_source_returns_none_for_http_error () =
  Alcotest.(check (option (of_pp capacity_backpressure_source_to_string)))
    "HttpError -> None" None
    (capacity_backpressure_source_of_http_error (mk_http_err ()))

let bp_source_returns_none_for_generic_network_error () =
  Alcotest.(check (option (of_pp capacity_backpressure_source_to_string)))
    "NetworkError(Unknown) -> None" None
    (capacity_backpressure_source_of_http_error (mk_network_err ()))

let bp_source_returns_none_for_timeout () =
  Alcotest.(check (option (of_pp capacity_backpressure_source_to_string)))
    "TimeoutError -> None" None
    (capacity_backpressure_source_of_http_error (mk_timeout_err ()))

let bp_source_returns_none_for_accept_rejected () =
  Alcotest.(check (option (of_pp capacity_backpressure_source_to_string)))
    "AcceptRejected -> None" None
    (capacity_backpressure_source_of_http_error (mk_accept_rejected ()))

let bp_source_returns_none_for_provider_terminal () =
  Alcotest.(check (option (of_pp capacity_backpressure_source_to_string)))
    "ProviderTerminal -> None" None
    (capacity_backpressure_source_of_http_error (mk_provider_terminal ()))

let bp_source_returns_none_for_other_provider_failure () =
  let err = mk_provider_failure Llm_provider.Http_client.Local_resource_exhaustion in
  (* Local_resource_exhaustion inside ProviderFailure is not matched by
     [NetworkError] clause — source confirms this. *)
  Alcotest.(check (option (of_pp capacity_backpressure_source_to_string)))
    "ProviderFailure(Local_resource_exhaustion) -> None" None
    (capacity_backpressure_source_of_http_error err)

(* ---- capacity_backpressure_of_http_error ------------------------------ *)

let is_capacity_backpressure = function
  | Capacity_backpressure _ -> true
  | _ -> false

let assert_source expected actual =
  if actual <> expected then
    Alcotest.failf "expected source %s, got %s"
      (fmt_bp_src expected) (fmt_bp_src actual)

let assert_retry_after expected actual =
  if actual <> expected then
    Alcotest.failf "expected retry_after %s, got %s"
      (fmt_retry_after expected) (fmt_retry_after actual)

let check_backpressure ~source_check ~retry_after_check actual =
  match actual with
  | Some (Capacity_backpressure { runtime_id = rid; source; detail = _; retry_after }) ->
    Alcotest.(check string) "runtime_id matches" runtime_id rid;
    source_check source;
    retry_after_check retry_after
  | Some other ->
    Alcotest.failf "expected Capacity_backpressure _, got %s"
      (match summary_of_masc_internal_error other with
       | Some s -> s | None -> "unknown")
  | None ->
    Alcotest.fail "expected Some (Capacity_backpressure _)"

let bp_of_http_error_with_explicit_retry () =
  let err = mk_provider_failure (mk_capacity_exhausted ~retry_after:(Some 30.0) ()) in
  check_backpressure
    ~source_check:(assert_source Provider_capacity)
    ~retry_after_check:(assert_retry_after (Explicit 30.0))
    (capacity_backpressure_of_http_error ~runtime_id (Some err))

let bp_of_http_error_without_retry () =
  let err = mk_provider_failure (mk_capacity_exhausted ()) in
  check_backpressure
    ~source_check:(assert_source Provider_capacity)
    ~retry_after_check:(function Synthetic_default _ -> () | o ->
      Alcotest.failf "expected Synthetic_default _, got %s" (fmt_retry_after o))
    (capacity_backpressure_of_http_error ~runtime_id (Some err))

let bp_of_http_error_source_override () =
  let err = mk_provider_failure (mk_capacity_exhausted ~retry_after:(Some 5.0) ()) in
  check_backpressure
    ~source_check:(assert_source Client_capacity)
    ~retry_after_check:(assert_retry_after (Explicit 5.0))
    (capacity_backpressure_of_http_error ~runtime_id ~source:Client_capacity (Some err))

let bp_of_http_error_local_resource_exhaustion () =
  let err = mk_network_err ~kind:(mk_local_resource_exhaustion ()) () in
  check_backpressure
    ~source_check:(assert_source Runtime_slot)
    ~retry_after_check:(function Synthetic_default _ -> () | o ->
      Alcotest.failf "expected Synthetic_default _, got %s" (fmt_retry_after o))
    (capacity_backpressure_of_http_error ~runtime_id (Some err))

let bp_of_http_error_none_input () =
  Alcotest.(check bool) "None -> None" true
    (Option.is_none (capacity_backpressure_of_http_error ~runtime_id None))

let bp_of_http_error_http_error_input () =
  Alcotest.(check bool) "HttpError -> None" true
    (Option.is_none
       (capacity_backpressure_of_http_error ~runtime_id (Some (mk_http_err ()))))

(* ---- capacity_backpressure_of_pending --------------------------------- *)

let bp_of_pending_some () =
  check_backpressure
    ~source_check:(assert_source Provider_capacity)
    ~retry_after_check:(assert_retry_after (Explicit 15.0))
    (capacity_backpressure_of_pending ~runtime_id
       (Some (Provider_capacity, "pending detail", Explicit 15.0)))

let bp_of_pending_none () =
  Alcotest.(check bool) "None -> None" true
    (Option.is_none (capacity_backpressure_of_pending ~runtime_id None))

(* ---- capacity_backpressure_of_sdk_error ------------------------------- *)

let msg_looks_like_capacity msg =
  String.starts_with ~prefix:"capacity_" msg
  || String.contains msg "quota"
  || String.contains msg "rate_limit"

let bp_of_sdk_error_provider_capacity_exhausted () =
  let sdk_err =
    Agent_sdk.Error.Provider
      (Llm_provider.Error.CapacityExhausted
         { retry_after = Some 60.0; detail = "quota hit"; scope = "test" })
  in
  Alcotest.(check bool) "Provider CapacityExhausted -> Some" true
    (Option.is_some
       (capacity_backpressure_of_sdk_error ~runtime_id
          ~message_looks_like_capacity_backpressure:msg_looks_like_capacity
          ~sdk_error_of_masc_internal_error:sdk_error_of_masc_internal_error
          sdk_err))

let bp_of_sdk_error_internal_msg_matching () =
  let sdk_err = Agent_sdk.Error.Internal "rate_limit_exceeded" in
  Alcotest.(check bool) "Internal matching msg -> Some" true
    (Option.is_some
       (capacity_backpressure_of_sdk_error ~runtime_id
          ~message_looks_like_capacity_backpressure:msg_looks_like_capacity
          ~sdk_error_of_masc_internal_error:sdk_error_of_masc_internal_error
          sdk_err))

let bp_of_sdk_error_internal_msg_not_matching () =
  let sdk_err = Agent_sdk.Error.Internal "ordinary_error" in
  Alcotest.(check bool) "Internal non-matching msg -> None" true
    (Option.is_none
       (capacity_backpressure_of_sdk_error ~runtime_id
          ~message_looks_like_capacity_backpressure:msg_looks_like_capacity
          ~sdk_error_of_masc_internal_error:sdk_error_of_masc_internal_error
          sdk_err))

let bp_of_sdk_error_api_error () =
  let sdk_err = Agent_sdk.Error.Api "some_api_error" in
  Alcotest.(check bool) "Api error -> None" true
    (Option.is_none
       (capacity_backpressure_of_sdk_error ~runtime_id
          ~message_looks_like_capacity_backpressure:msg_looks_like_capacity
          ~sdk_error_of_masc_internal_error:sdk_error_of_masc_internal_error
          sdk_err))

(* ---- test suite -------------------------------------------------------- *)

let () =
  Alcotest.run "Keeper_turn_driver_backpressure"
    [ "capacity_backpressure_source_of_http_error",
      [ Alcotest.test_case "recognises Local_resource_exhaustion" `Quick
          bp_source_recognises_local_resource_exhaustion;
        Alcotest.test_case "recognises Capacity_exhausted" `Quick
          bp_source_recognises_capacity_exhausted;
        Alcotest.test_case "returns None for HttpError" `Quick
          bp_source_returns_none_for_http_error;
        Alcotest.test_case "returns None for generic NetworkError" `Quick
          bp_source_returns_none_for_generic_network_error;
        Alcotest.test_case "returns None for TimeoutError" `Quick
          bp_source_returns_none_for_timeout;
        Alcotest.test_case "returns None for AcceptRejected" `Quick
          bp_source_returns_none_for_accept_rejected;
        Alcotest.test_case "returns None for ProviderTerminal" `Quick
          bp_source_returns_none_for_provider_terminal;
        Alcotest.test_case "returns None for other ProviderFailure" `Quick
          bp_source_returns_none_for_other_provider_failure;
      ];
      "capacity_backpressure_of_http_error",
      [ Alcotest.test_case "ProviderCapacity with explicit retry_after" `Quick
          bp_of_http_error_with_explicit_retry;
        Alcotest.test_case "ProviderCapacity without retry_after (synthetic)" `Quick
          bp_of_http_error_without_retry;
        Alcotest.test_case "source override" `Quick
          bp_of_http_error_source_override;
        Alcotest.test_case "Local_resource_exhaustion" `Quick
          bp_of_http_error_local_resource_exhaustion;
        Alcotest.test_case "None input" `Quick
          bp_of_http_error_none_input;
        Alcotest.test_case "HttpError input" `Quick
          bp_of_http_error_http_error_input;
      ];
      "capacity_backpressure_of_pending",
      [ Alcotest.test_case "Some pending" `Quick
          bp_of_pending_some;
        Alcotest.test_case "None input" `Quick
          bp_of_pending_none;
      ];
      "capacity_backpressure_of_sdk_error",
      [ Alcotest.test_case "Provider CapacityExhausted" `Quick
          bp_of_sdk_error_provider_capacity_exhausted;
        Alcotest.test_case "Internal msg matching predicate" `Quick
          bp_of_sdk_error_internal_msg_matching;
        Alcotest.test_case "Internal msg not matching predicate" `Quick
          bp_of_sdk_error_internal_msg_not_matching;
        Alcotest.test_case "Api error" `Quick
          bp_of_sdk_error_api_error;
      ];
    ]