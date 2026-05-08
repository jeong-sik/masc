(** OAS Event_bus → SSE Bridge.

    Subscribes to all events on the OAS Event_bus (both MASC Custom
    events and OAS native lifecycle events) and relays them as SSE
    broadcasts to connected dashboard clients.

    OAS native events (ToolCalled, TurnCompleted, etc.) are serialized
    to a uniform JSON format with an "oas:" prefix so consumers can
    distinguish them from MASC-originated events.

    Since OAS 0.123.0 every event carries an envelope with
    [correlation_id], [run_id], and [ts]. These are always emitted
    in the SSE JSON so downstream consumers can join events into
    causal chains offline.

    @since 2.96.0
    @modified 2.255.0 — accept OAS native events (#5620)
    @modified 2.260.0 — emit envelope correlation_id/run_id (oas#845) *)

(** Drain interval: how often we poll the Event_bus subscription.
    Lower default keeps the dashboard close to real-time, while staying
    runtime-tunable for quieter deployments. *)
let drain_interval_s () = Env_config.Oas_sse.drain_interval_sec

let json_string_opt = function
  | Some value when String.trim value <> "" -> `String value
  | _ -> `Null

let payload_string_opt key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String value) when String.trim value <> "" -> Some value
      | _ -> None)
  | _ -> None

let payload_int_opt key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Int value) -> Some value
      | Some (`Intlit value) -> int_of_string_opt value
      | _ -> None)
  | _ -> None

let inference_model_bucket ~provider ~model =
  let has needle =
    String_util.contains_substring_ci provider needle
    || String_util.contains_substring_ci model needle
  in
  if has "kimi" then "kimi"
  else if has "claude" || has "anthropic" then "anthropic"
  else if has "openai" || has "gpt" || has "codex" then "openai"
  else if has "gemini" || has "google" then "gemini"
  else if has "glm" || has "zai" then "glm"
  else if has "qwen" then "qwen"
  else if has "llama" then "llama"
  else "other"

let inference_token_bucket = function
  | None -> "missing"
  | Some tokens when tokens <= 0 -> "0"
  | Some tokens when tokens <= 1024 -> "1_1k"
  | Some tokens when tokens <= 8192 -> "1k_8k"
  | Some _ -> "over_8k"

let positive_finite value =
  value > 0.0
  && match classify_float value with
  | FP_nan | FP_infinite -> false
  | FP_normal | FP_subnormal | FP_zero -> true

let observe_inference_tokens ~model_bucket ~phase tokens =
  let labels =
    [
      ("model_bucket", model_bucket);
      ("phase", phase);
      ("token_bucket", inference_token_bucket tokens);
    ]
  in
  let value =
    match tokens with
    | Some tokens when tokens > 0 -> float_of_int tokens
    | _ -> 0.0
  in
  Prometheus.observe_histogram Prometheus.metric_oas_inference_telemetry_tokens
    ~labels value

let tok_per_sec_from_ms ~tokens ~ms =
  match (tokens, ms) with
  | Some tokens, Some ms when tokens > 0 && positive_finite ms ->
      Some (float_of_int tokens /. (ms /. 1000.0))
  | _ -> None

let observe_inference_rate metric ~model_bucket = function
  | Some rate when positive_finite rate ->
      Prometheus.observe_histogram metric
        ~labels:[ ("model_bucket", model_bucket) ]
        rate
  | _ -> ()

let observe_inference_telemetry ~provider ~model ~prompt_tokens
    ~completion_tokens ~prompt_ms ~decode_ms ~decode_tok_s =
  let model_bucket =
    inference_model_bucket ~provider ~model
  in
  observe_inference_tokens ~model_bucket ~phase:"prompt"
    prompt_tokens;
  observe_inference_tokens ~model_bucket ~phase:"completion"
    completion_tokens;
  observe_inference_rate Prometheus.metric_oas_inference_prompt_tok_per_sec
    ~model_bucket
    (tok_per_sec_from_ms ~tokens:prompt_tokens ~ms:prompt_ms);
  let decode_tok_s =
    match decode_tok_s with
    | Some rate when positive_finite rate -> Some rate
    | _ ->
        tok_per_sec_from_ms ~tokens:completion_tokens ~ms:decode_ms
  in
  observe_inference_rate Prometheus.metric_oas_inference_decode_tok_per_sec
    ~model_bucket decode_tok_s

let observe_inference_cost ~model_bucket = function
  | Some cost when positive_finite cost ->
      Prometheus.observe_histogram Prometheus.metric_oas_inference_cost_usd
        ~labels:[ ("model_bucket", model_bucket) ]
        cost
  | _ -> ()

let stop_reason_to_wire = function
  | Agent_sdk.Types.EndTurn -> "end_turn"
  | Agent_sdk.Types.StopToolUse -> "tool_use"
  | Agent_sdk.Types.MaxTokens -> "max_tokens"
  | Agent_sdk.Types.StopSequence -> "stop_sequence"
  | Agent_sdk.Types.Unknown value -> value

let agent_completed_usage_fields (response : Agent_sdk.Types.api_response) =
  match response.usage with
  | None -> [ ("usage_reported", `Bool false) ]
  | Some usage ->
      [
        ("usage_reported", `Bool true);
        ("input_tokens", `Int usage.input_tokens);
        ("output_tokens", `Int usage.output_tokens);
        ( "cache_creation_input_tokens",
          `Int usage.cache_creation_input_tokens );
        ("cache_read_input_tokens", `Int usage.cache_read_input_tokens);
        ("total_tokens", `Int (usage.input_tokens + usage.output_tokens));
        ( "cost_usd",
          match usage.cost_usd with
          | Some cost -> `Float cost
          | None -> `Null );
      ]

