type plan_fingerprint = Exact_output_plan.fingerprint

type output_normalization_error = Exact_output_plan.output_normalization_error =
  | Incomplete_structured_response of Types.stop_reason
  | Missing_structured_text
  | Ambiguous_structured_text of int
  | Unexpected_structured_content
  | Invalid_json of string

type normalized_output = Exact_output_plan.normalized_output =
  | Text_output of string
  | Json_output of
      { value : Yojson.Safe.t
      ; validation : Exact_output_plan.json_validation_provenance
      }

type effect_phase =
  | Before_dispatch
  | Dispatch_started
  | Response_received
  | Terminal

type receipt_identity =
  { fingerprint : plan_fingerprint
  ; request_body_sha256 : string
  }

type response_receipt =
  { identity : receipt_identity
  ; http_status : int
  }

type one_dispatch_receipt =
  | Before_dispatch_receipt of receipt_identity
  | Dispatch_started_receipt of receipt_identity
  | Response_received_receipt of response_receipt
  | Terminal_receipt of response_receipt

type execute_once_error_cause =
  | Clock_required_for_timeout
  | Frozen_request_mismatch
  | Provider_error of Http_client.http_error
  | Output_normalization_failed of output_normalization_error

type pricing_provenance = Pricing_annotation_omitted

type normalized_outcome =
  { receipt : one_dispatch_receipt
  ; response_format : Types.response_format
  ; response : Types.api_response
  ; output : normalized_output
  ; pricing : pricing_provenance
  }

type raw_response_evidence =
  { raw_body : string
  ; raw_body_sha256 : string
  ; response_header_evidence : Http_client.response_header_evidence
  }

type normalized_outcome_with_evidence =
  { outcome : normalized_outcome
  ; raw_response : raw_response_evidence
  }

type execute_once_error_with_evidence =
  { receipt : one_dispatch_receipt
  ; cause : execute_once_error_cause
  ; raw_response : raw_response_evidence option
  }

let receipt_phase = function
  | Before_dispatch_receipt _ -> Before_dispatch
  | Dispatch_started_receipt _ -> Dispatch_started
  | Response_received_receipt _ -> Response_received
  | Terminal_receipt _ -> Terminal
;;

let receipt_dispatch_count = function
  | Before_dispatch_receipt _ -> 0
  | Dispatch_started_receipt _ | Response_received_receipt _ | Terminal_receipt _ -> 1
;;

let receipt_http_status = function
  | Before_dispatch_receipt _ | Dispatch_started_receipt _ -> None
  | Response_received_receipt receipt | Terminal_receipt receipt ->
    Some receipt.http_status
;;

let receipt_identity = function
  | Before_dispatch_receipt identity | Dispatch_started_receipt identity -> identity
  | Response_received_receipt receipt | Terminal_receipt receipt -> receipt.identity
;;

let receipt_fingerprint receipt = (receipt_identity receipt).fingerprint
let receipt_request_body_sha256 receipt = (receipt_identity receipt).request_body_sha256

let raw_response_evidence (raw : Http_client.raw_sync_response) response_header_evidence =
  { raw_body = raw.body
  ; raw_body_sha256 = Digestif.SHA256.(to_hex (digest_string raw.body))
  ; response_header_evidence
  }
;;

