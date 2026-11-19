(* Closed candidate-fault judgment. See candidate_fault.mli and
   RFC-one-slot-fault-judgment-for-every-walk.md (#38472). *)

type binding_fact =
  | Credential
  | Account_access
  | Account
  | Model_absent
  | Rate_limit
  | Capacity
  | Server
  | Window
  | Body_limit
  | Admission
  | Deadline
  | Output_dialect
  | Refusal_unread

type t =
  | Binding of binding_fact
  | Unattributed
  | Unknown_after_dispatch
  | Local_admission
  | Not_sent

(* [of_api_error] matches [Retry.api_error] without [_]: a new constructor
   stops compilation until its expected judgment is written here and in the
   table test. *)
let of_api_error (api : Retry.api_error) : t =
  match api with
  | Retry.RateLimited _ -> Binding Rate_limit
  | Retry.Overloaded _ -> Binding Capacity
  | Retry.ServerError _ -> Binding Server
  | Retry.AuthError _ -> Binding Credential
  | Retry.AuthorizationError _ -> Binding Account_access
  | Retry.PaymentRequired _ -> Binding Account
  | Retry.NotFound _ -> Binding Model_absent
  | Retry.ContextOverflow _ -> Binding Window
  | Retry.InputCapacity _ -> Binding Admission
  | Retry.InvalidRequest { reason; _ } ->
    (match reason with
     | Retry.Request_body_refused_by_provider _ -> Binding Body_limit
     | Retry.Refusal_body_not_received -> Binding Refusal_unread
     | Retry.Attempt_rejected -> Binding Admission
     | Retry.Json_parse_error -> Binding Admission
     | Retry.Unknown_invalid_request | Retry.Unclassified_status _ -> Unattributed)
  (* A network failure is not a key, account or model fact: nothing the
     provider answered says whose affair it is. A connection function's failure
     is its own constructor, so [Retry.NetworkError] is everything else, and it
     may have been sent: it stays unknown. The Keeper walk still rotates on it
     through [Runtime_attempt_fsm.should_try_next]. *)
  | Retry.NetworkError _ -> Unknown_after_dispatch
  (* Only a connection function builds [Connect_failed], before any byte of the
     request is written (RFC #52028 §2.3, operator decision 2026-11-15). *)
  | Retry.Connect_failed _ -> Not_sent
  (* [Queue] and [Capacity_backpressure] expire in MASC's own permit queue or
     local capacity gate, before the request reaches this binding. *)
  | Retry.Timeout { phase; message = _ } ->
    if Error.timeout_phase_is_local_admission phase then Local_admission
    else Binding Deadline
;;
