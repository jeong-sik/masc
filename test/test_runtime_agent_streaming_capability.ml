(* Progress observation must not select a wire protocol the resolved model
   does not support. Exercise each public Runtime_agent dispatch path against
   a real loopback peer, with both JSON and SSE response controls. A supplied
   durable scope must persist its locator before the request and deliver its
   terminal disposition before returning through every native dispatch. *)
open Alcotest
open Masc

type entry = Fresh | Cooperative | Checkpoint | Cooperative_checkpoint
type callbacks = Persist_callbacks | Fail_scope_sink | Fail_terminal_sink

let model_id = "stream-dispatch-fixture"
let system_prompt = "Return the fixture answer."
let goal = "Reply once without tools."
let answer = "fixture answer"

let json_response =
  {|{"id":"reply-1","model":"stream-dispatch-fixture","choices":[{"index":0,"message":{"role":"assistant","content":"fixture answer"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}

let sse_response =
  "data: {\"id\":\"reply-1\",\"model\":\"stream-dispatch-fixture\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"fixture answer\"},\"finish_reason\":null}]}\n\n\
   data: {\"id\":\"reply-1\",\"model\":\"stream-dispatch-fixture\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}\n\n\
   data: [DONE]\n\n"

let install_catalog ?(base = "openai_chat") ~sw ~supports_native_streaming () =
  let previous = Llm_provider.Model_catalog.global () in
  Eio.Switch.on_release sw (fun () ->
    match previous with
    | Some catalog -> Llm_provider.Model_catalog.set_global catalog
    | None -> Llm_provider.Model_catalog.clear_global ());
  let source =
    Printf.sprintf
      "[[models]]\nid_prefix = %S\nprovider_name = \"fixture\"\nbase = %S\nmax_context_tokens = 8192\nmax_output_tokens = 128\nsupports_native_streaming = %b\n"
      model_id base supports_native_streaming
  in
  match Llm_provider.Model_catalog.of_toml_string ~source:"stream-dispatch-test" source with
  | Ok catalog -> Llm_provider.Model_catalog.set_global catalog
  | Error error -> fail error

let run_case ?(callbacks = Persist_callbacks) ?(observer_failure = false)
    entry ~supports_native_streaming ~observe ~durable_execution () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  install_catalog ~sw ~supports_native_streaming ();
  let scope_ready = Atomic.make None in
  let scope_callbacks = Atomic.make 0 in
  let terminal_dispositions = Atomic.make [] in
  let scope_ready_at_provider = Atomic.make [] in
  let execution_store =
    if not durable_execution then None
    else
      let path = Filename.temp_file "runtime-agent-execution-" ".dir" in
      Sys.remove path;
      let dir = Eio.Path.(env#fs / path) in
      Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
      Eio.Switch.on_release sw (fun () -> Eio.Path.rmtree ~missing_ok:true dir);
      let runtime =
        match Agent_core.Agent.create_execution_runtime
            ~sw ~domain_mgr:env#domain_mgr ~domain_count:1 with
        | Ok runtime -> runtime
        | Error error -> fail (Agent_core.Error.to_string error)
      in
      Some (Agent_core.Agent.execution_store ~runtime ~dir
        ~on_scope_ready:(fun locator ->
          Atomic.incr scope_callbacks;
          match callbacks with
          | Fail_scope_sink -> Error "fixture locator persistence failure"
          | Persist_callbacks | Fail_terminal_sink ->
            Eio.Path.save ~create:(`Exclusive 0o600)
              Eio.Path.(dir / "host-locator.json")
              (Yojson.Safe.to_string (Agent_core.Agent.execution_locator_to_yojson locator));
            Atomic.set scope_ready (Some locator);
            Ok ())
        ~on_terminal_disposition:(fun disposition ->
          Atomic.set terminal_dispositions
            (disposition :: Atomic.get terminal_dispositions);
          match callbacks with
          | Fail_terminal_sink -> Error "fixture terminal persistence failure"
          | Persist_callbacks | Fail_scope_sink -> Ok ())
        ())
  in
  let expected_stream = supports_native_streaming && observe in
  let server =
    Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      ~on_request_before_reply:(fun () ->
        Atomic.set scope_ready_at_provider
          (Option.is_some (Atomic.get scope_ready) :: Atomic.get scope_ready_at_provider))
      (if expected_stream then Exact_output_fixture.Stream_reply sse_response
       else Exact_output_fixture.Reply json_response)
  in
  let provider_cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~provider_id:"fixture" ~model_id
      ~base_url:server.Exact_output_fixture.base_url
      ~request_path:"/v1/chat/completions" ()
  in
  check bool "catalog capability reaches the actual provider config"
    supports_native_streaming
    (Runtime_agent.provider_caps_of_config provider_cfg).supports_native_streaming;
  let config =
    Runtime_agent.default_config ~name:"stream-dispatch-test"
      ~provider_cfg ~system_prompt ~tools:[]
  in
  check bool "ordinary dispatch has no execution store by default" true
    (Option.is_none config.execution_store);
  let config = { config with execution_store } in
  let deltas = Buffer.create 32 in
  let on_event =
    if observe then
      Some (function
        | Agent_core.Types.MessageStart _ when observer_failure ->
          failwith "fixture non-fatal progress observer failure"
        | Agent_core.Types.ContentBlockDelta { delta = TextDelta text; _ } ->
          Buffer.add_string deltas text
        | _ -> ())
    else None
  in
  let progress_at_collection = ref [] in
  let hooks = { Agent_core.Hooks.empty with
    after_turn = Some (function
      | Agent_core.Hooks.AfterTurn _ ->
        progress_at_collection := Buffer.contents deltas :: !progress_at_collection;
        Agent_core.Hooks.Continue
      | Agent_core.Hooks.BeforeTurn _ | Agent_core.Hooks.BeforeTurnParams _
      | Agent_core.Hooks.PreToolUse _ | Agent_core.Hooks.PostToolUse _
      | Agent_core.Hooks.PostToolUseFailure _ | Agent_core.Hooks.OnStop _
      | Agent_core.Hooks.OnError _ | Agent_core.Hooks.OnToolError _ ->
        Agent_core.Hooks.Continue) } in
  let config = { config with hooks = Some hooks } in
  let result =
    Eio.Time.with_timeout_exn env#clock
      Exact_output_fixture.fixture_wait_seconds (fun () ->
        match entry with
        | Fresh -> Runtime_agent.run ~sw ~net:env#net ~config ?on_event goal
        | Cooperative ->
          Runtime_agent.run ~sw ~net:env#net ~config ?on_event
            ~cooperative_yield_probe:(fun _ -> Ok Runtime_agent.Continue) goal
        | Checkpoint | Cooperative_checkpoint ->
          let context = Keeper_context_core.create ~eio:true ~system_prompt in
          let checkpoint =
            Keeper_context_core.append context (Agent_core.Types.user_msg goal)
            |> Keeper_context_core.resume_checkpoint_of_context
          in
          let cooperative_yield_probe =
            match entry with
            | Cooperative_checkpoint -> Some (fun _ -> Ok Runtime_agent.Continue)
            | Checkpoint -> None
            | Fresh | Cooperative -> fail "unreachable checkpoint entry"
          in
          Runtime_agent.continue_from_checkpoint ~sw ~net:env#net ~config
            ~checkpoint ?on_event ?cooperative_yield_probe ())
  in
  check int "scope persistence callback reaches the selected dispatch"
    (if durable_execution then 1 else 0) (Atomic.get scope_callbacks);
  (match durable_execution, callbacks, Atomic.get terminal_dispositions with
   | false, Persist_callbacks, [] -> ()
   | true, Fail_scope_sink,
       [ { Agent_core.Agent.outcome = Terminal_failed; recovery = Retire } ] -> ()
   | true, (Persist_callbacks | Fail_terminal_sink),
       [ { Agent_core.Agent.outcome = Terminal_succeeded; recovery = Retire } ] -> ()
   | _ -> fail "dispatch must deliver its terminal disposition exactly once before returning");
  let check_callback_failure () =
    match result with
    | Error (Agent_core.Error.Internal _) -> ()
    | Error error -> fail (Agent_core.Error.to_string error)
    | Ok _ -> fail "callback persistence failure was not propagated"
  in
  match callbacks with
  | Fail_scope_sink ->
    check int "failed locator persistence admits no provider request" 0
      (Exact_output_fixture.post_count server);
    check (list bool) "provider effect did not run" [] (Atomic.get scope_ready_at_provider);
    check_callback_failure ()
  | Persist_callbacks | Fail_terminal_sink ->
  check int "one provider request" 1 (Exact_output_fixture.post_count server);
  check (list bool) "scope ready precedes the provider effect"
    [durable_execution] (Atomic.get scope_ready_at_provider);
  let request =
    match Exact_output_fixture.request_bodies server with
    | [body] ->
      (* Synthetic request evidence remains visible when the baseline fails. *)
      Format.eprintf "captured request: %s@." body;
      Yojson.Safe.from_string body
    | _ -> fail "expected one captured provider request"
  in
  (* OpenAI-compatible sync serialization omits [stream]; streaming emits
     [true]. Assert that actual codec contract, including absence. *)
  let stream_field =
    Yojson.Safe.Util.to_assoc request |> List.assoc_opt "stream"
    |> Option.map Yojson.Safe.Util.to_bool
  in
  check (option bool) "wire stream matches capability and observation request"
    (if expected_stream then Some true else None) stream_field;
  (match callbacks with
   | Fail_terminal_sink -> check_callback_failure ()
   | Persist_callbacks ->
     let completed =
       match result with
       | Ok completed -> completed
       | Error error -> fail (Agent_core.Error.to_string error)
     in
     (match completed.Runtime_agent.stop_reason with
      | Runtime_agent.Completed -> ()
      | _ -> fail "provider answer must complete the run");
     check string "provider answer survives dispatch" answer
       (Agent_core.Types.text_of_content completed.response.content)
   | Fail_scope_sink -> fail "unreachable provider effect after scope refusal");
  check (list string) "completed progress precedes existing collection hook"
    [if observe then answer else ""] !progress_at_collection;
  check string "observer receives the answer through the selected transport"
    (if observe then answer else "") (Buffer.contents deltas)

(* Drive the actual Keeper occurrence/media consumers, rather than treating
   text-only observer delivery as proof of a working tool loop. The rejected
   call precedes the admitted one: synthesizing the filtered AfterTurn
   response would lose its original inventory and assign the wrong block. *)
let completed_media_and_tools entry () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  install_catalog ~base:"anthropic" ~sw ~supports_native_streaming:false ();
  let path = Filename.temp_file "completed-response-media-" ".dir" in
  Sys.remove path;
  let dir = Eio.Path.(env#fs / path) in
  Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
  Eio.Switch.on_release sw (fun () -> Eio.Path.rmtree ~missing_ok:true dir);
  let media_payload = Base64.decode_exn
    "iVBORw0KGgoAAAANSUhEUgAAAEAAAAAgCAYAAACinX6EAAAAS0lEQVR4nO3QMQ0AIAwAsInABja4UbwbV0PGkqVHDTRW3ur09mkVAgQIECBAgAABAgQIECBAgAABAgQIECBAgAABAgQIECBAwPyADyLYbQCQNiXPAAAAAElFTkSuQmCC" in
  let content = `List [
    `Assoc ["type", `String "image"; "source", `Assoc [
      "type", `String "base64"; "media_type", `String "image/png";
      "data", `String (Base64.encode_string media_payload)]];
    `Assoc ["type", `String "tool_use"; "id", `String "rejected-call";
      "name", `String "unregistered_fixture_tool"; "input", `Assoc []];
    `Assoc ["type", `String "tool_use"; "id", `String "accepted-call";
      "name", `String "fixture_effect"; "input", `Assoc []]] in
  let response ~id ~content ~stop_reason =
    Yojson.Safe.to_string (`Assoc [
      "id", `String id; "type", `String "message"; "role", `String "assistant";
      "model", `String model_id; "content", content;
      "stop_reason", `String stop_reason; "stop_sequence", `Null;
      "usage", `Assoc ["input_tokens", `Int 10; "output_tokens", `Int 20]]) in
  let replies = ref 0 in
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
    (Exact_output_fixture.Reply_with (fun _ body ->
      let json = Yojson.Safe.from_string body in
      if Yojson.Safe.Util.member "max_tokens" json = `Null
      then `OK, {|{"input_tokens":10}|}
      else begin
        check (option bool) "observed response still uses JSON" (Some false)
          (Yojson.Safe.Util.member "stream" json |> Yojson.Safe.Util.to_bool_option);
        incr replies;
        match !replies with
        | 1 -> `OK, response ~id:"media-tools" ~content ~stop_reason:"tool_use"
        | 2 -> `OK, response ~id:"final" ~stop_reason:"end_turn"
            ~content:(`List [`Assoc ["type", `String "text"; "text", `String answer]])
        | _ -> fail "unexpected extra provider completion"
      end)) in
  let provider_cfg = Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.Anthropic ~provider_id:"fixture" ~model_id
      ~base_url:server.base_url ~request_path:"/v1/messages" () in
  let accum = Keeper_stream_tool_accum.create () in
  let bridge = ref (Keeper_chat_agent_core_stream_bridge.empty_state ()) in
  let media = ref [] in
  let on_event event =
    Keeper_stream_tool_accum.on_event accum event;
    let translated = Keeper_chat_agent_core_stream_bridge.translate
      ~redact_text:Fun.id ~base_dir:path
      ~stream_scope:(Keeper_stream_tool_accum.current_stream_scope accum)
      !bridge event in
    bridge := translated.bridge_state;
    List.iter (function
      | Keeper_chat_events.Agent_core_media_delta { media_ref; _ } ->
        media := media_ref :: !media
      | Keeper_chat_events.Agent_core_stream_protocol_error _ ->
        fail "completed response must preserve the real Keeper stream contract"
      | _ -> ()) translated.chat_events in
  let collections = ref 0 in
  let hooks = { Agent_core.Hooks.empty with after_turn = Some (function
    | Agent_core.Hooks.AfterTurn { turn; tool_source_map; _ } ->
      incr collections;
      let tool_source_map = match tool_source_map with
        | Some mapping -> mapping
        | None -> fail "Agent Core response must retain its original tool mapping" in
      (match Keeper_stream_tool_accum.seal_turn accum ~turn ~tool_source_map with
       | Ok _ -> ()
       | Error detail -> fail detail);
      Agent_core.Hooks.Continue
    | Agent_core.Hooks.BeforeTurn _ | Agent_core.Hooks.BeforeTurnParams _
    | Agent_core.Hooks.PreToolUse _ | Agent_core.Hooks.PostToolUse _
    | Agent_core.Hooks.PostToolUseFailure _ | Agent_core.Hooks.OnStop _
    | Agent_core.Hooks.OnError _ | Agent_core.Hooks.OnToolError _ ->
      Agent_core.Hooks.Continue) } in
  let executions = ref 0 in
  let tool = Agent_core.Tool.create ~name:"fixture_effect"
    ~description:"Return a synthetic effect receipt" ~parameters:[] (fun _ ->
      incr executions;
      Ok {Agent_core.Types.content="fixture effect"; content_blocks=None; _meta=None}) in
  let config = Runtime_agent.default_config ~name:"completed-progress"
      ~provider_cfg ~system_prompt ~tools:[tool] in
  let config = {config with hooks=Some hooks} in
  let result = Eio.Time.with_timeout_exn env#clock
    Exact_output_fixture.fixture_wait_seconds (fun () ->
      match entry with
      | Fresh -> Runtime_agent.run ~sw ~net:env#net ~config ~on_event goal
      | Cooperative -> Runtime_agent.run ~sw ~net:env#net ~config ~on_event
          ~cooperative_yield_probe:(fun _ -> Ok Runtime_agent.Continue) goal
      | Checkpoint | Cooperative_checkpoint ->
        let context = Keeper_context_core.create ~eio:true ~system_prompt in
        let checkpoint = Keeper_context_core.append context (Agent_core.Types.user_msg goal)
          |> Keeper_context_core.resume_checkpoint_of_context in
        let cooperative_yield_probe = match entry with
          | Cooperative_checkpoint -> Some (fun _ -> Ok Runtime_agent.Continue)
          | Checkpoint -> None
          | Fresh | Cooperative -> fail "unreachable checkpoint entry" in
        Runtime_agent.continue_from_checkpoint ~sw ~net:env#net ~config
          ~checkpoint ~on_event ?cooperative_yield_probe ()) in
  let completed = match result with
    | Ok completed -> completed
    | Error error -> fail (Agent_core.Error.to_string error) in
  check int "one admitted effect executes" 1 !executions;
  check int "both provider responses reach collection" 2 !collections;
  check int "tool loop completes with two provider responses" 2 !replies;
  check string "terminal response survives" answer
    (Agent_core.Types.text_of_content completed.response.content);
  (match !media with
   | [media_ref] ->
     let token = Filename.basename media_ref in
     let media_path = match Keeper_chat_media_store.file_path_of_token ~base_dir:path ~token with
       | Some path -> path
       | None -> fail "generated media reference does not name stored bytes" in
     check string "base64 decodes to original stored payload" media_payload
       (Eio.Path.load Eio.Path.(env#fs / media_path))
   | _ -> fail "one successful media block must publish one reference")

let failed_completion_has_no_progress () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  install_catalog ~sw ~supports_native_streaming:false ();
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
    (Exact_output_fixture.Reply_with (fun _ _ ->
      `Bad_request, {|{"error":{"message":"fixture refused input","type":"invalid_request_error"}}|})) in
  let provider_cfg = Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"fixture" ~model_id
    ~base_url:server.base_url ~request_path:"/v1/chat/completions" () in
  let events = ref [] in
  let config = Runtime_agent.default_config ~name:"failed-progress"
    ~provider_cfg ~system_prompt ~tools:[] in
  let result = Eio.Time.with_timeout_exn env#clock
    Exact_output_fixture.fixture_wait_seconds (fun () ->
      Runtime_agent.run ~sw ~net:env#net ~config
        ~on_event:(fun event -> events := event :: !events) goal) in
  (match result with
   | Error _ -> ()
   | Ok _ -> fail "provider refusal must remain a failed completion");
  check int "one refused JSON request" 1 (Exact_output_fixture.post_count server);
  check int "refusal does not synthesize a successful response" 0 (List.length !events)

let () =
  run "runtime agent streaming capability"
    (List.map
       (fun (name, entry) ->
         name,
         List.concat_map (fun (mode, durable_execution) ->
           [ test_case (mode ^ ": non-streaming model with observer uses JSON") `Quick
               (run_case entry ~supports_native_streaming:false ~observe:true ~durable_execution)
           ; test_case (mode ^ ": streaming model with observer keeps SSE") `Quick
               (run_case entry ~supports_native_streaming:true ~observe:true ~durable_execution)
           ; test_case (mode ^ ": streaming model without observer uses JSON") `Quick
               (run_case entry ~supports_native_streaming:true ~observe:false ~durable_execution)
           ]) [ "ordinary", false; "durable", true ])
       [ "fresh", Fresh; "cooperative", Cooperative; "checkpoint", Checkpoint
       ; "cooperative checkpoint", Cooperative_checkpoint ]
     @ [ "observer exceptions",
         [test_case "JSON progress keeps the native non-fatal callback contract" `Quick
           (run_case ~observer_failure:true Fresh ~supports_native_streaming:false
             ~observe:true ~durable_execution:false);
          test_case "refused JSON completion publishes no response" `Quick
            failed_completion_has_no_progress]
       ; "completed media and original tool admission",
         List.map (fun (name, entry) -> test_case name `Quick
           (completed_media_and_tools entry))
           ["fresh", Fresh; "cooperative", Cooperative; "checkpoint", Checkpoint;
            "cooperative checkpoint", Cooperative_checkpoint]
       ; "callback persistence failures",
         [ test_case "fresh JSON scope failure admits no provider request" `Quick
             (run_case ~callbacks:Fail_scope_sink Fresh
                ~supports_native_streaming:false ~observe:false ~durable_execution:true)
         ; test_case "fresh SSE scope failure admits no provider request" `Quick
             (run_case ~callbacks:Fail_scope_sink Fresh
                ~supports_native_streaming:true ~observe:true ~durable_execution:true)
         ; test_case "cooperative scope failure admits no provider request" `Quick
             (run_case ~callbacks:Fail_scope_sink Cooperative
                ~supports_native_streaming:false ~observe:false ~durable_execution:true)
         ; test_case "checkpoint scope failure admits no provider request" `Quick
             (run_case ~callbacks:Fail_scope_sink Checkpoint
                ~supports_native_streaming:false ~observe:false ~durable_execution:true)
         ; test_case "cooperative checkpoint scope failure admits no provider request" `Quick
             (run_case ~callbacks:Fail_scope_sink Cooperative_checkpoint
                ~supports_native_streaming:false ~observe:false ~durable_execution:true)
         ; test_case "terminal persistence failure propagates after provider completion" `Quick
             (run_case ~callbacks:Fail_terminal_sink Fresh
                ~supports_native_streaming:false ~observe:false ~durable_execution:true)
         ] ])