let agent_completed_result_fields = function
  | Ok (response : Agent_sdk.Types.api_response) ->
      [
        ("success", `Bool true);
        ("result", `String "ok");
        ("response_id", `String response.id);
        ("model", `String response.model);
        ("stop_reason", `String (stop_reason_to_wire response.stop_reason));
      ]
      @ agent_completed_usage_fields response
  | Error error ->
      [
        ("success", `Bool false);
        ("result", `String "error");
        ("error", `String (Agent_sdk.Error.to_string error));
        ("usage_reported", `Bool false);
      ]

let json_float_opt = function
  | Some value -> `Float value
  | None -> `Null

let json_int_opt = function
  | Some value -> `Int value
  | None -> `Null

let network_error_kind_to_wire = function
  | Llm_provider.Http_client.Connection_refused -> "connection_refused"
  | Llm_provider.Http_client.Dns_failure -> "dns_failure"
  | Llm_provider.Http_client.Tls_error -> "tls_error"
  | Llm_provider.Http_client.Timeout -> "timeout"
  | Llm_provider.Http_client.Local_resource_exhaustion ->
      "local_resource_exhaustion"
  | Llm_provider.Http_client.End_of_file -> "end_of_file"
  | Llm_provider.Http_client.Unknown -> "unknown"

let sdk_api_error_fields = function
  | Agent_sdk.Retry.RateLimited { retry_after; message } ->
      [
        ("variant", `String "rate_limited");
        ("message", `String message);
        ("retry_after_s", json_float_opt retry_after);
      ]
  | Agent_sdk.Retry.Overloaded { message } ->
      [
        ("variant", `String "overloaded");
        ("message", `String message);
      ]
  | Agent_sdk.Retry.ServerError { status; message } ->
      [
        ("variant", `String "server_error");
        ("status", `Int status);
        ("message", `String message);
      ]
  | Agent_sdk.Retry.AuthError { message } ->
      [
        ("variant", `String "auth_error");
        ("message", `String message);
      ]
  | Agent_sdk.Retry.InvalidRequest { message } ->
      [
        ("variant", `String "invalid_request");
        ("message", `String message);
      ]
  | Agent_sdk.Retry.NotFound { message } ->
      [
        ("variant", `String "not_found");
        ("message", `String message);
      ]
  | Agent_sdk.Retry.ContextOverflow { message; limit } ->
      [
        ("variant", `String "context_overflow");
        ("message", `String message);
        ("limit", json_int_opt limit);
      ]
  | Agent_sdk.Retry.NetworkError { message; kind } ->
      [
        ("variant", `String "network_error");
        ("message", `String message);
        ("network_kind", `String (network_error_kind_to_wire kind));
      ]
  | Agent_sdk.Retry.Timeout { message } ->
      [
        ("variant", `String "timeout");
        ("message", `String message);
      ]

let sdk_agent_error_fields = function
  | Agent_sdk.Error.MaxTurnsExceeded { turns; limit } ->
      [
        ("variant", `String "max_turns_exceeded");
        ("turns", `Int turns);
        ("limit", `Int limit);
      ]
  | Agent_sdk.Error.TokenBudgetExceeded { kind; used; limit } ->
      [
        ("variant", `String "token_budget_exceeded");
        ("kind", `String kind);
        ("used", `Int used);
        ("limit", `Int limit);
      ]
  | Agent_sdk.Error.CostBudgetExceeded { spent_usd; limit_usd } ->
      [
        ("variant", `String "cost_budget_exceeded");
        ("spent_usd", `Float spent_usd);
        ("limit_usd", `Float limit_usd);
      ]
  | Agent_sdk.Error.UnrecognizedStopReason { reason } ->
      [
        ("variant", `String "unrecognized_stop_reason");
        ("reason", `String reason);
      ]
  | Agent_sdk.Error.IdleDetected { consecutive_idle_turns } ->
      [
        ("variant", `String "idle_detected");
        ("consecutive_idle_turns", `Int consecutive_idle_turns);
      ]
  | Agent_sdk.Error.ToolRetryExhausted { attempts; limit; detail } ->
      [
        ("variant", `String "tool_retry_exhausted");
        ("attempts", `Int attempts);
        ("limit", `Int limit);
        ("detail", `String detail);
      ]
  | Agent_sdk.Error.CompletionContractViolation { contract; reason } ->
      [
        ("variant", `String "completion_contract_violation");
        ( "contract",
          `String (Agent_sdk.Completion_contract_id.to_string contract) );
        ("reason", `String reason);
      ]
  | Agent_sdk.Error.GuardrailViolation { validator; reason } ->
      [
        ("variant", `String "guardrail_violation");
        ("validator", `String validator);
        ("reason", `String reason);
      ]
  | Agent_sdk.Error.TripwireViolation { tripwire; reason } ->
      [
        ("variant", `String "tripwire_violation");
        ("tripwire", `String tripwire);
        ("reason", `String reason);
      ]
  | Agent_sdk.Error.ExitConditionMet { turn } ->
      [
        ("variant", `String "exit_condition_met");
        ("turn", `Int turn);
      ]

