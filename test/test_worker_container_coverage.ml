open Alcotest
open Masc_mcp

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some old -> Unix.putenv name old
      | None -> Unix.putenv name "")
    f
;;

let worker_usage ?cost_usd ~input_tokens ~output_tokens () : Agent_sdk.Types.api_usage =
  { input_tokens
  ; output_tokens
  ; cache_creation_input_tokens = 0
  ; cache_read_input_tokens = 0
  ; cost_usd
  }
;;

let test_parse_text_tool_calls_single () =
  let content =
    {|mcp__masc__masc_keeper_msg(name="keeper-alpha", message="[local64-smoke-01] manager decide online for hybrid smoke")|}
  in
  match Worker_runtime.parse_text_tool_calls content with
  | [ Agent_sdk.Types.ToolUse { name; input; _ } ] ->
    check string "tool name" "masc_keeper_msg" name;
    let json = input in
    check
      string
      "keeper name"
      "keeper-alpha"
      Yojson.Safe.Util.(json |> member "name" |> to_string);
    check
      string
      "message"
      "[local64-smoke-01] manager decide online for hybrid smoke"
      Yojson.Safe.Util.(json |> member "message" |> to_string)
  | _ -> fail "expected exactly one parsed tool call"
;;

let test_parse_text_tool_calls_multiple () =
  let content =
    {|
<think>
done
</think>
mcp__masc__masc_heartbeat()
mcp__masc__masc_keeper_msg(name="keeper-alpha", message="[local64-smoke-02] metacog verify online for hybrid smoke")
done:local64-smoke-02
|}
  in
  match Worker_runtime.parse_text_tool_calls content with
  | [ Agent_sdk.Types.ToolUse { name = name1; input = input1; _ }
    ; Agent_sdk.Types.ToolUse { name = name2; _ }
    ] ->
    check string "first tool" "masc_heartbeat" name1;
    check string "heartbeat args" "{}" (Yojson.Safe.to_string input1);
    check string "second tool" "masc_keeper_msg" name2
  | _ -> fail "expected two parsed text tool calls"
;;

let test_merge_usage_preserves_present_cost () =
  let a = worker_usage ~input_tokens:8 ~output_tokens:2 ~cost_usd:0.12 () in
  let b = worker_usage ~input_tokens:1 ~output_tokens:4 () in
  let merged = Worker_container_types.merge_usage a b in
  check int "input tokens merged" 9 merged.input_tokens;
  check int "output tokens merged" 6 merged.output_tokens;
  check (option (float 0.000001)) "cost preserved from left" (Some 0.12) merged.cost_usd
;;

let test_merge_usage_sums_costs_when_both_present () =
  let a = worker_usage ~input_tokens:8 ~output_tokens:2 ~cost_usd:0.12 () in
  let b = worker_usage ~input_tokens:1 ~output_tokens:4 ~cost_usd:0.03 () in
  let merged = Worker_container_types.merge_usage a b in
  check (option (float 0.000001)) "costs summed" (Some 0.15) merged.cost_usd
;;

let test_mcp_endpoint_url_does_not_leak_token () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" (fun () ->
    let url = Worker_container_types.mcp_endpoint_url ~auth_token:(Some "secret-token") in
    check string "mcp url stays clean" "http://127.0.0.1:8935/mcp" url)
;;

let () =
  run
    "Worker_runtime"
    [ ( "parser"
      , [ test_case
            "parse text tool calls single"
            `Quick
            test_parse_text_tool_calls_single
        ; test_case
            "parse text tool calls multiple"
            `Quick
            test_parse_text_tool_calls_multiple
        ; test_case
            "merge usage preserves present cost"
            `Quick
            test_merge_usage_preserves_present_cost
        ; test_case
            "merge usage sums costs"
            `Quick
            test_merge_usage_sums_costs_when_both_present
        ; test_case
            "mcp endpoint url does not leak token"
            `Quick
            test_mcp_endpoint_url_does_not_leak_token
        ] )
    ]
;;
