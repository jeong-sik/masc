open Alcotest
open Masc

module Provider = Agent_core.Llm_provider
module J = Yojson.Safe.Util

let expect_ok = function
  | Ok value -> value
  | Error detail -> fail detail

let media_result result =
  result
  |> Result.map_error Agent_core.History.show_media_error
  |> expect_ok

let runtime_config () =
  let source = In_channel.with_open_bin (Sys.getenv "MASC_TEST_RUNTIME_SEED")
      In_channel.input_all in
  let config = Runtime_toml.parse_string source
      |> Result.map_error (fun errors ->
        errors |> List.map (fun (error : Runtime_toml.parse_error) ->
          error.path ^ ": " ^ error.message) |> String.concat "\n")
      |> expect_ok in
  (* Use the shipped provider/model/binding declarations without resolving an
     operator's credential or contacting its endpoint. *)
  { config with providers = List.map (fun (provider : Runtime_schema.provider) ->
      if provider.id = "kimi_coding"
      then { provider with credentials = Some (Runtime_schema.Inline "fixture-key") }
      else provider) config.providers }

let with_catalog f =
  let previous = Provider.Catalog_snapshot.current () in
  let _,providers = Provider.Catalog_snapshot.sources previous in
  let catalog = Provider.Model_catalog.load_file (Sys.getenv "MASC_TEST_MODEL_CATALOG")
      |> expect_ok in
  Fun.protect ~finally:(fun () -> Provider.Catalog_snapshot.publish previous) (fun () ->
    Provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Some catalog) ~providers);
    f ())

let provider_config runtime model_id =
  let binding = List.find (fun (binding : Runtime_schema.binding) ->
    binding.provider_id = "kimi_coding" && binding.model_id = model_id)
      runtime.Runtime_schema.bindings in
  Runtime_adapter.binding_to_provider_config runtime binding |> expect_ok