let execute_once_with_evidence ~net ?clock ?on_phase plan =
  let fingerprint = Exact_output_plan.fingerprint plan in
  let request_body_sha256 = Exact_output_plan.request_body_sha256 plan in
  let identity = { fingerprint; request_body_sha256 } in
  let before_dispatch_receipt () = Before_dispatch_receipt identity in
  let dispatch_started_receipt () = Dispatch_started_receipt identity in
  let response_received_receipt http_status =
    Response_received_receipt { identity; http_status }
  in
  let terminal_receipt http_status = Terminal_receipt { identity; http_status } in
  let error ?raw_response receipt cause = Error { receipt; cause; raw_response } in
  let transport_error_receipt = function
    | Http_client.Before_dispatch_error provider_error ->
      before_dispatch_receipt (), provider_error
    | Http_client.Dispatch_started_error provider_error ->
      dispatch_started_receipt (), provider_error
    | Http_client.Response_received_error { status; error = provider_error } ->
      response_received_receipt status, provider_error
  in
  if not (Exact_output_plan.verify_frozen_request plan)
  then error (before_dispatch_receipt ()) Frozen_request_mismatch
  else (
    match
      ( Exact_output_plan.connect_timeout_s plan
      , Exact_output_plan.body_timeout_s plan
      , clock )
    with
    | connect_timeout_s, body_timeout_s, None
      when Option.is_some connect_timeout_s || Option.is_some body_timeout_s ->
      error (before_dispatch_receipt ()) Clock_required_for_timeout
    | connect_timeout_s, body_timeout_s, _ ->
      let post_once () =
        Http_client.post_sync_once_with_evidence
          ?clock
          ?connect_timeout_s
          ?body_timeout_s
          ~net
          ~url:(Exact_output_plan.request_url plan)
          ~headers:(Exact_output_plan.request_headers plan)
          ~body:(Exact_output_plan.request_body plan)
          ()
      in
      (* Transport exceptions are handled upstream: post_sync_once's [fail_exn]
         returns a typed [Unknown_provider_failure] instead of re-raising, which is
         where that belongs because two unrelated call paths hit it. What remains here
         is the observer: [with_observer] runs a caller-supplied [on_phase] callback,
         and a raise from that callback is not a transport error and never reaches
         [fail_exn]. This function returns a result, so that raise must not leave it
         either. Reserved exceptions (cancellation) are re-raised first, the same
         idiom as complete_common.ml:172 and five other edges.

         Dispatch_started is a floor, not a claim: the public receipt is advanced
         separately by the phase observer and Generation_receipt.advance only moves
         forward, so an already-observed Response_received is not lowered by it. *)
      let post_result =
        try
          match on_phase with
          | None -> post_once ()
          | Some observe -> Http_client_phase_observer.with_observer observe post_once
        with
        | exn ->
          Reserved_exn.reraise_if_reserved exn;
          Error
            (Http_client.Dispatch_started_error
               (Http_client.ProviderFailure
                  { kind =
                      Http_client.Unknown_provider_failure
                        { reason = Some (Printexc.to_string exn) }
                  ; message = "unclassified transport exception"
                  }))
      in
      (match post_result with
       | Error transport_error ->
         let receipt, provider_error = transport_error_receipt transport_error in
         error receipt (Provider_error provider_error)
       | Ok (raw, response_header_evidence) when raw.status < 200 || raw.status >= 300 ->
         let raw_response = raw_response_evidence raw response_header_evidence in
         error
           ~raw_response
           (response_received_receipt raw.status)
           (Provider_error
              (Http_client.HttpError
                 { code = raw.status
                 ; body = raw.body
                 ; retry_after_header = raw.retry_after_header
                 }))
       | Ok (raw, response_header_evidence) ->
         let raw_response = raw_response_evidence raw response_header_evidence in
         (match
            Complete_sync.parse_sync_response
              ~http_codec:(Exact_output_plan.response_codec plan)
              ~provider_kind:(Exact_output_plan.provider_kind plan)
              raw.body
          with
          | Error provider_error ->
            error
              ~raw_response
              (response_received_receipt raw.status)
              (Provider_error provider_error)
          | Ok response ->
            (match Exact_output_plan.normalize plan response with
             | Error normalization_error ->
               error
                 ~raw_response
                 (response_received_receipt raw.status)
                 (Output_normalization_failed normalization_error)
             | Ok output ->
               Ok
                 { outcome =
                     { receipt = terminal_receipt raw.status
                     ; response_format = Exact_output_plan.response_format plan
                     ; response
                     ; output
                     ; pricing = Pricing_annotation_omitted
                     }
                 ; raw_response
                 }))))
;;
