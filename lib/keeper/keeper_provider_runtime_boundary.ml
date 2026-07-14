(** Typed provider/runtime observations for SDK errors crossing from OAS into
    MASC. This boundary classifies transport facts only; it never decides a
    Keeper lifecycle transition. *)

type stream_idle_state =
  | Awaiting_first_event
  | Awaiting_first_delta
  | Streaming_answer
  | Streaming_thinking
  | Streaming_tool_call
  | Streaming_heartbeat
  | Streaming_substrate
  | Streaming_done
  | Streaming_unknown

let stream_idle_state_to_label = function
  | Awaiting_first_event -> "awaiting_first_event"
  | Awaiting_first_delta -> "awaiting_first_delta"
  | Streaming_answer -> "streaming_answer"
  | Streaming_thinking -> "streaming_thinking"
  | Streaming_tool_call -> "streaming_tool_call"
  | Streaming_heartbeat -> "streaming_heartbeat"
  | Streaming_substrate -> "streaming_substrate"
  | Streaming_done -> "streaming_done"
  | Streaming_unknown -> "streaming_unknown"
;;

let stream_idle_state_of_label = function
  | "awaiting_first_event" -> Some Awaiting_first_event
  | "awaiting_first_delta" -> Some Awaiting_first_delta
  | "streaming_answer" -> Some Streaming_answer
  | "streaming_thinking" -> Some Streaming_thinking
  | "streaming_tool_call" -> Some Streaming_tool_call
  | "streaming_heartbeat" -> Some Streaming_heartbeat
  | "streaming_substrate" -> Some Streaming_substrate
  | "streaming_done" -> Some Streaming_done
  | "streaming_unknown" -> Some Streaming_unknown
  | _ -> None
;;

let stream_idle_state_is_activity = function
  | Streaming_answer
  | Streaming_thinking
  | Streaming_tool_call
  | Streaming_heartbeat
  | Streaming_substrate -> true
  | Awaiting_first_event
  | Awaiting_first_delta
  | Streaming_done
  | Streaming_unknown -> false
;;

type timeout_phase =
  | First_token
  | Http_operation
  | Non_streaming_body
  | Stream_body
  | Stream_idle of stream_idle_state
  | Provider_step
  | Cli_stdout_idle
  | Caller_budget
  | Wall_clock
  | Capacity_backpressure
  | Unknown_timeout

let timeout_phase_to_label = function
  | First_token -> "first_token"
  | Http_operation -> "http_operation"
  | Non_streaming_body -> "non_streaming_body"
  | Stream_body -> "stream_body"
  | Stream_idle state -> "stream_idle:" ^ stream_idle_state_to_label state
  | Provider_step -> "provider_step"
  | Cli_stdout_idle -> "cli_stdout_idle"
  | Caller_budget -> "caller_budget"
  | Wall_clock -> "wall_clock"
  | Capacity_backpressure -> "capacity_backpressure"
  | Unknown_timeout -> "unknown_timeout"
;;

let timeout_phase_of_label label =
  let normalize label =
    label
    |> String.trim
    |> String.lowercase_ascii
    |> String.map (function
      | '-' | ' ' -> '_'
      | ch -> ch)
  in
  let label = normalize label in
  let stream_idle_prefix = "stream_idle:" in
  if String.starts_with ~prefix:stream_idle_prefix label
  then (
    let prefix_len = String.length stream_idle_prefix in
    String.sub label prefix_len (String.length label - prefix_len)
    |> stream_idle_state_of_label
    |> Option.map (fun state -> Stream_idle state))
  else
    match label with
    | "first_token" | "no_first_token" | "time_to_first_token" | "ttft" ->
      Some First_token
    | "http_operation" -> Some Http_operation
    | "non_streaming_body" -> Some Non_streaming_body
    | "stream_body" -> Some Stream_body
    | "stream_idle" -> Some (Stream_idle Streaming_unknown)
    | "provider_step" -> Some Provider_step
    | "cli_stdout_idle" -> Some Cli_stdout_idle
    | "caller_budget" -> Some Caller_budget
    | "wall_clock" | "wall_clock_timeout" | "wall_exceeded" | "max_execution_time" ->
      Some Wall_clock
    | "capacity_backpressure" | "client_capacity" | "client_capacity_full" ->
      Some Capacity_backpressure
    | "unknown_timeout" -> Some Unknown_timeout
    | _ -> None
;;

let timeout_phase_is_streaming_activity = function
  | Stream_idle state -> stream_idle_state_is_activity state
  | First_token
  | Http_operation
  | Non_streaming_body
  | Stream_body
  | Provider_step
  | Cli_stdout_idle
  | Caller_budget
  | Wall_clock
  | Capacity_backpressure
  | Unknown_timeout -> false
;;

type timeout_source =
  | Oas_api
  | Oas_provider

type provider_timeout =
  { phase : timeout_phase option
  ; source : timeout_source
  }

type t =
  | Provider_timeout of provider_timeout
  | Not_provider_runtime_failure

