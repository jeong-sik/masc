(** Typed provider/runtime observations for agent-core errors crossing from AGENT_CORE into
    MASC. This boundary classifies transport facts only; it never decides a
    Keeper lifecycle transition. *)

type stream_production =
  | Streaming_answer
  | Streaming_thinking
  | Streaming_tool_call
  | Streaming_heartbeat
  | Streaming_substrate
  | Streaming_done
  | Streaming_unknown

let stream_production_of_label = function
  | "streaming_answer" -> Some Streaming_answer
  | "streaming_thinking" -> Some Streaming_thinking
  | "streaming_tool_call" -> Some Streaming_tool_call
  | "streaming_heartbeat" -> Some Streaming_heartbeat
  | "streaming_substrate" -> Some Streaming_substrate
  | "streaming_done" -> Some Streaming_done
  | "streaming_unknown" -> Some Streaming_unknown
  | _ -> None
;;

type timeout_phase =
  | First_token
  | Http_operation
  | Non_streaming_body
  | Stream_body
  | Stream_idle of stream_production
  | Provider_step
  | Cli_stdout_idle
  | Caller_budget
  | Wall_clock
  | Capacity_backpressure
  | Queue
  | Unknown_timeout

let timeout_phase_label phase =
  let module Http = Llm_provider.Http_client in
  let label = Http.timeout_phase_to_label in
  match phase with
  | First_token -> label Http.First_token
  | Http_operation -> label Http.Http_operation
  | Non_streaming_body -> label Http.Non_streaming_body
  | Stream_body -> label Http.Stream_body
  | Stream_idle production ->
    let production =
      match production with
      | Streaming_answer -> Http.Streaming_answer
      | Streaming_thinking -> Http.Streaming_thinking
      | Streaming_tool_call -> Http.Streaming_tool_call
      | Streaming_heartbeat -> Http.Streaming_heartbeat
      | Streaming_substrate -> Http.Streaming_substrate
      | Streaming_done -> Http.Streaming_done
      | Streaming_unknown -> Http.Streaming_unknown
    in
    label (Http.Stream_idle production)
  | Provider_step -> label Http.Provider_step
  | Cli_stdout_idle -> label Http.Cli_stdout_idle
  | Caller_budget -> "caller_budget"
  | Wall_clock -> label Http.Wall_clock
  | Capacity_backpressure -> label Http.Capacity_backpressure
  | Queue -> label Http.Queue
  | Unknown_timeout -> label Http.Unknown_timeout
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
    |> stream_production_of_label
    |> Option.map (fun production -> Stream_idle production))
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
    | "queue" -> Some Queue
    | "unknown_timeout" -> Some Unknown_timeout
    | _ -> None
;;

type timeout_source = Keeper_turn_terminal_code.timeout_source =
  | Agent_core_api
  | Agent_core_provider

type provider_timeout =
  { phase : timeout_phase option
  ; source : timeout_source
  }

type t =
  | Provider_timeout of provider_timeout
  | Not_provider_runtime_failure

(* Direct variant-to-variant translation (RFC-0371 B12): this used to render
   the agent-core phase to its label and re-parse the label into the MASC
   vocabulary — a typed->string->typed round trip inside one function. Both
   matches are exhaustive and total, so a new constructor on either side is
   a compile error here. *)
let stream_production_of_agent_core :
      Llm_provider.Http_client.stream_production -> stream_production
  = function
  | Llm_provider.Http_client.Streaming_answer -> Streaming_answer
  | Streaming_thinking -> Streaming_thinking
  | Streaming_tool_call -> Streaming_tool_call
  | Streaming_heartbeat -> Streaming_heartbeat
  | Streaming_substrate -> Streaming_substrate
  | Streaming_done -> Streaming_done
  | Streaming_unknown -> Streaming_unknown
;;

let timeout_phase_of_agent_core_phase :
      Llm_provider.Http_client.timeout_phase -> timeout_phase
  = function
  | Llm_provider.Http_client.First_token -> First_token
  | Http_operation -> Http_operation
  | Non_streaming_body -> Non_streaming_body
  | Stream_body -> Stream_body
  | Stream_idle production -> Stream_idle (stream_production_of_agent_core production)
  | Provider_step -> Provider_step
  | Cli_stdout_idle -> Cli_stdout_idle
  | Wall_clock -> Wall_clock
  | Capacity_backpressure -> Capacity_backpressure
  | Unknown_timeout -> Unknown_timeout
  (* [Queue] is the wait for a provider admission permit that ran out of its
     bound with nothing sent: the keeper's sub-call, and since the stream
     admission bound its turn attempts, produce it. *)
  | Queue -> Queue
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
    match
      suffix_after_prefix
        code
        Keeper_terminal_reason.wire_provider_error_timeout_prefix
    with
    | Some label -> Some label
    | None ->
      suffix_after_prefix
        code
        Keeper_terminal_reason.wire_provider_error_network_timeout_prefix
  in
  match Option.map trim_phase_token code_phase with
  | Some phase when not (String.equal phase "") -> Some phase
  | Some _ | None -> None
