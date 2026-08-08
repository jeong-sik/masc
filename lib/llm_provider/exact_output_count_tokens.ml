type completion_request_measurement =
  { input_count : Input_token_count.count
  ; output_token_receipt : Types.output_token_receipt
  }

type completion_request_error =
  | Input_count_failed of Input_token_count.error
  | Output_token_resolution_failed of Types.required_output_token_error
  | Invalid_completion_request of string

type measurement_transport_stage =
  | Measurement_before_dispatch
  | Measurement_dispatch_started
  | Measurement_response_received of int

type 'callback_error completion_request_dispatch_error =
  | Completion_request_failed of completion_request_error * measurement_transport_stage
  | Before_dispatch_failed of 'callback_error

type 'callback_error measurement_dispatch_intent =
  'callback_error Exact_output_measurement_transport.dispatch_intent

let create_measurement_dispatch_intent ~commit_fence ~mark_dispatch_started =
  Exact_output_measurement_transport.create_dispatch_intent
    ~commit_fence
    ~mark_dispatch_started
;;

type exact_completion_measurement_request =
  { protocol : Input_token_count.protocol
  ; model_id : string
  ; url : string
  ; headers : (string * string) list
  ; body : string
  ; connect_timeout_s : float option
  ; body_timeout_s : float option
  ; output_token_receipt : Types.output_token_receipt
  }

type exact_completion_artifact =
  { generation_artifact : Backend_anthropic.request_artifact
  ; measurement_request : exact_completion_measurement_request
  }

let generation_serializer_invocations = Atomic.make 0

let supports_completion_request_measurement =
  Count_tokens_sync.supports_completion_request_measurement
;;

let transport_error_stage = function
  | Http_client.Before_dispatch_error error -> Measurement_before_dispatch, error
  | Http_client.Dispatch_started_error error -> Measurement_dispatch_started, error
  | Http_client.Response_received_error { status; error } ->
    Measurement_response_received status, error
;;

let count_tokens_body_of_generation_artifact generation_artifact =
  let generation_only_field = function
    | "max_tokens" | "stream" | "temperature" | "top_p" | "top_k" -> true
    | _ -> false
  in
  try
    match
      Backend_anthropic.request_payload generation_artifact |> Yojson.Safe.from_string
    with
    | `Assoc fields ->
      fields
      |> List.filter (fun (name, _) -> not (generation_only_field name))
      |> fun fields -> Ok (Yojson.Safe.to_string (`Assoc fields))
    | _ ->
      Error
        (Invalid_completion_request
           "frozen Anthropic generation artifact is not a JSON object")
  with
  | Yojson.Json_error detail -> Error (Invalid_completion_request detail)
;;

let freeze_exact_completion_artifact
      ~anthropic_thinking_control
      (request : Llm_transport.completion_request)
  =
  let config = request.config in
  let protocol = Input_token_count.Anthropic_messages_count_tokens in
  if supports_completion_request_measurement config
  then (
    try
      let generation_artifact_result =
        Backend_anthropic.build_request_artifact_with_thinking_control
          ~stream:false
          ~anthropic_thinking_control
          ~config:request.config
          ~messages:request.messages
          ~tools:request.tools
          ()
      in
      Atomic.incr generation_serializer_invocations;
      match generation_artifact_result with
      | Error error -> Error (Output_token_resolution_failed error)
      | Ok generation_artifact ->
        (match count_tokens_body_of_generation_artifact generation_artifact with
         | Error _ as error -> error
         | Ok body ->
           let measurement_request =
             { protocol
             ; model_id = config.model_id
             ; url = Count_tokens_sync.count_tokens_url config
             ; headers =
                 config.headers
                 @ Provider_config.auth_headers_for_config config
                 @ [ "Content-Type", "application/json"
                   ; "Content-Length", string_of_int (String.length body)
                   ]
             ; body
             ; connect_timeout_s = config.connect_timeout_s
             ; body_timeout_s = request.body_timeout_s
             ; output_token_receipt =
                 Backend_anthropic.request_output_token_receipt generation_artifact
             }
           in
           Ok { generation_artifact; measurement_request })
    with
    | Invalid_argument detail -> Error (Invalid_completion_request detail))
  else
    Error
      (Input_count_failed
         (Input_token_count.Unsupported { protocol; model_id = config.model_id }))
;;

let exact_completion_generation_body artifact =
  Backend_anthropic.request_payload artifact.generation_artifact
;;

let exact_completion_measurement_request artifact = artifact.measurement_request

let measure_exact_completion_request
      ?clock
      ~net
      ~dispatch_intent
      (request : exact_completion_measurement_request)
  =
  match
    Exact_output_measurement_transport.post_sync_once
      ?clock
      ?connect_timeout_s:request.connect_timeout_s
      ?body_timeout_s:request.body_timeout_s
      ~net
      ~url:request.url
      ~headers:request.headers
      ~body:request.body
      ~dispatch_intent
      ()
  with
  | Error (Exact_output_measurement_transport.Commit_failed cause) ->
    Error (Before_dispatch_failed cause)
  | Error (Exact_output_measurement_transport.Transport_failed transport_error) ->
    let stage, error = transport_error_stage transport_error in
    Error
      (Completion_request_failed
         (Input_count_failed (Input_token_count.Transport error), stage))
  | Ok response ->
    let response_body =
      if response.status >= 200 && response.status < 300
      then Ok response.body
      else
        Error
          (Http_client.HttpError
             { code = response.status
             ; body = response.body
             ; retry_after_header = response.retry_after_header
             })
    in
    Input_token_count.decode_transport_result
      ~protocol:request.protocol
      ~model_id:request.model_id
      response_body
    |> Result.map_error (fun error ->
      Completion_request_failed
        (Input_count_failed error, Measurement_response_received response.status))
    |> Result.map (fun input_count ->
      { input_count; output_token_receipt = request.output_token_receipt })
;;

module For_testing = struct
  let generation_serializer_invocation_count () =
    Atomic.get generation_serializer_invocations
  ;;
end