let timeout_phase_of_oas_phase phase =
  Llm_provider.Http_client.timeout_phase_to_label phase
  |> timeout_phase_of_label
;;

let suffix_after_prefix text prefix =
  if String.starts_with ~prefix text
  then
    let prefix_len = String.length prefix in
    Some (String.sub text prefix_len (String.length text - prefix_len) |> String.trim)
  else None
;;

let trim_phase_token token =
  let rec trim_right s =
    let len = String.length s in
    if len = 0
    then s
    else (
      match s.[len - 1] with
      | ':' | ',' | ';' | '.' | ')' -> trim_right (String.sub s 0 (len - 1))
      | _ -> s)
  in
  token |> String.trim |> trim_right
;;

let provider_runtime_error_timeout_phase_label ~code =
  let code = String.lowercase_ascii (String.trim code) in
  let code_phase =
    match suffix_after_prefix code "provider_error_timeout:" with
    | Some label -> Some label
    | None -> suffix_after_prefix code "provider_error_network:timeout:"
  in
  match Option.map trim_phase_token code_phase with
  | Some phase when not (String.equal phase "") -> Some phase
  | Some _ | None -> None
;;

let provider_runtime_error_looks_like_timeout ~code =
  let code = String.lowercase_ascii (String.trim code) in
  String.equal code "provider_error_timeout"
  || String.starts_with ~prefix:"provider_error_timeout:" code
  || String.equal code "provider_error_network:timeout"
  || String.starts_with ~prefix:"provider_error_network:timeout:" code
;;

let classify_provider_runtime_error_record ~code ~detail =
  ignore detail;
  if provider_runtime_error_looks_like_timeout ~code
  then
    Provider_timeout
      { source = Oas_provider
      ; phase =
        (Option.bind
           (provider_runtime_error_timeout_phase_label ~code)
           timeout_phase_of_label)
      }
  else Not_provider_runtime_failure
;;

let provider_timeout ~source ~phase =
  Provider_timeout { source; phase }
;;

let classify_masc_internal_error = function
  | Some
      ( Keeper_internal_error.Runtime_exhausted _
      | Keeper_internal_error.Capacity_backpressure _
      | Keeper_internal_error.Resumable_cli_session _
      | Keeper_internal_error.Accept_rejected _
      | Keeper_internal_error.Internal_unhandled_exception _
      | Keeper_internal_error.Internal_bridge_exception _
      | Keeper_internal_error.Internal_contract_rejected _
      | Keeper_internal_error.Receipt_persistence_failed _ )
  | None ->
    Not_provider_runtime_failure
;;

let classify_provider_error = function
  | Llm_provider.Error.Timeout { timeout_phase; _ } ->
    provider_timeout
      ~source:Oas_provider
      ~phase:(Option.bind timeout_phase timeout_phase_of_oas_phase)
  | Llm_provider.Error.NetworkError { timeout_phase = Some phase; _ } ->
    provider_timeout
      ~source:Oas_provider
      ~phase:(timeout_phase_of_oas_phase phase)
  | Llm_provider.Error.MissingApiKey _
  | Llm_provider.Error.InvalidConfig _
  | Llm_provider.Error.ParseError _
  | Llm_provider.Error.UnknownVariant _
  | Llm_provider.Error.ProviderUnavailable _
  | Llm_provider.Error.RateLimit _
  | Llm_provider.Error.HardQuota _
  | Llm_provider.Error.CapacityExhausted _
  | Llm_provider.Error.AuthError _
  | Llm_provider.Error.AuthorizationError _
  | Llm_provider.Error.ServerError _
  | Llm_provider.Error.NetworkError _
  | Llm_provider.Error.InvalidRequest _
  | Llm_provider.Error.NotFound _
  | Llm_provider.Error.ProviderTerminal _ ->
    Not_provider_runtime_failure
;;

let classify_sdk_error (err : Agent_sdk.Error.sdk_error) : t =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some _ as internal_error -> classify_masc_internal_error internal_error
  | None ->
    (match err with
     | Agent_sdk.Error.Api (Timeout _) ->
       provider_timeout ~source:Oas_api ~phase:None
     | Agent_sdk.Error.Provider provider_error ->
       classify_provider_error provider_error
     | Agent_sdk.Error.Api (NetworkError _ | Overloaded _ | ServerError _
       | RateLimited _ | AuthError _ | AuthorizationError _ | PaymentRequired _
       | InvalidRequest _ | NotFound _ | ContextOverflow _)
     | Agent_sdk.Error.Agent _
     | Agent_sdk.Error.Mcp _
     | Agent_sdk.Error.Config _
     | Agent_sdk.Error.Serialization _
     | Agent_sdk.Error.Io _
     | Agent_sdk.Error.Orchestration _
     | Agent_sdk.Error.Internal _ ->
       Not_provider_runtime_failure)
;;

let is_provider_timeout = function
  | Provider_timeout _ -> true
  | Not_provider_runtime_failure -> false
;;

let is_provider_timeout_error err =
  classify_sdk_error err |> is_provider_timeout
;;
