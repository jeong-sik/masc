open Alcotest
open Masc

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some old -> Unix.putenv name old
      | None -> Unix.putenv name "")
    f

let worker_usage ?cost_usd ~input_tokens ~output_tokens () :
    Agent_sdk.Types.api_usage =
  {
    input_tokens;
    output_tokens;
    cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0;
    cost_usd;
  }

let test_parse_text_tool_calls_single () =
  let content =
    {|mcp__masc__masc_keeper_delegate(target={"kind":"keeper","name":"keeper-alpha"}, capability="invoke_turn", prompt="[local64-smoke-01] manager decide online for hybrid smoke")|}
  in
  match Worker_runtime.parse_text_tool_calls content with
  | [ Agent_sdk.Types.ToolUse { name; input; _ } ] ->
      check string "tool name" "masc_keeper_delegate" name;
      let json = input in
      check string "keeper name" "keeper-alpha"
        Yojson.Safe.Util.(json |> member "target" |> member "name" |> to_string);
      check string "prompt"
        "[local64-smoke-01] manager decide online for hybrid smoke"
        Yojson.Safe.Util.(json |> member "prompt" |> to_string)
  | _ -> fail "expected exactly one parsed tool call"

let test_parse_text_tool_calls_multiple () =
  let content =
    {|
<think>
done
</think>
mcp__masc__masc_heartbeat()
mcp__masc__masc_keeper_delegate(target={"kind":"keeper","name":"keeper-alpha"}, capability="invoke_turn", prompt="[local64-smoke-02] metacog verify online for hybrid smoke")
done:local64-smoke-02
|}
  in
  match Worker_runtime.parse_text_tool_calls content with
  | [ Agent_sdk.Types.ToolUse { name = name1; input = input1; _ };
      Agent_sdk.Types.ToolUse { name = name2; _ } ] ->
      check string "first tool" "masc_heartbeat" name1;
      check string "heartbeat args" "{}"
        (Yojson.Safe.to_string input1);
      check string "second tool" "masc_keeper_delegate" name2
  | _ -> fail "expected two parsed text tool calls"

let test_merge_usage_preserves_present_cost () =
  let a = worker_usage ~input_tokens:8 ~output_tokens:2 ~cost_usd:0.12 () in
  let b = worker_usage ~input_tokens:1 ~output_tokens:4 () in
  let merged = Worker_container_types.merge_usage a b in
  check int "input tokens merged" 9 merged.input_tokens;
  check int "output tokens merged" 6 merged.output_tokens;
  check (option (float 0.000001)) "cost preserved from left" (Some 0.12)
    merged.cost_usd

let test_merge_usage_sums_costs_when_both_present () =
  let a = worker_usage ~input_tokens:8 ~output_tokens:2 ~cost_usd:0.12 () in
  let b = worker_usage ~input_tokens:1 ~output_tokens:4 ~cost_usd:0.03 () in
  let merged = Worker_container_types.merge_usage a b in
  check (option (float 0.000001)) "costs summed" (Some 0.15)
    merged.cost_usd

let test_mcp_endpoint_url_does_not_leak_token () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" (fun () ->
    let url =
      Worker_container_types.mcp_endpoint_url ~auth_token:(Some "secret-token")
    in
    check string "mcp url stays clean" "http://127.0.0.1:8935/mcp" url)

