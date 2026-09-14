type t = { request : Llm_transport.completion_request }

type admitted_body =
  { http_codec : Provider_http_codec.t
  ; body : string
  ; evidence : Request_wire_observer.observation
  }

type serialized =
  { prepared : t
  ; admitted_body : admitted_body
  }

type measurement =
  { input_count : Input_token_count.count
  ; output_token_receipt : Types.output_token_receipt
  }

type measured =
  { prepared : t
  ; admitted_body : admitted_body option
  ; measurement : measurement
  ; count_round_trip_s : float option
  }

type next_stage =
  | Completion of { call_timeout_s : float option }
  | Stream of
      { admission_timeout_s : float option
      ; first_event_timeout_s : float option
      }

type context_fit =
  { input_tokens : int
  ; reserved_output_tokens : int
  ; max_context_tokens : int
  }

type fit_error =
  | Context_limit_unknown of { model_id : string }
  | Invalid_context_limit of
      { model_id : string
      ; max_context_tokens : int
      }
  | Output_reservation_unknown of { model_id : string }
  | Context_window_exceeded of context_fit
  | Serving_constraint_rejected of
      { constraint_ : Serving_constraint.t
      ; reason : Serving_constraint.admission_error
      }

type admitted =
  { measured : measured
  ; fit : context_fit
  }

let prepare
      ~config
      ~messages
      ?(tools = [])
      ?(trace_context = [])
      ?capture_id
      ?stream_idle_timeout_s
      ?first_event_timeout_s
      ?body_timeout_s
      ()
  =
  { request =
      { Llm_transport.config =
          Complete_common.config_with_trace_context config trace_context
      ; messages
      ; tools
      ; capture_id
      ; observe_http_status = None
      ; observe_wire_chunk = None
      ; request_wire_observer = None
      ; stream_idle_timeout_s
      ; first_event_timeout_s
      ; body_timeout_s
      }
  }
;;

let request prepared = prepared.request

let admit_serialized_body ~stream prepared =
  let request = prepared.request in
  let config = request.Llm_transport.config in
  let ( let* ) = Result.bind in
  let* () = Complete_common.validate_all config in
  let* http_codec, body =
    Complete_common.serialize_final_http_request_unadmitted
      ~stream
      ~config
      ~messages:request.messages
      ~tools:request.tools
  in
  let* body = Complete_common.admit_final_serialized_body ~config body in
  let evidence =
    Request_wire_observer.observation
      ~capture_id:request.capture_id
      ~provider:(Provider_registry.provider_name_of_config config)
      ~model:config.model_id
      ~http_codec:(Provider_http_codec.fingerprint_tag http_codec)
      ~stream
      ~body
  in
  Ok { prepared; admitted_body = { http_codec; body; evidence } }
;;

let transport_failure error =
  Error (Count_tokens_sync.Input_count_failed (Input_token_count.Transport error))
;;

