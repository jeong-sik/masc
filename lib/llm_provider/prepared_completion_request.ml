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

let measure_prepared ?connection_cache ?clock ?timeout_s ~sw ~net prepared =
  let config = prepared.request.Llm_transport.config in
  let measured () =
    Count_tokens_sync.measure_completion_request
      ?connection_cache
      ?clock
      ?timeout_s
      ~sw
      ~net
      prepared.request
    |> Result.map (fun (measurement : Count_tokens_sync.completion_request_measurement) ->
      { prepared
      ; admitted_body = None
      ; measurement =
          { input_count = measurement.input_count
          ; output_token_receipt = measurement.output_token_receipt
          }
      })
  in
  match Complete_common.validate_all config with
  | Error (Http_client.AcceptRejected { reason }) ->
    Error (Count_tokens_sync.Invalid_completion_request reason)
  | Error error ->
    Error (Count_tokens_sync.Input_count_failed (Input_token_count.Transport error))
  | Ok () -> Provider_admission.with_admission ~config measured
;;

let measure ?connection_cache ?clock ?timeout_s ~sw ~net (serialized : serialized) =
  let prepared = serialized.prepared in
  Result.map
    (fun measured -> { measured with admitted_body = Some serialized.admitted_body })
    (measure_prepared ?connection_cache ?clock ?timeout_s ~sw ~net prepared)
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
let admitted_body admitted = admitted.measured.admitted_body
let serialized_request (serialized : serialized) = serialized.prepared
let admitted_body_http_codec admitted_body = admitted_body.http_codec
let admitted_body_contents admitted_body = admitted_body.body
let admitted_body_evidence admitted_body = admitted_body.evidence