let client_operation_params =
  `Assoc [ ("name", `String "masc_status"); ("arguments", `Assoc []) ]

let client_operation_labels ?error_type ?rpc_response_status_code () =
  Worker_container_types.For_testing.mcp_client_operation_duration_labels
    ~url:"http://127.0.0.1:8935/mcp"
    ~method_name:Otel_genai.Mcp_value.tools_call_method
    ~params:client_operation_params
    ?error_type
    ?rpc_response_status_code
    ()

let test_mcp_client_operation_duration_labels_follow_semconv () =
  let labels =
    client_operation_labels ~error_type:"-32602" ~rpc_response_status_code:"-32602" ()
  in
  check (list (pair string string)) "client operation labels"
    [
      (Otel_genai.Mcp_attr_key.mcp_method_name, Otel_genai.Mcp_value.tools_call_method);
      ( Otel_genai.Mcp_attr_key.mcp_protocol_version,
        Mcp_transport_protocol.default_protocol_version );
      (Otel_genai.Mcp_attr_key.network_protocol_name, "http");
      (Otel_genai.Mcp_attr_key.network_protocol_version, "1.1");
      (Otel_genai.Mcp_attr_key.network_transport, "tcp");
      (Otel_genai.Attr_key.gen_ai_operation_name, "execute_tool");
      (Otel_genai.Attr_key.gen_ai_tool_name, "masc_status");
      (Otel_genai.Mcp_attr_key.server_address, "127.0.0.1");
      (Otel_genai.Mcp_attr_key.server_port, "8935");
      (Otel_genai.Mcp_attr_key.error_type, "-32602");
      (Otel_genai.Mcp_attr_key.rpc_response_status_code, "-32602");
    ]
    labels;
  check bool "client operation metric omits session id" false
    (List.exists
       (fun (key, _) -> String.equal key Otel_genai.Mcp_attr_key.mcp_session_id)
       labels)

let test_records_mcp_client_operation_duration_metric () =
  let metric_name = Otel_genai.Mcp_metric_name.client_operation_duration in
  let labels = client_operation_labels () in
  let before_count =
    Otel_metric_store.metric_value_or_zero (metric_name ^ "_count") ~labels ()
  in
  Worker_container_types.For_testing.record_mcp_client_operation_duration
    ~url:"http://127.0.0.1:8935/mcp"
    ~method_name:Otel_genai.Mcp_value.tools_call_method
    ~params:client_operation_params
    ~started_at:(Unix.gettimeofday () -. 0.25)
    ();
  check (float 0.0001) "client operation count increments"
    (before_count +. 1.0)
    (Otel_metric_store.metric_value_or_zero (metric_name ^ "_count") ~labels ())

let test_tools_call_is_error_records_failed_client_operation_duration () =
  let metric_name = Otel_genai.Mcp_metric_name.client_operation_duration in
  let labels = client_operation_labels ~error_type:Otel_genai.Mcp_value.tool_error_type () in
  let before_count =
    Otel_metric_store.metric_value_or_zero (metric_name ^ "_count") ~labels ()
  in
  Worker_container_types.For_testing.record_mcp_client_operation_duration
    ~url:"http://127.0.0.1:8935/mcp"
    ~method_name:Otel_genai.Mcp_value.tools_call_method
    ~params:client_operation_params
    ~started_at:(Unix.gettimeofday () -. 0.25)
    ~tool_result_is_error:true
    ();
  check (float 0.0001) "client tool-error count increments"
    (before_count +. 1.0)
    (Otel_metric_store.metric_value_or_zero (metric_name ^ "_count") ~labels ())

let client_session_labels ?error_type () =
  Worker_container_types.For_testing.mcp_client_session_duration_labels
    ~url:"http://127.0.0.1:8935/mcp"
    ?error_type
    ()

let test_mcp_client_session_duration_labels_follow_semconv () =
  let labels = client_session_labels ~error_type:"agent_error" () in
  check (list (pair string string)) "client session labels"
    [
      ( Otel_genai.Mcp_attr_key.mcp_protocol_version,
        Mcp_transport_protocol.default_protocol_version );
      (Otel_genai.Mcp_attr_key.network_protocol_name, "http");
      (Otel_genai.Mcp_attr_key.network_protocol_version, "1.1");
      (Otel_genai.Mcp_attr_key.network_transport, "tcp");
      (Otel_genai.Mcp_attr_key.server_address, "127.0.0.1");
      (Otel_genai.Mcp_attr_key.server_port, "8935");
      (Otel_genai.Mcp_attr_key.error_type, "agent_error");
    ]
    labels;
  check bool "client session metric omits session id" false
    (List.exists
       (fun (key, _) -> String.equal key Otel_genai.Mcp_attr_key.mcp_session_id)
       labels)

let test_records_mcp_client_session_duration_metric () =
  let metric_name = Otel_genai.Mcp_metric_name.client_session_duration in
  let labels = client_session_labels () in
  let before_count =
    Otel_metric_store.metric_value_or_zero (metric_name ^ "_count") ~labels ()
  in
  Worker_container_types.For_testing.record_mcp_client_session_duration
    ~url:"http://127.0.0.1:8935/mcp"
    ~started_at:(Unix.gettimeofday () -. 0.5)
    ();
  check (float 0.0001) "client session count increments"
    (before_count +. 1.0)
    (Otel_metric_store.metric_value_or_zero (metric_name ^ "_count") ~labels ())

let worker_meta ?mcp_client_session_started_at () =
  {
    Worker_container_types.version =
      Worker_container_types.worker_container_version;
    worker_name = "coverage-worker";
    mcp_session_id = "coverage-session";
    workspace_path = "/tmp/coverage-workspace";
    role = None;
    selection_note = None;
    runtime_backend = Worker_execution_backend.Local_playground;
    thinking_enabled = None;
    timeout_seconds = None;
    effective_model = "test-model";
    checkpoint_path = "/tmp/coverage-checkpoint.json";
    turn_log_path = "/tmp/coverage-turns.jsonl";
    mcp_client_session_started_at;
    last_run_at = None;
  }

let test_worker_mcp_client_session_preserves_persisted_start () =
  let started_at = 42.0 in
  let begun =
    Worker_oas.For_testing.begin_worker_mcp_client_session
      (worker_meta ~mcp_client_session_started_at:started_at ())
  in
  check (option (float 0.0001)) "persisted start is preserved"
    (Some started_at)
    begun.mcp_client_session_started_at;
  let fresh =
    Worker_oas.For_testing.begin_worker_mcp_client_session (worker_meta ())
  in
  check bool "fresh session receives a start timestamp" true
    (Option.is_some fresh.mcp_client_session_started_at)

let test_worker_mcp_client_session_finish_clears_started_at () =
  let completed =
    Worker_oas.For_testing.finish_worker_mcp_client_session
      (worker_meta ~mcp_client_session_started_at:42.0 ())
  in
  check (option (float 0.0001)) "active session timestamp cleared" None
    completed.mcp_client_session_started_at;
  check bool "last_run_at recorded" true (Option.is_some completed.last_run_at)

let () =
  run "Worker_runtime"
    [
      ( "parser",
        [
          test_case "parse text tool calls single" `Quick
            test_parse_text_tool_calls_single;
          test_case "parse text tool calls multiple" `Quick
            test_parse_text_tool_calls_multiple;
          test_case "merge usage preserves present cost" `Quick
            test_merge_usage_preserves_present_cost;
          test_case "merge usage sums costs" `Quick
            test_merge_usage_sums_costs_when_both_present;
          test_case "mcp endpoint url does not leak token" `Quick
            test_mcp_endpoint_url_does_not_leak_token;
          test_case "MCP client operation duration labels follow semconv" `Quick
            test_mcp_client_operation_duration_labels_follow_semconv;
          test_case "records MCP client operation duration metric" `Quick
            test_records_mcp_client_operation_duration_metric;
          test_case "tools/call isError records failed client operation duration"
            `Quick
            test_tools_call_is_error_records_failed_client_operation_duration;
          test_case "MCP client session duration labels follow semconv" `Quick
            test_mcp_client_session_duration_labels_follow_semconv;
          test_case "records MCP client session duration metric" `Quick
            test_records_mcp_client_session_duration_metric;
          test_case "worker MCP client session preserves persisted start"
            `Quick
            test_worker_mcp_client_session_preserves_persisted_start;
          test_case "worker MCP client session finish clears active start"
            `Quick
            test_worker_mcp_client_session_finish_clears_started_at;
        ] );
    ]
