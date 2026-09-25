(* Closed candidate-fault judgment. See candidate_fault.mli and
   RFC-one-slot-fault-judgment-for-every-walk.md (#38472). *)

type binding_fact =
  | Credential
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

type dispatch =
  | Not_dispatched
  | Dispatched

(* [of_api_error] matches [Retry.api_error] without [_]: a new constructor
   stops compilation until its expected judgment is written here and in the
   table test. *)
let of_api_error (api : Retry.api_error) : t =
  match api with
  | Retry.RateLimited _ -> Binding Rate_limit
  | Retry.Overloaded _ -> Binding Capacity
  | Retry.ServerError _ -> Binding Server
  | Retry.AuthError _ -> Binding Credential
  | Retry.AuthorizationError _ -> Binding Credential
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

(* [of_transport_error] classifies the transport edge. The [dispatch] fact is
   the Exact_output [generation_dispatch_fact] lowered: a timeout before
   dispatch is wiring, after dispatch it is this binding's deadline. *)
let of_transport_error (err : Http_client.http_error) ~(dispatch : dispatch) : t =
  match err with
  | Http_client.HttpError _ -> Binding Server
  | Http_client.NetworkError _ -> Unknown_after_dispatch
  | Http_client.TimeoutError { phase; _ } ->
    (match dispatch with
     | Dispatched ->
       (match phase with
        | Http_client.Http_operation | Http_client.Wall_clock -> Binding Deadline
        | Http_client.Queue
        | Http_client.First_token
        | Http_client.Capacity_backpressure
        | Http_client.Non_streaming_body
        | Http_client.Stream_body
        | Http_client.Stream_idle _
        | Http_client.Provider_step
        | Http_client.Cli_stdout_idle
        | Http_client.Unknown_timeout -> Unknown_after_dispatch)
     | Not_dispatched -> Unknown_after_dispatch)
  (* Wiring and provider-terminal conditions are not this binding's affair in
     the advance sense; they carry no "the next candidate may serve the same
     input" fact. *)
  | Http_client.AcceptRejected _ -> Unknown_after_dispatch
  | Http_client.ProviderTerminal _ -> Unknown_after_dispatch
  | Http_client.ProviderFailure _ -> Unknown_after_dispatch
;;
