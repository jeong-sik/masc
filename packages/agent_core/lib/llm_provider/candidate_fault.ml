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
     | Retry.Unknown_invalid_request -> Unattributed)
  (* A network failure is not a key, account or model fact: nothing the
     provider answered says whose affair it is, and [Retry.NetworkError]
     carries no dispatch fact to split "sent, then lost" from wiring every
     candidate shares. The RFC §2.1 table has no network row, so it stays
     unknown. The Keeper walk still rotates on it through
     [Runtime_attempt_fsm.should_try_next]. *)
  | Retry.NetworkError _ -> Unknown_after_dispatch
  | Retry.Timeout _ -> Binding Deadline
;;
