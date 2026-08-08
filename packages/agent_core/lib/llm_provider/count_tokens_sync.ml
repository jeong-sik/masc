let count_tokens_url (config : Provider_config.t) =
  match String.index_opt config.request_path '?' with
  | None -> config.base_url ^ config.request_path ^ "/count_tokens"
  | Some query_start ->
    let path = String.sub config.request_path 0 query_start in
    let query =
      String.sub
        config.request_path
        query_start
        (String.length config.request_path - query_start)
    in
    config.base_url ^ path ^ "/count_tokens" ^ query
;;

type measurement_transport_stage =
  | Measurement_before_dispatch
  | Measurement_dispatch_started
  | Measurement_response_received of int

type count_dispatch_error =
  | Count_failed of Input_token_count.error * measurement_transport_stage

let transport_error_stage = function
  | Http_client.Before_dispatch_error error -> Measurement_before_dispatch, error
  | Http_client.Dispatch_started_error error -> Measurement_dispatch_started, error
  | Http_client.Response_received_error { status; error } ->
    Measurement_response_received status, error
;;

let count_anthropic_staged
      ?connection_cache
      ?clock
      ?timeout_s
      ~sw:_
      ~net
      ~(config : Provider_config.t)
      ~messages
      ?(tools = [])
      ()
  =
  let protocol = Input_token_count.Anthropic_messages_count_tokens in
  match config.kind with
  | Provider_config.Anthropic | Provider_config.Kimi ->
    let request_body =
      try
        Ok (Backend_anthropic.build_count_tokens_request ~config ~messages ~tools ())
      with
      | Invalid_argument reason -> Error (Http_client.AcceptRejected { reason })
    in
    let result =
      match request_body with
      | Error error ->
        Error
          (Count_failed (Input_token_count.Transport error, Measurement_before_dispatch))
      | Ok body ->
        let transport =
          Http_client.post_sync_once_with_evidence
            ?cache:connection_cache
            ?clock
            ?body_timeout_s:timeout_s
            ~net
            ~url:(count_tokens_url config)
            ~headers:
              (config.headers
               @ Provider_config.auth_headers_for_config config
               @ [ "Content-Type", "application/json"
                 ; "Content-Length", string_of_int (String.length body)
                 ])
            ~body
            ()
        in
        (match transport with
         | Error transport_error ->
           let stage, error = transport_error_stage transport_error in
           Error (Count_failed (Input_token_count.Transport error, stage))
         | Ok (response, _) ->
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
             ~protocol
             ~model_id:config.model_id
             response_body
           |> Result.map_error (fun error ->
             Count_failed (error, Measurement_response_received response.status)))
    in
    result
  | Provider_config.OpenAI_compat
  | Provider_config.Ollama
  | Provider_config.Gemini
  | Provider_config.Glm
  | Provider_config.DashScope ->
    Error
      (Count_failed
         ( Input_token_count.Unsupported { protocol; model_id = config.model_id }
         , Measurement_before_dispatch ))
;;

let count_anthropic
      ?connection_cache
      ?clock
      ?timeout_s
      ~sw
      ~net
      ~config
      ~messages
      ?tools
      ()
  =
  match
    count_anthropic_staged
      ?connection_cache
      ?clock
      ?timeout_s
      ~sw
      ~net
      ~config
      ~messages
      ?tools
      ()
  with
  | Ok count -> Ok count
  | Error (Count_failed (error, _)) -> Error error
;;

type completion_request_measurement =
  { input_count : Input_token_count.count
  ; output_token_receipt : Types.output_token_receipt
  }

type completion_request_error =
  | Input_count_failed of Input_token_count.error
  | Output_token_resolution_failed of Types.required_output_token_error
  | Invalid_completion_request of string

type completion_request_dispatch_error =
  | Completion_request_failed of completion_request_error * measurement_transport_stage

let supports_completion_request_measurement (config : Provider_config.t) =
  match config.kind with
  | Provider_config.Anthropic | Provider_config.Kimi -> true
  | Provider_config.OpenAI_compat
  | Provider_config.Ollama
  | Provider_config.Gemini
  | Provider_config.Glm
  | Provider_config.DashScope -> false
;;

let measure_completion_request_staged
      ?connection_cache
      ?clock
      ?timeout_s
      ~sw
      ~net
      (request : Llm_transport.completion_request)
  =
  let config = request.config in
  if supports_completion_request_measurement config
  then (
    let output_token_receipt =
      Backend_anthropic.required_output_token_receipt config
      |> Result.map_error (fun error ->
        Completion_request_failed
          (Output_token_resolution_failed error, Measurement_before_dispatch))
    in
    match output_token_receipt with
    | Error _ as error -> error
    | Ok output_token_receipt ->
      (match
         count_anthropic_staged
           ?connection_cache
           ?clock
           ?timeout_s
           ~sw
           ~net
           ~config
           ~messages:request.messages
           ~tools:request.tools
           ()
       with
       | Error (Count_failed (error, stage)) ->
         Error (Completion_request_failed (Input_count_failed error, stage))
       | Ok input_count -> Ok { input_count; output_token_receipt }))
  else
    Error
      (Completion_request_failed
         ( Input_count_failed
             (Input_token_count.Unsupported
                { protocol = Input_token_count.Anthropic_messages_count_tokens
                ; model_id = config.model_id
                })
         , Measurement_before_dispatch ))
;;

let measure_completion_request ?connection_cache ?clock ?timeout_s ~sw ~net request =
  match
    measure_completion_request_staged ?connection_cache ?clock ?timeout_s ~sw ~net request
  with
  | Ok measurement -> Ok measurement
  | Error (Completion_request_failed (error, _)) -> Error error
;;
