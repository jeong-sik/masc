open Masc

let () = Mirage_crypto_rng_unix.use_default ()

let test_rewrites_unknown_provider () =
  let detail =
    Fusion_agent_core.provider_error_detail ~runtime_id:"ollama_cloud.kimi-k2-6"
      "Provider 'unknown' timeout phase=http_operation: HTTP operation exceeded wall-clock timeout"
  in
  Alcotest.(check string)
    "unknown provider replaced with runtime id"
    "Provider 'ollama_cloud.kimi-k2-6' timeout phase=http_operation: HTTP operation exceeded wall-clock timeout"
    detail
;;

let test_prefixes_unattributed_provider_error () =
  let detail =
    Fusion_agent_core.provider_error_detail ~runtime_id:"ollama_cloud.minimax-m3"
      "HTTP 503 from provider"
  in
  Alcotest.(check string)
    "runtime context prefixed"
    "ollama_cloud.minimax-m3: HTTP 503 from provider"
    detail
;;

let test_keeps_already_attributed_error () =
  let detail =
    Fusion_agent_core.provider_error_detail ~runtime_id:"ollama_cloud.minimax-m3"
      "Provider 'ollama_cloud.minimax-m3' timeout phase=http_operation"
  in
  Alcotest.(check string)
    "already attributed"
    "Provider 'ollama_cloud.minimax-m3' timeout phase=http_operation"
    detail
;;

let test_panel_failure_detail_rewrites_unknown_provider () =
  let detail =
    Fusion_agent_core.panel_failure_detail ~runtime_id:"ollama_cloud.kimi-k2-6"
      (Fusion_types.Provider_error
         "Provider 'unknown' timeout phase=http_operation: HTTP operation exceeded wall-clock timeout")
  in
  Alcotest.(check string)
    "panel failure detail"
    "Provider 'ollama_cloud.kimi-k2-6' timeout phase=http_operation: HTTP operation exceeded wall-clock timeout"
    detail;
  Alcotest.(check string)
    "panel failure code"
    "provider_error"
    (Fusion_agent_core.panel_failure_code
       (Fusion_types.Provider_error "Provider 'unknown' timeout"))
;;

(* RFC-0278: panel_failure_text는 이미 attribution된 detail을 재-attribution 없이
   그대로 렌더한다 (sink가 panelist 정체성을 provider 슬롯에 다시 입히지 않도록). *)
let test_panel_failure_text_no_reattribution () =
  Alcotest.(check string)
    "provider_error returns detail as-is"
    "Provider 'claude': boom"
    (Fusion_agent_core.panel_failure_text
       (Fusion_types.Provider_error "Provider 'claude': boom"));
  Alcotest.(check string)
    "timeout"
    "timeout"
    (Fusion_agent_core.panel_failure_text Fusion_types.Timeout);
  Alcotest.(check string)
    "bridge error"
    "Bridge error: env_not_initialized"
    (Fusion_agent_core.panel_failure_text (Fusion_types.Bridge_error "env_not_initialized"));
  Alcotest.(check string)
    "empty response"
    "empty response (stop_reason=max_tokens)"
    (Fusion_agent_core.panel_failure_text
       (Fusion_types.Empty_response "empty response (stop_reason=max_tokens)"))
;;

let test_empty_response_detail_summarizes_shape () =
  let response : Agent_core.Types.api_response =
    { id = "r"
    ; model = "m"
    ; stop_reason = Agent_core.Types.MaxTokens
    ; content =
        [ Agent_core.Types.Thinking { signature = None; content = "secret chain" } ]
    ; usage =
        Some
          { input_tokens = 21
          ; output_tokens = 32
          ; cache_creation_input_tokens = 0
          ; cache_read_input_tokens = 0
          ; cost_usd = None
          }
    ; telemetry = None
    }
  in
  let detail = Fusion_agent_core.For_testing.empty_response_detail response in
  Alcotest.(check bool) "stop reason included" true
    (String_util.string_contains_substring ~needle:"stop_reason=max_tokens" detail);
  Alcotest.(check bool) "thinking block counted" true
    (String_util.string_contains_substring ~needle:"thinking_blocks=1" detail);
  Alcotest.(check bool) "thinking kind summarized" true
    (String_util.string_contains_substring ~needle:"thinking_kind=thinking" detail);
  Alcotest.(check bool) "thinking chars summarized" true
    (String_util.string_contains_substring ~needle:"thinking_chars=12" detail);
  Alcotest.(check bool) "output tokens included" true
    (String_util.string_contains_substring ~needle:"output_tokens=32" detail);
  Alcotest.(check bool) "reasoning body not leaked" false
    (String_util.string_contains_substring ~needle:"secret chain" detail)