;;

let provider_runtime_error_looks_like_timeout ~code =
  let code = String.lowercase_ascii (String.trim code) in
  String.equal code Keeper_terminal_reason.wire_provider_error_timeout
  || String.starts_with
       ~prefix:Keeper_terminal_reason.wire_provider_error_timeout_prefix
       code
  || String.equal code Keeper_terminal_reason.wire_provider_error_network_timeout
  || String.starts_with
       ~prefix:Keeper_terminal_reason.wire_provider_error_network_timeout_prefix
       code
;;

let classify_provider_runtime_error_record ?agent_core_timeout ~code ~detail () =
  ignore detail;
  (* Typed observation first (RFC-0371 §6.1(3)): records built while the
     original agent-core error was in hand carry it, and no string is
     consulted. The prefix parse below survives only for records rehydrated
     from persisted wire, where the string is all that remains. *)
  match agent_core_timeout with
  | Some { Keeper_turn_terminal_code.source; phase } ->
    Provider_timeout
      { source
      ; phase = Option.map timeout_phase_of_agent_core_phase phase
      }
  | None ->
    if provider_runtime_error_looks_like_timeout ~code
    then
      Provider_timeout
        { source = Agent_core_provider
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
      | Keeper_internal_error.Incomplete_tool_transcript _
      | Keeper_internal_error.Terminal_effect_failed _
      | Keeper_internal_error.Provider_attempt_effect_fenced _
      | Keeper_internal_error.Tool_correction_lost _
      (* Neither is a provider-runtime timeout: the host stopped the turn, or
         the client's transport closed. [ProviderUnavailable] answered the
         same before RFC-0454 P2 typed the second one. *)
      | Keeper_internal_error.Host_stopped_turn _
      | Keeper_internal_error.Runtime_connection_closed _
      | Keeper_internal_error.Receipt_persistence_failed _
      | Keeper_internal_error.Gate_replay_repair_required _ )
  | None ->
    Not_provider_runtime_failure
;;

let classify_provider_error = function
  | Llm_provider.Error.Timeout { timeout_phase; _ } ->
    provider_timeout
      ~source:Agent_core_provider
      ~phase:(Option.map timeout_phase_of_agent_core_phase timeout_phase)
  | Llm_provider.Error.NetworkError { timeout_phase = Some phase; _ } ->
    provider_timeout
      ~source:Agent_core_provider
      ~phase:(Some (timeout_phase_of_agent_core_phase phase))
  | Llm_provider.Error.MissingApiKey _
  | Llm_provider.Error.InvalidConfig _
  | Llm_provider.Error.ParseError _
  | Llm_provider.Error.ProviderWireError _
  | Llm_provider.Error.ProviderReportedError _
  | Llm_provider.Error.UnknownVariant _
  | Llm_provider.Error.ProviderUnavailable _
  | Llm_provider.Error.EmptyCompletion _
  | Llm_provider.Error.RepeatingGeneration _
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

let classify_core_error (err : Agent_core.Error.t) : t =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some _ as internal_error -> classify_masc_internal_error internal_error
  | None ->
    (match err with
     | Agent_core.Error.Api (Timeout { phase; _ }) ->
       provider_timeout ~source:Agent_core_api
         ~phase:(Option.map timeout_phase_of_agent_core_phase phase)
     | Agent_core.Error.Provider provider_error ->
       classify_provider_error provider_error
     | Agent_core.Error.Api (NetworkError _ | Overloaded _ | ServerError _
       | RateLimited _ | AuthError _ | AuthorizationError _ | PaymentRequired _
       | InvalidRequest _ | NotFound _ | ContextOverflow _ | InputCapacity _)
     | Agent_core.Error.Agent _
     | Agent_core.Error.Mcp _
     | Agent_core.Error.Config _
     | Agent_core.Error.Serialization _
     | Agent_core.Error.Io _
     | Agent_core.Error.Orchestration _
     | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried { message = _; _ } ->
       Not_provider_runtime_failure)
;;

let is_provider_timeout = function
  | Provider_timeout _ -> true
  | Not_provider_runtime_failure -> false
;;

let is_provider_timeout_error err =
  classify_core_error err |> is_provider_timeout
;;
