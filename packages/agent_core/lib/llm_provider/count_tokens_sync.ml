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

let post_count_request
      ?connection_cache
      ?clock
      ?timeout_s
      ~net
      ~protocol
      ~(config : Provider_config.t)
      ~url
      ~headers
      ~body
      ()
  =
  let open Result.Syntax in
  let* auth_headers =
    Provider_config.resolve_auth_headers config
    |> Result.map_error (fun reason ->
      Count_failed
        ( Input_token_count.Transport (Http_client.AcceptRejected { reason })
        , Measurement_before_dispatch ))
  in
  match
    Http_client.post_sync_once_with_evidence
      ?cache:connection_cache
      ?clock
      ?body_timeout_s:timeout_s
      ~net
      ~url
      ~headers:
        (headers
         @ auth_headers
         @ [ "Content-Type", "application/json"
           ; "Content-Length", string_of_int (String.length body)
           ])
      ~body
      ()
  with
  | Error transport_error ->
    let stage, error = transport_error_stage transport_error in
    Error (Count_failed (Input_token_count.Transport error, stage))
  | Ok receipt ->
    let response = receipt.Http_client.response in
    let response_body =
      if response.status >= 200 && response.status < 300
      then Ok response.body
      else
        Error
          (Http_client.HttpError
             { code = response.status
             ; body = receipt.body_receipt
             ; retry_after_header = response.retry_after_header
             })
    in
    Input_token_count.decode_transport_result
      ~protocol
      ~model_id:config.model_id
      response_body
    |> Result.map_error (fun error ->
      Count_failed (error, Measurement_response_received response.status))
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
    (match Backend_anthropic.build_count_tokens_request ~config ~messages ~tools () with
     | exception Invalid_argument reason ->
       Error
         (Count_failed
            ( Input_token_count.Transport (Http_client.AcceptRejected { reason })
            , Measurement_before_dispatch ))
     | body ->
       post_count_request
         ?connection_cache
         ?clock
         ?timeout_s
         ~net
         ~protocol
         ~config
         ~url:(count_tokens_url config)
         ~headers:(Backend_anthropic.request_headers ~body config.headers)
         ~body
         ())
  | Provider_config.OpenAI_compat
  | Provider_config.Ollama
  | Provider_config.Gemini
  | Provider_config.Glm ->
    Error
      (Count_failed
         ( Input_token_count.Unsupported { protocol; model_id = config.model_id }
         , Measurement_before_dispatch ))
;;

(* Gemini [models/{model}:countTokens] counts a whole
   [generateContentRequest]: system instruction, tools and generation config
   included. The body is the one {!Backend_gemini.build_request} produces for
   the same messages and tools, so the count is of the request the dispatch
   sends. Ref: aistudio.google.com/api-reference/tokens. *)
let gemini_count_tokens_url (config : Provider_config.t) =
  Printf.sprintf "%s/models/%s:countTokens" config.base_url config.model_id
;;

let gemini_count_tokens_body ~(config : Provider_config.t) ~messages ~tools =
  match Backend_gemini.build_request ~config ~messages ~tools () |> Yojson.Safe.from_string with
  | `Assoc fields ->
    Ok
      (Yojson.Safe.to_string
         (`Assoc
             [ ( "generateContentRequest"
               , `Assoc (("model", `String ("models/" ^ config.model_id)) :: fields) )
             ]))
  | _ ->
    Error (Http_client.AcceptRejected { reason = "Gemini request body is not a JSON object" })
  | exception Invalid_argument reason -> Error (Http_client.AcceptRejected { reason })
  | exception Yojson.Json_error reason -> Error (Http_client.AcceptRejected { reason })
;;

let count_gemini_staged
      ?connection_cache
      ?clock
      ?timeout_s
      ~net
      ~(config : Provider_config.t)
      ~messages
      ~tools
      ()
  =
  let protocol = Input_token_count.Gemini_count_tokens in
  match gemini_count_tokens_body ~config ~messages ~tools with
  | Error error ->
    Error (Count_failed (Input_token_count.Transport error, Measurement_before_dispatch))
  | Ok body ->
    post_count_request
      ?connection_cache
      ?clock
      ?timeout_s
      ~net
      ~protocol
      ~config
      ~url:(gemini_count_tokens_url config)
      ~headers:config.headers
      ~body
      ()
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
  | Provider_config.Anthropic | Provider_config.Kimi | Provider_config.Gemini -> true
  | Provider_config.OpenAI_compat | Provider_config.Ollama | Provider_config.Glm -> false
;;

let measure_completion_request_staged
      ?connection_cache
      ?clock
      ?timeout_s
      ~sw
      ~net
      (request : Llm_transport.completion_request)
  =
  let config = Provider_config.freeze_for_request request.config in
  let before_dispatch error =
    Error (Completion_request_failed (error, Measurement_before_dispatch))
  in
  let with_input_count output_token_receipt = function
    | Error (Count_failed (error, stage)) ->
      Error (Completion_request_failed (Input_count_failed error, stage))
    | Ok input_count -> Ok { input_count; output_token_receipt }
  in
  match config.kind with
  | Provider_config.Anthropic | Provider_config.Kimi ->
    (match Backend_anthropic.required_output_token_receipt config with
     | Error error -> before_dispatch (Output_token_resolution_failed error)
     | Ok output_token_receipt ->
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
       |> with_input_count output_token_receipt)
  | Provider_config.Gemini ->
    (match
       Input_budget.resolve_output_token_receipt
         ~envelope:
           (Provider_http_codec.output_token_envelope
              Provider_http_codec.gemini_generate_content)
         config
     with
     | Error error -> before_dispatch (Output_token_resolution_failed error)
     | Ok output_token_receipt ->
       count_gemini_staged
         ?connection_cache
         ?clock
         ?timeout_s
         ~net
         ~config
         ~messages:request.messages
         ~tools:request.tools
         ()
       |> with_input_count output_token_receipt)
  | Provider_config.OpenAI_compat | Provider_config.Ollama | Provider_config.Glm ->
    before_dispatch
      (Input_count_failed
         (Input_token_count.Unsupported
            { protocol = Input_token_count.Anthropic_messages_count_tokens
            ; model_id = config.model_id
            }))
;;

let measure_completion_request ?connection_cache ?clock ?timeout_s ~sw ~net request =
  match
    measure_completion_request_staged ?connection_cache ?clock ?timeout_s ~sw ~net request
  with
  | Ok measurement -> Ok measurement
  | Error (Completion_request_failed (error, _)) -> Error error
;;