;;

let test_empty_response_detail_uses_canonical_unknown_stop_reason () =
  let response : Agent_core.Types.api_response =
    { id = "r"
    ; model = "m"
    ; stop_reason = Agent_core.Types.Unknown "line\nquote\""
    ; content = []
    ; usage = None
    ; telemetry = None
    }
  in
  let detail = Fusion_agent_core.For_testing.empty_response_detail response in
  Alcotest.(check bool) "unknown stop reason uses canonical label" true
    (String_util.string_contains_substring ~needle:"stop_reason=unknown" detail);
  Alcotest.(check bool) "raw newline not embedded" false
    (String_util.string_contains_substring ~needle:"line\nquote" detail)
;;

let test_empty_response_detail_counts_via_canonical_projection () =
  (* 비-thinking 카운트가 AGENT_CORE canonical projection
     [Agent_core.Response_shape.summarize_blocks]에서 산출됨을 증명한다(로컬 fold 제거 후).
     text_chars는 AGENT_CORE 규약대로 trim 후 길이다: "  hi  "(2) + "yo"(2) = 4. *)
  let response : Agent_core.Types.api_response =
    { id = "r"
    ; model = "m"
    ; stop_reason = Agent_core.Types.MaxTokens
    ; content = [ Agent_core.Types.Text "  hi  "; Agent_core.Types.Text "yo" ]
    ; usage = None
    ; telemetry = None
    }
  in
  let detail = Fusion_agent_core.For_testing.empty_response_detail response in
  Alcotest.(check bool) "content blocks total counted" true
    (String_util.string_contains_substring ~needle:"content_blocks=2" detail);
  Alcotest.(check bool) "text blocks from canonical projection" true
    (String_util.string_contains_substring ~needle:"text_blocks=2" detail);
  Alcotest.(check bool) "text chars use canonical trimmed length" true
    (String_util.string_contains_substring ~needle:"text_chars=4" detail)
;;

let test_panel_failure_yojson_rejects_bare_string_shapes () =
  (* Both used to decode. `String "Empty_response" also invented the detail
     "empty response", which no producer ever sent. *)
  let rejects label json =
    match Fusion_types.panel_failure_of_yojson json with
    | Error _ -> ()
    | Ok failure ->
      Alcotest.failf "%s decoded as %s" label
        (Fusion_types.show_panel_failure failure)
  in
  rejects "bare Empty_response" (`String "Empty_response");
  rejects "bare Timeout" (`String "Timeout");
  (* An [`Int] in the float slot was accepted for hand-written records and
     earlier wire. *)
  rejects "Invalid_timeout_s carrying an Int"
    (`List [ `String "Invalid_timeout_s"; `Int 3 ])
;;

let test_panel_failure_yojson_round_trips_current_shapes () =
  let check_round_trip label failure =
    let json = Fusion_types.panel_failure_to_yojson failure in
    match Fusion_types.panel_failure_of_yojson json with
    | Ok actual ->
      Alcotest.(check string)
        label
        (Fusion_types.show_panel_failure failure)
        (Fusion_types.show_panel_failure actual)
    | Error err -> Alcotest.failf "%s failed to decode: %s" label err
  in
  check_round_trip "timeout" Fusion_types.Timeout;
  check_round_trip "provider error"
    (Fusion_types.Provider_error "Provider 'runtime': quota");
  check_round_trip "empty response"
    (Fusion_types.Empty_response "empty response (stop_reason=max_tokens)");
  check_round_trip "invalid max output tokens"
    (Fusion_types.Invalid_max_output_tokens 0);
  Alcotest.(check bool)
    "detail empty response serializes as tagged payload, not legacy string"
    true
    (Yojson.Safe.equal
       (`List
         [ `String "Empty_response"
         ; `String "empty response (stop_reason=max_tokens)"
         ])
       (Fusion_types.panel_failure_to_yojson
          (Fusion_types.Empty_response "empty response (stop_reason=max_tokens)")))
;;