let measure_prepared ?connection_cache ?clock ?timeout_s ~next_stage ?on_permit_wait ~sw ~net prepared =
  let config = prepared.request.Llm_transport.config in
  let count () =
    Count_tokens_sync.measure_completion_request
      ?connection_cache
      ?clock
      ?timeout_s
      ~sw
      ~net
      prepared.request
  in
  (* The count round trip is timed when there is a clock to time it on: the
     stream's first-event budget is one window from this request to the
     first token, and the route hands the stream what this round trip left. *)
  let measured () =
    let started = Option.map Eio.Time.now clock in
    count ()
    |> Result.map (fun (measurement : Count_tokens_sync.completion_request_measurement) ->
      { prepared
      ; admitted_body = None
      ; measurement =
          { input_count = measurement.input_count
          ; output_token_receipt = measurement.output_token_receipt
          }
      ; count_round_trip_s =
          (match started, clock with
           | Some started, Some clock -> Some (Eio.Time.now clock -. started)
           | None, _ | Some _, None -> None)
      })
  in
  let deadline ~parameter timeout_s =
    Http_client.resolve_explicit_deadline
      ~operation:"Prepared_completion_request.measure"
      ~parameter
      ~clock
      ~timeout_s
    |> Result.map_error (fun error ->
      Count_tokens_sync.Input_count_failed (Input_token_count.Transport error))
  in
  let deadline_exceeded ~parameter ~seconds ~phase ~stage =
    transport_failure
      (Http_client.TimeoutError
         { message =
             Printf.sprintf
               "%s deadline exceeded after %.17gs %s (Prepared_completion_request.measure)"
               parameter
               seconds
               stage
         ; phase
         })
  in
  let permit_wait_expired ~parameter ~seconds =
    deadline_exceeded
      ~parameter
      ~seconds
      ~phase:Http_client.Queue
      ~stage:"before a provider admission permit was granted for the count-tokens request"
  in
  match Complete_common.validate_all config with
  | Error (Http_client.AcceptRejected { reason }) ->
    Error (Count_tokens_sync.Invalid_completion_request reason)
  | Error error -> transport_failure error
  | Ok () ->
    (match next_stage with
     | Completion { call_timeout_s } ->
       (* Ahead of a non-streaming completion the caller's bound is the whole
          call: the measurement takes the endpoint's permit like the
          completion does, so the call deadline bounds that wait and the
          count round trip under it the same way; a declared [timeout_s]
          still arms inside. *)
       (match deadline ~parameter:"call_timeout_s" call_timeout_s with
        | Error error -> Error error
        | Ok Http_client.Unbounded -> Provider_admission.with_admission ~config measured
        | Ok (Http_client.Bounded (call_clock, call_timeout_s)) ->
          let exceeded = deadline_exceeded ~parameter:"call_timeout_s" ~seconds:call_timeout_s in
          (match
             Provider_admission.with_admission_and_work_until
               ?on_wait:on_permit_wait
               ~clock:call_clock
               ~deadline_at:(Eio.Time.now call_clock +. call_timeout_s)
               ~config
               measured
           with
           | Ok result -> result
           | Error Provider_admission.Permit_wait_expired ->
             permit_wait_expired ~parameter:"call_timeout_s" ~seconds:call_timeout_s
           | Error Provider_admission.Permit_granted_as_deadline_passed ->
             exceeded
               ~phase:Http_client.Queue
               ~stage:
                 "with a provider admission permit for the count-tokens request granted as \
                  the deadline passed"
           | Error Provider_admission.Work_expired ->
             exceeded
               ~phase:Http_client.Non_streaming_body
               ~stage:"during the count-tokens round trip"))
     | Stream { admission_timeout_s; first_event_timeout_s } ->
       (* Ahead of a stream the caller's bounds are the stream's: the permit
          wait ends under the admission budget as the stream's own would,
          and the count round trip is provider silence before the first
          token, so it runs under the first-event budget; a declared
          [timeout_s] still arms inside. *)
       (match deadline ~parameter:"admission_timeout_s" admission_timeout_s with
        | Error error -> Error error
        | Ok admission_deadline ->
          (match deadline ~parameter:"first_event_timeout_s" first_event_timeout_s with
           | Error error -> Error error
           | Ok first_event_deadline ->
             let round_trip () =
               match first_event_deadline with
               | Http_client.Unbounded -> measured ()
               | Http_client.Bounded (clock, first_event_timeout_s) ->
                 (match
                    Under_deadline.run clock first_event_timeout_s measured
                  with
                  | Ok result -> result
                  | Error `Timeout ->
                    deadline_exceeded
                      ~parameter:"first_event_timeout_s"
                      ~seconds:first_event_timeout_s
                      ~phase:Http_client.First_token
                      ~stage:"during the count-tokens round trip, before the stream's first token")
             in
             (match admission_deadline with
              | Http_client.Unbounded -> Provider_admission.with_admission ~config round_trip
              | Http_client.Bounded (clock, admission_timeout_s) ->
                (match
                   Provider_admission.with_admission_until
                     ?on_wait:on_permit_wait
                     ~clock
                     ~deadline_at:(Eio.Time.now clock +. admission_timeout_s)
                     ~config
                     round_trip
                 with
                 | Ok result -> result
                 | Error `Permit_wait_expired ->
                   permit_wait_expired
                     ~parameter:"admission_timeout_s"
                     ~seconds:admission_timeout_s)))))