let sdk_mcp_error_fields = function
  | Agent_sdk.Error.ServerStartFailed { command; detail } ->
      [
        ("variant", `String "server_start_failed");
        ("command", `String command);
        ("detail", `String detail);
      ]
  | Agent_sdk.Error.InitializeFailed { detail } ->
      [
        ("variant", `String "initialize_failed");
        ("detail", `String detail);
      ]
  | Agent_sdk.Error.ToolListFailed { detail } ->
      [
        ("variant", `String "tool_list_failed");
        ("detail", `String detail);
      ]
  | Agent_sdk.Error.ToolCallFailed { tool_name; detail } ->
      [
        ("variant", `String "tool_call_failed");
        ("tool_name", `String tool_name);
        ("detail", `String detail);
      ]
  | Agent_sdk.Error.HttpTransportFailed { url; detail } ->
      [
        ("variant", `String "http_transport_failed");
        ("url", `String url);
        ("detail", `String detail);
      ]

let sdk_config_error_fields = function
  | Agent_sdk.Error.MissingEnvVar { var_name } ->
      [
        ("variant", `String "missing_env_var");
        ("var_name", `String var_name);
      ]
  | Agent_sdk.Error.UnsupportedProvider { detail } ->
      [
        ("variant", `String "unsupported_provider");
        ("detail", `String detail);
      ]
  | Agent_sdk.Error.InvalidConfig { field; detail } ->
      [
        ("variant", `String "invalid_config");
        ("field", `String field);
        ("detail", `String detail);
      ]

let sdk_serialization_error_fields = function
  | Agent_sdk.Error.JsonParseError { detail } ->
      [
        ("variant", `String "json_parse_error");
        ("detail", `String detail);
      ]
  | Agent_sdk.Error.VersionMismatch { expected; got } ->
      [
        ("variant", `String "version_mismatch");
        ("expected", `Int expected);
        ("got", `Int got);
      ]
  | Agent_sdk.Error.UnknownVariant { type_name; value } ->
      [
        ("variant", `String "unknown_variant");
        ("type_name", `String type_name);
        ("value", `String value);
      ]

let sdk_io_error_fields = function
  | Agent_sdk.Error.FileOpFailed { op; path; detail } ->
      [
        ("variant", `String "file_op_failed");
        ("op", `String op);
        ("path", `String path);
        ("detail", `String detail);
      ]
  | Agent_sdk.Error.ValidationFailed { detail } ->
      [
        ("variant", `String "validation_failed");
        ("detail", `String detail);
      ]