let checkpoint model messages =
  Agent_core.Checkpoint.
    { provider_binding = None; version = checkpoint_version
    ; session_id = "kimi-replay-fixture"; agent_name = "test-agent"; model
    ; system_prompt = None; messages; usage = Agent_core.Types.empty_usage
    ; turn_count = 1; created_at = 1_000.0; tools = []; tool_choice = None
    ; disable_parallel_tool_use = false; temperature = None; top_p = None
    ; top_k = None; min_p = None; reasoning_effort = None
    ; enable_thinking = None; preserve_thinking = None
    ; response_format = Agent_core.Types.Off; cache_system_prompt = false
    ; context = Agent_core.Context.create_sync (); pending_input = None
    ; mcp_sessions = []; working_context = Some (`Assoc [])
    }

let tool_call =
  `Assoc [ "id", `String "weather-call"; "type", `String "function"
         ; "function", `Assoc ["name", `String "weather";
                                "arguments", `String {|{"city":"Seoul"}|}] ]

let assistant ~stream (config : Provider.Provider_config.t) ~tool ~reasoning ~content =
  let response =
    if stream then (
      let dialect = Provider.Reasoning_dialect.for_provider_config config in
      let state = Provider.Streaming.create_openai_stream_state () in
      let acc = Provider.Complete_stream_acc.create_stream_acc () in
      let feed wire =
        let parsed = Provider.Streaming.parse_openai_sse_chunk
            ~streaming_reasoning:dialect.streaming wire in
        let events, _ = Provider.Streaming.openai_sse_parse_result_to_events state parsed in
        List.iter (Provider.Complete_stream_acc.accumulate_event acc) events in
      let chunk delta finish = Yojson.Safe.to_string
          (`Assoc ["id", `String "kimi-response";
                   "model", `String config.model_id;
                   "choices", `List [`Assoc ["index", `Int 0; "delta", `Assoc delta;
                                              "finish_reason", finish]]]) in
      (* Split reasoning to exercise the actual configured SSE accumulator. *)
      feed (chunk ["reasoning_content", `String reasoning] `Null);
      feed (chunk ["reasoning_content", `String "\n검증"] `Null);
      feed (chunk ["content", `String content] `Null);
      if tool then feed (chunk ["tool_calls", `List
        [`Assoc (("index", `Int 0) :: J.to_assoc tool_call)]] `Null);
      feed (chunk [] (`String (if tool then "tool_calls" else "stop")));
      feed "[DONE]";
      Provider.Complete_stream_acc.finalize_stream_acc acc
      |> Result.map_error (fun _ -> "Kimi Coding SSE fixture failed") |> expect_ok)
    else
      Provider.Backend_openai_parse.parse_openai_response_result_json
        (`Assoc ["id", `String "kimi-response";
                 "model", `String config.model_id;
                 "choices", `List [`Assoc
                   ["message", `Assoc
                      (["role", `String "assistant"; "content", `String content;
                        "reasoning_content", `String (reasoning ^ "\n검증")]
                       @ if tool then ["tool_calls", `List [tool_call]] else []);
                    "finish_reason", `String (if tool then "tool_calls" else "stop")]]])
      |> Result.map_error Provider.Backend_openai_parse.parse_error_to_string |> expect_ok in
  Provider.Complete_common.patch_telemetry response ~config None
  |> Provider.Types.assistant_message_of_response
  |> Result.map_error Provider.Types.show_assistant_message_error
  |> expect_ok

let test_configured_replay model_id ~stream () =
  with_catalog (fun () ->
    let config = provider_config (runtime_config ()) model_id in
    check bool "Coding Plan uses Chat HTTP" true
      (config.kind = Provider.Provider_config.OpenAI_compat);
    check string "Coding provider scope" "kimi_coding" (Option.get config.provider_id);
    check string "Chat request path" "/chat/completions" config.request_path;
    let first = assistant ~stream config ~tool:true
        ~reasoning:"check forecast" ~content:"" in
    let last = assistant ~stream config ~tool:false
        ~reasoning:"explain forecast" ~content:"Sunny" in
    let media_store = Agent_core.History.Memory_store.create () in
    let history = Provider.Types.
        [ user_msg "Weather?"; first
        ; { origin = Conversation; role = Tool; name = None; tool_call_id = None; metadata = []
          ; content = [ToolResult { tool_use_id = "weather-call"; content = "sunny"
                                   ; outcome = Tool_succeeded; json = None; content_blocks = None }] }
        ]
      |> List.map (fun message ->
        Agent_core.History.of_wire_message media_store message |> media_result) in
    let stored_last = Agent_core.History.of_wire_message media_store last |> media_result in
    let original = checkpoint config.model_id (history @ [stored_last]) in
    let finalized, _ = Keeper_replay_checkpoint.checkpoint_for_replay_persistence
        ~stop_reason:(Runtime_agent.Completed {provider_turn_ordinal=17})
        ~history_messages:history ~session_id:original.session_id
        ~response_text:"Sunny" ~exclude_thought_from_replay:false original |> expect_ok in
    let session_dir = Filename.temp_dir "kimi-coding-replay-" "" in
    Fun.protect ~finally:(fun () -> Fs_compat.remove_tree session_dir) (fun () ->
      (match Keeper_checkpoint_store.save_agent_core_classified
          ~boundary:Agent_core.Checkpoint_objects.Turn_closes
          ~history_retained:(Runtime_params.get Runtime_settings.keeper_checkpoint_history_retained)
          ~session_dir finalized |> expect_ok with
       | Saved _ -> ()
       | Stale_noop _ -> fail "fresh Kimi Coding checkpoint was not saved");
      let restored = Keeper_checkpoint_store.load_agent_core
          ~session_dir ~session_id:original.session_id
        |> Result.map_error Keeper_checkpoint_store.checkpoint_load_error_to_string |> expect_ok in
      let messages = Agent_core.History.to_wire_messages media_store restored.messages
          |> media_result in
      let restored_first = List.nth messages 1 in
      check bool "checkpoint retains exact producer provenance" true
        (restored_first.metadata = first.metadata);
      check bool "producer provenance was stamped" true
        (match Provider.Types.Reasoning_source.classify restored_first.metadata with
         | Present source -> source.provider_kind = OpenAI_compat
                             && source.canonical_model_id = config.model_id
         | Absent | Invalid | Duplicate -> false);
      (* A new human turn must not erase the plan's earlier tool reasoning. *)
      let body = Provider.Backend_openai.build_request ~config
          ~messages:(messages @ [Provider.Types.user_msg "And tomorrow?"]) ()
        |> Yojson.Safe.from_string in
      check string "request uses configured API model" config.model_id
        (J.member "model" body |> J.to_string);
      let wire = J.member "messages" body |> J.to_list in
      check int "request retains complete history" 5 (List.length wire);
      let tool_assistant = List.nth wire 1 and final_assistant = List.nth wire 3 in
      check string "tool reasoning survives restart and new human turn" "check forecast\n검증"
        (J.member "reasoning_content" tool_assistant |> J.to_string);
      check string "final reasoning also survives restart" "explain forecast\n검증"
        (J.member "reasoning_content" final_assistant |> J.to_string);
      check bool "tool call identity and arguments survive" true
        (J.member "tool_calls" tool_assistant = `List [tool_call]);
      check string "result matches assistant call" "weather-call"
        (List.nth wire 2 |> J.member "tool_call_id" |> J.to_string);
      check bool "reasoning uses the declared field" true
        (J.member "reasoning" tool_assistant = `Null)))

let test_configured_effort model_id () =
  with_catalog (fun () ->
    let runtime = runtime_config () in
    let request config =
      let serialized = Result.bind (Provider.Complete_common.validate_all config)
          (fun () -> Provider.Complete_common.serialize_http_request ~stream:false ~config
            ~messages:[Provider.Types.user_msg "Weather?"] ~tools:[]) in
      match serialized with
      | Ok artifact -> Yojson.Safe.from_string artifact.body
      | Error (Provider.Http_client.AcceptRejected {reason}) -> fail reason
      | Error _ -> fail "Kimi Coding request serialization failed" in
    let default = provider_config runtime model_id in
    let check_effort label expected body =
      (match expected with
       | None -> check bool (label ^ " has no effort field") false
           (List.mem_assoc "reasoning_effort" (J.to_assoc body))
       | Some _ -> ());
      check (option string) label expected
        (body |> J.member "reasoning_effort" |> J.to_string_option);
      check string "effort request retains the configured API ID" default.model_id
        (body |> J.member "model" |> J.to_string) in
    check_effort "shipped default omits effort" None (request default);
    check_effort "explicit enable uses the provider default without choosing a depth" None
      (request {default with enable_thinking = Some true});
    List.iter (fun effort ->
      (* An operator's typed runtime model setting must reach the admitted
         request, with the shipped provider and binding unchanged. *)
      let configured = {runtime with models = List.map
          (fun (model : Runtime_schema.model_spec) ->
            if model.id = model_id then {model with reasoning_effort = Some effort}
            else model) runtime.models} in
      let config = provider_config configured model_id in
      check bool "runtime adapter carries the explicit effort" true
        (config.reasoning_effort = Some effort);
      check_effort "documented effort reaches the request"
        (Some (Provider.Reasoning_effort.to_string effort))
        (request {config with enable_thinking = Some true});
      (* The API documents none as K2.8 Preview routing without thinking.
         This asserts the requested control, not the served model identity. *)
      check_effort "explicit disable overrides the configured depth" (Some "none")
        (request {config with enable_thinking = Some false}))
      Provider.Reasoning_effort.[Low; High; Max];
    check_effort "explicit disable without a configured depth" (Some "none")
      (request {default with enable_thinking = Some false}))

let () =
  Alcotest.run "Kimi Coding replay"
    [ "configured HTTP checkpoint replay",
      List.concat_map (fun model_id ->
        List.map (fun stream ->
          test_case (model_id ^ if stream then " stream" else " sync") `Quick
            (test_configured_replay model_id ~stream)) [false; true])
        ["kimi-for-coding"; "kimi-k3"; "kimi-k3-256k"]
    ; "configured HTTP effort contract",
      List.map (fun model_id -> test_case model_id `Quick (test_configured_effort model_id))
        ["kimi-for-coding"; "kimi-k3"; "kimi-k3-256k"] ]