;;

let measure
      ?connection_cache
      ?clock
      ?timeout_s
      ~next_stage
      ?on_permit_wait
      ~sw
      ~net
      (serialized : serialized)
  =
  let prepared = serialized.prepared in
  Result.map
    (fun measured -> { measured with admitted_body = Some serialized.admitted_body })
    (measure_prepared
       ?connection_cache
       ?clock
       ?timeout_s
       ~next_stage
       ?on_permit_wait
       ~sw
       ~net
       prepared)
;;

let attach_measurement
      prepared
      (measurement : Exact_output_count_tokens.completion_request_measurement)
  =
  { prepared
  ; admitted_body = None
  ; measurement =
      { input_count = measurement.input_count
      ; output_token_receipt = measurement.output_token_receipt
      }
  ; count_round_trip_s = None
  }
;;

(* Pure single source for the context-token limit. Uses only the caller-owned
   config and the exact model capability -- no network -- so a pre-knowable
   limit failure is decidable before any measurement round-trip. *)
let resolve_context_limit prepared =
  let config = prepared.request.config in
  let max_context =
    match config.max_context with
    | Some _ as explicit -> explicit
    | None ->
      Option.bind
        (Provider_config.capabilities_for_config_model config)
        (fun capabilities -> capabilities.Capabilities.max_context_tokens)
  in
  match max_context with
  | None -> Error (Context_limit_unknown { model_id = config.model_id })
  | Some max_context_tokens when max_context_tokens <= 0 ->
    Error (Invalid_context_limit { model_id = config.model_id; max_context_tokens })
  | Some max_context_tokens -> Ok max_context_tokens
;;

let serving_constraint prepared =
  Option.bind
    (Provider_config.capabilities_for_config_model prepared.request.config)
    (fun capabilities -> capabilities.Capabilities.serving_constraint)
;;

let requires_token_measurement prepared = Option.is_some (serving_constraint prepared)

let admit ~now_unix_s ~max_context_tokens measured =
  let request = measured.prepared.request in
  let { input_count; output_token_receipt } = measured.measurement in
  let input_tokens = input_count.input_tokens in
  let reserved_output_tokens =
    Types.output_token_receipt_effective output_token_receipt
  in
  match reserved_output_tokens with
  | None ->
    (* [measure_completion_request] currently returns only a required receipt.
       Keep this branch total if a future provider protocol can report an
       optional output ceiling. *)
    Error (Output_reservation_unknown { model_id = request.config.model_id })
  | Some reserved_output_tokens ->
    let fit = { input_tokens; reserved_output_tokens; max_context_tokens } in
    if
      reserved_output_tokens > max_context_tokens
      || input_tokens > max_context_tokens - reserved_output_tokens
    then Error (Context_window_exceeded fit)
    else (
      match serving_constraint measured.prepared with
      | None -> Ok { measured; fit }
      | Some constraint_ ->
        (match Serving_constraint.admit ~now_unix_s ~input_tokens constraint_ with
         | Ok () -> Ok { measured; fit }
         | Error reason -> Error (Serving_constraint_rejected { constraint_; reason })))
;;

let admitted_request admitted = admitted.measured.prepared
let admitted_fit admitted = admitted.fit
let count_round_trip_s (measured : measured) = measured.count_round_trip_s

(* The stream stage reads its first-event budget from the request it was
   prepared with; the route hands it what the count round trip left. The
   admitted body is untouched: no timeout is part of the wire body. *)
let with_first_event_timeout_s first_event_timeout_s (admitted : admitted) =
  let prepared = admitted.measured.prepared in
  { admitted with
    measured =
      { admitted.measured with
        prepared =
          { request = { prepared.request with first_event_timeout_s = Some first_event_timeout_s } }
      }
  }
;;
let admitted_body admitted = admitted.measured.admitted_body
let serialized_request (serialized : serialized) = serialized.prepared
let serialized_admitted_body (serialized : serialized) = serialized.admitted_body
let admitted_body_http_codec admitted_body = admitted_body.http_codec
let admitted_body_contents admitted_body = admitted_body.body
let admitted_body_evidence admitted_body = admitted_body.evidence