let sdk_orchestration_error_fields = function
  | Agent_sdk.Error.UnknownAgent { name } ->
      [
        ("variant", `String "unknown_agent");
        ("name", `String name);
      ]
  | Agent_sdk.Error.TaskTimeout { task_id } ->
      [
        ("variant", `String "task_timeout");
        ("task_id", `String task_id);
      ]
  | Agent_sdk.Error.DiscoveryFailed { url; detail } ->
      [
        ("variant", `String "discovery_failed");
        ("url", `String url);
        ("detail", `String detail);
      ]

let sdk_a2a_error_fields = function
  | Agent_sdk.Error.TaskNotFound { task_id } ->
      [
        ("variant", `String "task_not_found");
        ("task_id", `String task_id);
      ]
  | Agent_sdk.Error.InvalidTransition { task_id; from_state; to_state } ->
      [
        ("variant", `String "invalid_transition");
        ("task_id", `String task_id);
        ("from_state", `String from_state);
        ("to_state", `String to_state);
      ]
  | Agent_sdk.Error.MessageSendFailed { task_id; detail } ->
      [
        ("variant", `String "message_send_failed");
        ("task_id", `String task_id);
        ("detail", `String detail);
      ]
  | Agent_sdk.Error.ProtocolError { detail } ->
      [
        ("variant", `String "protocol_error");
        ("detail", `String detail);
      ]
  | Agent_sdk.Error.StoreCapacityExceeded { current; max } ->
      [
        ("variant", `String "store_capacity_exceeded");
        ("current", `Int current);
        ("max", `Int max);
      ]

let sdk_error_detail_fields (error : Agent_sdk.Error.sdk_error) =
  match error with
  | Agent_sdk.Error.Api error -> sdk_api_error_fields error
  | Agent_sdk.Error.Agent error -> sdk_agent_error_fields error
  | Agent_sdk.Error.Mcp error -> sdk_mcp_error_fields error
  | Agent_sdk.Error.Config error -> sdk_config_error_fields error
  | Agent_sdk.Error.Serialization error -> sdk_serialization_error_fields error
  | Agent_sdk.Error.Io error -> sdk_io_error_fields error
  | Agent_sdk.Error.Orchestration error -> sdk_orchestration_error_fields error
  | Agent_sdk.Error.A2a error -> sdk_a2a_error_fields error
  | Agent_sdk.Error.Internal message ->
      [
        ("variant", `String "internal");
        ("message", `String message);
      ]

let sdk_error_json error =
  let domain = Keeper_agent_error.sdk_error_kind error in
  let code = Keeper_agent_error.terminal_reason_code_of_sdk_error error in
  `Assoc
    ([
       ("domain", `String domain);
       ("code", `String code);
       ("retryable", `Bool (Agent_sdk.Error.is_retryable error));
     ]
    @ sdk_error_detail_fields error)

let agent_failed_error_fields error =
  [
    ("error", `String (Agent_sdk.Error.to_string error));
    ("error_domain", `String (Keeper_agent_error.sdk_error_kind error));
    ( "error_code",
      `String (Keeper_agent_error.terminal_reason_code_of_sdk_error error) );
    ("error_retryable", `Bool (Agent_sdk.Error.is_retryable error));
    ("error_detail", sdk_error_json error);
  ]

let payload_agent_name payload =
  (* Check [agent_name], [agent], then [keeper_name] for Custom events
     whose publisher stores the per-agent attribution under the
     keeper-specific key (e.g. [masc:keeper:snapshot],
     [masc:keeper:lifecycle]).  Without this fallback the top-level
     envelope [agent_name] is Null for 9%+ of daily events, breaking
     per-agent filters over the Dated_jsonl store under [.masc/oas-events/].
     See #7827. *)
  match payload_string_opt "agent_name" payload with
  | Some _ as value -> value
  | None ->
    (match payload_string_opt "agent" payload with
     | Some _ as value -> value
     | None -> payload_string_opt "keeper_name" payload)

let emit_native_event_log (evt : Agent_sdk.Event_bus.event) (json : Yojson.Safe.t) =
  let log_at level message =
    Log.emit level ~module_name:"oas:event" ~details:json message
  in
  let log_routine message =
    Log.emit_routine ~module_name:"oas:event" ~details:json message
  in
  let log message =
    log_at Log.Info message
  in
  match evt.payload with
  | Agent_sdk.Event_bus.AgentStarted { agent_name; task_id } ->
      log
        (Printf.sprintf "agent started agent=%s task_id=%s" agent_name task_id)
  | Agent_sdk.Event_bus.AgentCompleted { agent_name; task_id; elapsed; _ } ->
      log
        (Printf.sprintf
           "agent completed agent=%s task_id=%s elapsed_s=%.3f"
           agent_name task_id elapsed)
  | Agent_sdk.Event_bus.TurnStarted { agent_name; turn } ->
      log (Printf.sprintf "turn started agent=%s turn=%d" agent_name turn)
  | Agent_sdk.Event_bus.TurnCompleted { agent_name; turn } ->
      log (Printf.sprintf "turn completed agent=%s turn=%d" agent_name turn)
  | Agent_sdk.Event_bus.ToolCalled { agent_name; tool_name; _ } ->
      log
        (Printf.sprintf "tool called agent=%s tool_name=%s" agent_name tool_name)
  | Agent_sdk.Event_bus.ToolCompleted { agent_name; tool_name; _ } ->
      log
        (Printf.sprintf
           "tool completed agent=%s tool_name=%s"
           agent_name tool_name)
  | Agent_sdk.Event_bus.TurnReady { agent_name; turn; tool_names } ->
      (* [substrate:tool_surface] — deterministic per-turn snapshot of the
         tool list the LLM actually sees this turn (after guardrails,
         operator policy, tool_filter_override).  Emitted as a single
         grep-friendly line with a stable hash so operators can confirm
         which tools were on the LLM's surface for a given turn without
         enabling verbose tool dumps. *)
      let names_hash =
        Digest.to_hex (Digest.string (String.concat "\n" tool_names))
      in
      log_routine
        (Printf.sprintf
           "[substrate:tool_surface] agent=%s turn=%d count=%d names_hash=%s"
           agent_name turn (List.length tool_names)
           (String.sub names_hash 0 16))
  | Agent_sdk.Event_bus.ContextCompacted
      { agent_name; before_tokens; after_tokens; phase } ->
      log
        (Printf.sprintf
           "context compacted agent=%s before_tokens=%d after_tokens=%d phase=%s"
           agent_name before_tokens after_tokens phase)
  | Agent_sdk.Event_bus.ContextOverflowImminent
      { agent_name; estimated_tokens; limit_tokens; ratio } ->
      log
        (Printf.sprintf
           "context overflow imminent agent=%s estimated_tokens=%d limit_tokens=%d ratio=%.3f"
           agent_name estimated_tokens limit_tokens ratio)
  | Agent_sdk.Event_bus.ContextCompactStarted { agent_name; trigger } ->
      log
        (Printf.sprintf
           "context compact started agent=%s trigger=%s"
           agent_name trigger)
  (* Variants below previously absorbed by [_ -> ()] catch-all.  Each is
     enumerated explicitly so adding a new [Agent_sdk.Event_bus.payload]
     variant fails the build instead of silently dropping the log line. *)
  | Agent_sdk.Event_bus.AgentFailed _
  | Agent_sdk.Event_bus.HandoffRequested _
  | Agent_sdk.Event_bus.HandoffCompleted _
  | Agent_sdk.Event_bus.ElicitationCompleted _
  | Agent_sdk.Event_bus.ContentReplacementReplaced _
  | Agent_sdk.Event_bus.ContentReplacementKept _
  | Agent_sdk.Event_bus.SlotSchedulerObserved _
  | Agent_sdk.Event_bus.InferenceTelemetry _
  | Agent_sdk.Event_bus.Custom _ ->
      ()

(** Build the SSE JSON wrapper. [correlation_id] and [run_id] are
    mandatory (from the envelope); all other fields are optional. *)
let wrap_event ~ts ~correlation_id ~run_id ~event_type ~payload
    ?agent_name ?task_id ?turn ?tool_name () =
  `Assoc
    [
      ("type", `String ("oas:" ^ event_type));
      ("event_type", `String event_type);
      ("ts_unix", `Float ts);
      ("correlation_id", `String correlation_id);
      ("run_id", `String run_id);
      ("agent_name", json_string_opt agent_name);
      ("task_id", json_string_opt task_id);
      ("turn", Option.fold ~none:`Null ~some:(fun value -> `Int value) turn);
      ("tool_name", json_string_opt tool_name);
      ("payload", payload);
    ]

(** Serialize an OAS event to JSON for SSE relay + durable storage.
    Reads envelope metadata ([correlation_id], [run_id], [ts]) from
    [evt.meta] and includes them in every emitted JSON object.

    The match below intentionally combines explicit per-variant arms
    with a final [other] catch-all that produces a kind-only fallback
    via [Agent_sdk.Event_bus.payload_kind].  The catch-all is "redundant" at
    every individual snapshot of the OAS variant set (warning 11), but
    it is a deliberate future-proof against the OAS pin-bump P0 class
    (#10490, #10574, #10584).  Without the catch-all, every new
    upstream variant breaks main with [-warn-error +8] until the
    consumer is migrated; with it, the relay degrades to a
    kind-labelled placeholder + a warn log signal until an explicit
    arm is added.

    Suppressing warning 11 ([@warning "-11"]) is therefore the entire
    point of this function's shape — do not remove it without also
    removing the catch-all. *)
let native_event_to_json (evt : Agent_sdk.Event_bus.event) : Yojson.Safe.t option =
  let { Agent_sdk.Event_bus.correlation_id; run_id; ts; _ } = evt.meta in
  let wrap = wrap_event ~ts ~correlation_id ~run_id in
  match[@warning "-11"] evt.payload with
  | Agent_sdk.Event_bus.AgentStarted { agent_name; task_id } ->
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("task_id", `String task_id);
          ]
      in
      Some (wrap ~event_type:"agent_started" ~payload ~agent_name ~task_id ())
  | Agent_sdk.Event_bus.AgentCompleted { agent_name; task_id; elapsed; result } ->
      (match result with
       | Ok (response : Agent_sdk.Types.api_response) ->
           let model_bucket =
             inference_model_bucket ~provider:"" ~model:response.model
           in
           let cost_usd =
             match response.usage with
             | Some usage -> usage.cost_usd
             | None -> None
           in
           observe_inference_cost ~model_bucket cost_usd
       | Error _ -> ());
      let payload =
        `Assoc
          ([
             ("agent_name", `String agent_name);
             ("task_id", `String task_id);
             ("elapsed_s", `Float elapsed);
           ]
          @ agent_completed_result_fields result)
      in
      Some (wrap ~event_type:"agent_completed" ~payload ~agent_name ~task_id ())
  | Agent_sdk.Event_bus.AgentFailed { agent_name; task_id; error; elapsed } ->
      let payload =
        `Assoc
          ([
             ("agent_name", `String agent_name);
             ("task_id", `String task_id);
             ("elapsed_s", `Float elapsed);
           ]
          @ agent_failed_error_fields error)
      in
      Some (wrap ~event_type:"agent_failed" ~payload ~agent_name ~task_id ())
  | Agent_sdk.Event_bus.ToolCalled { agent_name; tool_name; _ } ->
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("tool_name", `String tool_name);
          ]
      in
      Some (wrap ~event_type:"tool_called" ~payload ~agent_name ~tool_name ())
  | Agent_sdk.Event_bus.ToolCompleted { agent_name; tool_name; _ } ->
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("tool_name", `String tool_name);
          ]
      in
      Some (wrap ~event_type:"tool_completed" ~payload ~agent_name ~tool_name ())
  | Agent_sdk.Event_bus.TurnStarted { agent_name; turn } ->
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("turn", `Int turn);
          ]
      in
      Some (wrap ~event_type:"turn_started" ~payload ~agent_name ~turn ())
  | Agent_sdk.Event_bus.TurnCompleted { agent_name; turn } ->
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("turn", `Int turn);
          ]
      in
      Some (wrap ~event_type:"turn_completed" ~payload ~agent_name ~turn ())
  | Agent_sdk.Event_bus.TurnReady { agent_name; turn; tool_names } ->
      let names_hash =
        Digest.to_hex (Digest.string (String.concat "\n" tool_names))
      in
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("turn", `Int turn);
            ("count", `Int (List.length tool_names));
            ("names_hash", `String (String.sub names_hash 0 16));
            ( "tool_names",
              `List (List.map (fun name -> `String name) tool_names) );
          ]
      in
      Some (wrap ~event_type:"turn_ready" ~payload ~agent_name ~turn ())
  | Agent_sdk.Event_bus.HandoffRequested { from_agent; to_agent; reason } ->
      let payload =
        `Assoc
          [
            ("from_agent", `String from_agent);
            ("to_agent", `String to_agent);
            ("reason", `String reason);
          ]
      in
      Some
        (wrap ~event_type:"handoff_requested" ~payload ~agent_name:from_agent ())
  | Agent_sdk.Event_bus.HandoffCompleted { from_agent; to_agent; elapsed } ->
      let payload =
        `Assoc
          [
            ("from_agent", `String from_agent);
            ("to_agent", `String to_agent);
            ("elapsed_s", `Float elapsed);
          ]
      in
      Some
        (wrap ~event_type:"handoff_completed" ~payload ~agent_name:from_agent ())
  | Agent_sdk.Event_bus.ContextCompacted
      { agent_name; before_tokens; after_tokens; phase } ->
      (* #9935: compaction completed — clears any pending
         imminent and fires action-taken counter. *)
      Context_overflow_action_tracker.record_action ~keeper_name:agent_name;
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("before_tokens", `Int before_tokens);
            ("after_tokens", `Int after_tokens);
            ("phase", `String phase);
          ]
      in
      Some (wrap ~event_type:"context_compacted" ~payload ~agent_name ())
  | Agent_sdk.Event_bus.ElicitationCompleted _ ->
    None  (* Internal; no SSE relay needed *)
  | Agent_sdk.Event_bus.ContextOverflowImminent
        { agent_name; estimated_tokens; limit_tokens; ratio } ->
      (* #9935: track imminent→action pairing so an unanswered
         overflow (no compact_started/compacted within grace
         window) is observable via metric + warn log, rather
         than silently burning out on oas_timeout_budget. *)
      Prometheus.set_gauge Prometheus.metric_oas_context_overflow_ratio
        ~labels:[ ("agent_name", agent_name) ]
        ratio;
      Context_overflow_action_tracker.record_imminent
        ~keeper_name:agent_name
        ~ts:(Time_compat.now ());
      let payload =
        `Assoc [
          ("agent_name", `String agent_name);
          ("estimated_tokens", `Int estimated_tokens);
          ("limit_tokens", `Int limit_tokens);
          ("ratio", `Float ratio);
        ]
      in
      Some (wrap ~event_type:"context_overflow_imminent" ~payload
              ~agent_name ())
  | Agent_sdk.Event_bus.ContextCompactStarted { agent_name; trigger } ->
      (* #9935: compaction started — clears pending imminent
         and fires action-taken counter. *)
      Context_overflow_action_tracker.record_action ~keeper_name:agent_name;
      Prometheus.inc_counter Prometheus.metric_oas_context_compaction_total
        ~labels:[ ("agent_name", agent_name); ("trigger", trigger) ] ();
      let payload =
        `Assoc [
          ("agent_name", `String agent_name);
          ("trigger", `String trigger);
        ]
      in
      Some (wrap ~event_type:"context_compact_started" ~payload
              ~agent_name ())
  | Agent_sdk.Event_bus.ContentReplacementReplaced
      { tool_use_id; preview; original_chars; seen_count_after } ->
      let payload =
        `Assoc [
          ("tool_use_id", `String tool_use_id);
          ("preview", `String preview);
          ("original_chars", `Int original_chars);
          ("seen_count_after", `Int seen_count_after);
        ]
      in
      Some (wrap ~event_type:"content_replacement_replaced" ~payload ())
  | Agent_sdk.Event_bus.ContentReplacementKept { tool_use_id; seen_count_after } ->
      let payload =
        `Assoc [
          ("tool_use_id", `String tool_use_id);
          ("seen_count_after", `Int seen_count_after);
        ]
      in
      Some (wrap ~event_type:"content_replacement_kept" ~payload ())
  | Agent_sdk.Event_bus.SlotSchedulerObserved
      { max_slots; active; available; queue_length; state } ->
      let state_str =
        match state with
        | Agent_sdk.Event_bus.Idle -> "idle"
        | Agent_sdk.Event_bus.Queued -> "queued"
        | Agent_sdk.Event_bus.Saturated -> "saturated"
      in
      let payload =
        `Assoc [
          ("max_slots", `Int max_slots);
          ("active", `Int active);
          ("available", `Int available);
          ("queue_length", `Int queue_length);
          ("state", `String state_str);
        ]
      in
      Some (wrap ~event_type:"slot_scheduler_observed" ~payload ())
  | Agent_sdk.Event_bus.Custom (name, payload) ->
      (* Wire compatibility: dashboard consumers historically decoded
         [masc:broadcast] / [masc:keeper:snapshot] (all colons).
         Internally MASC now emits dot-separated names per OAS Custom
         convention ([masc.broadcast], [masc.keeper.snapshot]).
         Translate EVERY dot to colon for [masc.*] events so existing
         SSE consumers continue to decode the full multi-segment name. *)
      let event_type =
        if String.length name > 5 && String.starts_with ~prefix:"masc." name
        then String.map (fun c -> if c = '.' then ':' else c) name
        else name
      in
      Some
        (wrap ~event_type ~payload
           ?agent_name:(payload_agent_name payload)
           ?task_id:(payload_string_opt "task_id" payload)
           ?turn:(payload_int_opt "turn" payload)
           ?tool_name:(payload_string_opt "tool_name" payload)
           ())
  | Agent_sdk.Event_bus.InferenceTelemetry
      {
        provider;
        model;
        prompt_tokens;
        completion_tokens;
        prompt_ms;
        decode_ms;
        decode_tok_s;
        _;
      } ->
      (* Per-token telemetry from OAS#1202; not surfaced over SSE. Preserve
         the aggregate signal with bounded Prometheus labels so operators can
         see model-family/token-bin trends without flooding SSE consumers or
         creating raw-model cardinality. *)
      observe_inference_telemetry ~provider ~model ~prompt_tokens
        ~completion_tokens ~prompt_ms ~decode_ms ~decode_tok_s;
      None
  | other ->
      (* Graceful fallback for OAS variants that ship before this consumer
         is migrated to an explicit shape (#10584).  Pre-fix, the match
         above was exhaustive and the OAS pin bump that introduced
         [InferenceTelemetry] (#10490) and [Stale_turn_timeout] (#10574)
         broke main with [-warn-error +8] partial-match errors.

         [Agent_sdk.Event_bus.payload_kind] is co-located with the [payload]
         variant in OAS — adding a new variant upstream forces an
         entry there in the same patch, so the snake_case label is
         always accurate.  Emit a kind-only SSE event so subscribers
         see *something happened* (with stable [event_type] for
         filtering) instead of having the whole stream fail to parse.

         [note] flags the partial-data shape so dashboards can render
         it as a placeholder rather than treating it as a complete
         payload.  The warn log gives operators a per-process signal
         that an OAS variant has shipped without a masc-mcp consumer
         migration; downstream PRs should then move the variant out
         of this catch-all into an explicit arm. *)
      let kind = Agent_sdk.Event_bus.payload_kind other in
      Log.Misc.warn
        "oas_event_bridge: kind-only fallback for unmigrated payload \
         variant kind=%s correlation_id=%s run_id=%s"
        kind correlation_id run_id;
      let payload =
        `Assoc [
          ("kind", `String kind);
          ("note", `String "kind-only fallback; consumer not yet migrated");
        ]
      in
      Some (wrap ~event_type:kind ~payload ())

let relay_max_attempts = 3
let relay_max_queue_depth = 256

type relay_stage =
  | Append
  | Broadcast

type pending_relay = {
  json : Yojson.Safe.t;
  attempts : int;
  appended : bool;
}

type relay_result =
  | Delivered
  | Retryable_failure of pending_relay * relay_stage * exn

let relay_stage_to_string = function
  | Append -> "append"
  | Broadcast -> "broadcast"

let json_field_string_opt key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String value) when String.trim value <> "" -> Some value
      | _ -> None)
  | _ -> None

let relay_event_type json =
  match json_field_string_opt "event_type" json with
  | Some value -> value
  | None ->
      (match json_field_string_opt "type" json with
       | Some value -> value
       | None -> "unknown")

let relay_event_is_presence_class json =
  match relay_event_type json with
  | "masc:keeper:snapshot" -> true
  | _ -> false

let broadcast_relay_json json =
  Sse.broadcast_to All json;
  if relay_event_is_presence_class json then
    try Sse.broadcast_presence json
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Log.Misc.warn "oas_event_bridge: presence relay failed: %s"
          (Printexc.to_string exn)

let update_relay_queue_depth pending =
  Prometheus.set_gauge Prometheus.metric_oas_sse_relay_queue_depth
    (float_of_int (List.length pending))

let emit_relay_retry_log ~(pending : pending_relay) ~(stage : relay_stage)
    ~(attempt : int) exn =
  Log.Misc.warn
    "oas_event_bridge: retrying event_type=%s stage=%s attempt=%d/%d correlation_id=%s run_id=%s error=%s"
    (relay_event_type pending.json)
    (relay_stage_to_string stage)
    attempt
    relay_max_attempts
    (Option.value
       ~default:"<none>"
       (json_field_string_opt "correlation_id" pending.json))
    (Option.value
       ~default:"<none>"
       (json_field_string_opt "run_id" pending.json))
    (Printexc.to_string exn)

let emit_relay_drop_log ~(pending : pending_relay) ~(stage_label : string)
    ~(attempts : int) =
  Log.Server.error
    "oas_event_bridge: dropping event_type=%s stage=%s attempts=%d correlation_id=%s run_id=%s"
    (relay_event_type pending.json)
    stage_label
    attempts
    (Option.value
       ~default:"<none>"
       (json_field_string_opt "correlation_id" pending.json))
    (Option.value
       ~default:"<none>"
       (json_field_string_opt "run_id" pending.json))

let broadcast_drop_marker ~(pending : pending_relay) ~(stage_label : string)
    ~(attempts : int) =
  let marker =
    `Assoc
      [
        ("type", `String "oas:relay_dropped");
        ("event_type", `String "relay_dropped");
        ("ts_unix", `Float (Time_compat.now ()));
        ( "correlation_id",
          match json_field_string_opt "correlation_id" pending.json with
          | Some value -> `String value
          | None -> `Null );
        ( "run_id",
          match json_field_string_opt "run_id" pending.json with
          | Some value -> `String value
          | None -> `Null );
        ( "agent_name",
          match json_field_string_opt "agent_name" pending.json with
          | Some value -> `String value
          | None -> `Null );
        ("failed_stage", `String stage_label);
        ("attempts", `Int attempts);
        ("original_event_type", `String (relay_event_type pending.json));
      ]
  in
  try
    Sse.broadcast_to All marker
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      (* P2 silent-failure fix: previously only logged.  The drop
         marker is the operator-visible signal that an OAS event was
         dropped after exhausting retries; if the drop marker also
         fails to broadcast, operators are blind to the drop entirely.
         Counter is distinct from masc_sse_broadcast_failures_total
         (PR-C #11075) so the recovery-path failure rate is visible
         in isolation from normal broadcast failures. *)
      Transport_metrics.inc_relay_drop_marker_failure ();
      Log.Misc.warn "oas_event_bridge: drop marker broadcast failed: %s"
        (Printexc.to_string exn)

let prepare_pending_event evt =
  match native_event_to_json evt with
  | None -> None
  | Some json ->
      (* OAS event payloads may carry tool output or user-facing text that
         contains invalid UTF-8 bytes (e.g. truncated multi-byte sequences
         from subprocess captures). Scrub once before the event enters the
         retry queue so every retry uses the same sanitized payload. *)
      let json = Inference_utils.sanitize_json_utf8 json in
      emit_native_event_log evt json;
      Some { json; attempts = 0; appended = false; }

let deliver_pending_with
    ~(append_json : Yojson.Safe.t -> unit)
    ~(broadcast_json : Yojson.Safe.t -> unit)
    (pending : pending_relay) =
  let pending =
    if pending.appended then pending
    else begin
      append_json pending.json;
      { pending with appended = true; }
    end
  in
  try
    broadcast_json pending.json;
    Delivered
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Retryable_failure (pending, Broadcast, exn)

let deliver_pending ?store_ref (pending : pending_relay) =
  let append_json =
    match store_ref with
    | None -> (fun _json -> ())
    | Some store_ref ->
        (fun json ->
           let store = !store_ref in
           try
             Dated_jsonl.append store json
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
               store_ref :=
                 Dated_jsonl.create ~base_dir:(Dated_jsonl.base_dir store) ();
               raise exn)
  in
  try
    deliver_pending_with
      ~append_json
      ~broadcast_json:broadcast_relay_json
      pending
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Retryable_failure (pending, Append, exn)

let should_drain_subscription pending =
  (* Do not move new OAS bus events into the local retry queue while
     failed relays are still pending.  The OAS subscriber stream is
     bounded, so leaving it undrained applies publisher backpressure
     instead of dropping the oldest local relay event. *)
  pending = []

let prepare_pending_events events =
  List.filter_map prepare_pending_event events

let rec process_pending ?store_ref acc = function
  | [] -> List.rev acc
  | pending :: rest -> (
      match deliver_pending ?store_ref pending with
      | Delivered ->
          process_pending ?store_ref acc rest
      | Retryable_failure (pending, stage, exn) ->
          let attempt = pending.attempts + 1 in
          if attempt >= relay_max_attempts then begin
            Prometheus.inc_counter Prometheus.metric_oas_sse_relay_drops
              ~labels:[ ("stage", relay_stage_to_string stage) ] ();
            emit_relay_drop_log ~pending
              ~stage_label:(relay_stage_to_string stage)
              ~attempts:attempt;
            broadcast_drop_marker ~pending
              ~stage_label:(relay_stage_to_string stage)
              ~attempts:attempt;
            process_pending ?store_ref acc rest
          end else begin
            Prometheus.inc_counter Prometheus.metric_oas_sse_relay_retries
              ~labels:[ ("stage", relay_stage_to_string stage) ] ();
            emit_relay_retry_log ~pending ~stage ~attempt exn;
            process_pending ?store_ref
              ({ pending with attempts = attempt; } :: acc)
              rest
          end)

type bridge_pending_relay = pending_relay
type bridge_relay_stage = relay_stage
type bridge_relay_result = relay_result

let deliver_pending_with_impl = deliver_pending_with

module For_testing = struct
  type pending_relay = {
    json : Yojson.Safe.t;
    attempts : int;
    appended : bool;
  }

  type relay_stage =
    | Append
    | Broadcast

  type relay_result =
    | Delivered
    | Retryable_failure of pending_relay * relay_stage * exn

  let make_pending json = { json; attempts = 0; appended = false; }

  let relay_max_queue_depth = relay_max_queue_depth

  let to_pending (pending : pending_relay) : bridge_pending_relay =
    { json = pending.json;
      attempts = pending.attempts;
      appended = pending.appended; }

  let of_pending (pending : bridge_pending_relay) : pending_relay =
    { json = pending.json;
      attempts = pending.attempts;
      appended = pending.appended; }

  (* Issue #8676: convert directly between the outer [relay_stage] and the
     [For_testing.relay_stage] mirror. The previous string-roundtrip carried
     a permissive [_ -> Broadcast] catch-all that would silently misclassify
     any future outer constructor as [Broadcast] in test stage assertions
     (#8605 anti-pattern). Direct match makes adding a constructor a
     compile error here, forcing the test mirror to stay in sync. *)
  let of_stage : bridge_relay_stage -> relay_stage = function
    | Append -> Append
    | Broadcast -> Broadcast

  let of_result (result : bridge_relay_result) =
    match result with
    | Delivered -> Delivered
    | Retryable_failure (pending, stage, exn) ->
        Retryable_failure (of_pending pending, of_stage stage, exn)

  let deliver_pending_with ~append_json ~broadcast_json pending =
    deliver_pending_with_impl
      ~append_json
      ~broadcast_json
      (to_pending pending)
    |> of_result

  let should_drain_subscription pending =
    should_drain_subscription (List.map to_pending pending)
end

let start_impl ~interval_s ~sw ~clock ~(config : Coord.config) ~bus =
  let store =
    ref
      (Dated_jsonl.create
         ~base_dir:(Filename.concat (Coord.masc_root_dir config) "oas-events")
         ())
  in
  let sub =
    Agent_sdk_metrics_bridge.subscribe
      ~purpose:"sse_bridge"
      ~filter:Agent_sdk.Event_bus.accept_all
      bus
  in
  Eio.Switch.on_release sw (fun () ->
    Agent_sdk_metrics_bridge.unsubscribe bus sub);
  let pending = ref [] in
  update_relay_queue_depth !pending;
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      (try
         pending := process_pending ~store_ref:store [] !pending;
         if should_drain_subscription !pending then begin
           let events = Agent_sdk_metrics_bridge.drain sub in
           pending := prepare_pending_events events;
           pending := process_pending ~store_ref:store [] !pending
         end;
         update_relay_queue_depth !pending
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Misc.warn
           "oas_event_bridge: relay iteration failed: %s"
           (Printexc.to_string exn));
      Eio.Time.sleep clock interval_s;
      loop ()
    in
    loop ())

(** Background fiber: drain events and relay to SSE. *)
let start ~sw ~clock ~(config : Coord.config) ~bus =
  start_impl ~interval_s:(drain_interval_s ()) ~sw ~clock ~config ~bus

let start_with_interval ~drain_interval_s:interval_s ~sw ~clock
    ~(config : Coord.config) ~bus =
  start_impl ~interval_s ~sw ~clock ~config ~bus
