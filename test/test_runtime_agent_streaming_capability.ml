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

let install_catalog ~sw ~supports_native_streaming =
  let previous = Llm_provider.Model_catalog.global () in
  Eio.Switch.on_release sw (fun () ->
    match previous with
    | Some catalog -> Llm_provider.Model_catalog.set_global catalog
    | None -> Llm_provider.Model_catalog.clear_global ());
  let source =
    Printf.sprintf
      "[[models]]\nid_prefix = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 8192\nmax_output_tokens = 128\nsupports_native_streaming = %b\n"
      model_id supports_native_streaming
  in
  match Llm_provider.Model_catalog.of_toml_string ~source:"stream-dispatch-test" source with
  | Ok catalog -> Llm_provider.Model_catalog.set_global catalog
  | Error error -> fail error

let run_case ?(callbacks = Persist_callbacks)
    entry ~supports_native_streaming ~observe ~durable_execution () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  install_catalog ~sw ~supports_native_streaming;
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
        | Agent_core.Types.ContentBlockDelta { delta = TextDelta text; _ } ->
          Buffer.add_string deltas text
        | _ -> ())
    else None
  in
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
  if expected_stream then
    check string "streaming observer receives the answer delta" answer
      (Buffer.contents deltas)

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
     @ [ "callback persistence failures",
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