let test_tool_observer_captures_actual_call_and_failure () =
  Eio_main.run @@ fun _env ->
  let actor = Fusion_types.Panel_actor "skeptic (claude)" in
  let observer = Fusion_agent_core.create_tool_observer ~actor in
  let bus = Fusion_agent_core.tool_observer_event_bus observer in
  let invocation =
    Agent_core.Tool_contract.Invocation.create
      ~tool_use_id:"web-1"
      ~turn:2
      ~schedule:
        { planned_index = 1
        ; batch_index = 0
        ; batch_size = 1
        ; execution_mode = Agent_core.Tool_contract.Serial
        }
      ~completion:Agent_core.Tool_contract.Continue_after_success
  in
  let event payload =
    { Agent_core.Event_bus.meta =
        Agent_core.Event_bus.mk_envelope
          ~event_id:(Agent_core.Event_bus.payload_kind payload)
          ~correlation_id:"fusion-test"
          ~run_id:"fusion-test-run"
          ()
    ; payload
    }
  in
  let input_text = String.make 1200 'x' in
  Agent_core.Event_bus.publish bus
    (event
       (Agent_core.Event_bus.ToolCalled
          { invocation
          ; agent_name = "skeptic (claude)"
          ; tool_name = "masc_web_search"
          ; input = `Assoc [ "query", `String input_text ]
          }));
  Agent_core.Event_bus.publish bus
    (event
       (Agent_core.Event_bus.ToolCompleted
          { invocation
          ; agent_name = "skeptic (claude)"
          ; tool_name = "masc_web_search"
          ; output =
              Error
                { Agent_core.Types.message = "provider refused"
                ; recoverable = false
                ; error_class = Some Agent_core.Types.Deterministic
                }
          }));
  match Fusion_agent_core.finish_tool_observer observer with
  | { Fusion_types.observed_actors = [ Fusion_types.Panel_actor observed_actor ]
    ; events =
        [ Fusion_types.Tool_called called
        ; Fusion_types.Tool_completed completed
        ]
    ; dropped_events = 0
    ; gaps = []
    } ->
    Alcotest.(check string) "observed actor retained" "skeptic (claude)"
      observed_actor;
    Alcotest.(check string) "exact tool name" "masc_web_search" called.tool_name;
    Alcotest.(check bool) "large input is explicitly truncated" true
      called.input.truncated;
    Alcotest.(check bool) "source byte count exceeds preview" true
      (called.input.bytes > String.length called.input.text);
    (match completed.completion with
     | Fusion_types.Tool_trace_failed failure ->
       Alcotest.(check string) "failure output" "provider refused"
         failure.output.text;
       Alcotest.(check bool) "recoverability retained" false failure.recoverable;
       Alcotest.(check bool) "typed error class retained" true
         (failure.error_class = Some Fusion_types.Trace_deterministic)
     | Fusion_types.Tool_trace_succeeded _ ->
       Alcotest.fail "failed Tool completion was flattened to success")
  | trace ->
    Alcotest.failf "expected called+completed ledger, got %d event(s)"
      (List.length trace.events)
;;

let () =
  Alcotest.run
    "Fusion_agent_core_error_detail"
    [ ( "provider attribution"
      , [ Alcotest.test_case
            "rewrites unknown provider"
            `Quick
            test_rewrites_unknown_provider
        ; Alcotest.test_case
            "prefixes unattributed provider error"
            `Quick
            test_prefixes_unattributed_provider_error
        ; Alcotest.test_case
            "keeps already attributed error"
            `Quick
            test_keeps_already_attributed_error
        ; Alcotest.test_case
            "panel failure detail rewrites unknown provider"
            `Quick
            test_panel_failure_detail_rewrites_unknown_provider
        ; Alcotest.test_case
            "panel failure text does not re-attribute"
            `Quick
            test_panel_failure_text_no_reattribution
        ; Alcotest.test_case
            "empty response detail summarizes shape"
            `Quick
            test_empty_response_detail_summarizes_shape
        ; Alcotest.test_case
            "empty response detail counts via canonical projection"
            `Quick
            test_empty_response_detail_counts_via_canonical_projection
        ; Alcotest.test_case
            "empty response detail uses canonical unknown stop reason"
            `Quick
            test_empty_response_detail_uses_canonical_unknown_stop_reason
        ; Alcotest.test_case
            "panel failure yojson rejects bare string shapes"
            `Quick
            test_panel_failure_yojson_rejects_bare_string_shapes
        ; Alcotest.test_case
            "panel failure yojson round-trips current shapes"
            `Quick
            test_panel_failure_yojson_round_trips_current_shapes
        ; Alcotest.test_case
            "tool observer captures actual call and failure"
            `Quick
            test_tool_observer_captures_actual_call_and_failure
        ] )
    ]
;;
