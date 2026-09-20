(* Progress observation must not select a wire protocol the resolved model
   does not support. Exercise each public Runtime_agent dispatch path against
   a real loopback peer, with both JSON and SSE response controls. *)
open Alcotest
open Masc

type entry = Fresh | Cooperative | Checkpoint

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

let run_case entry ~supports_native_streaming ~observe () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  install_catalog ~sw ~supports_native_streaming;
  let expected_stream = supports_native_streaming && observe in
  let server =
    Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
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
        | Checkpoint ->
          let context = Keeper_context_core.create ~eio:true ~system_prompt in
          let checkpoint =
            Keeper_context_core.append context (Agent_core.Types.user_msg goal)
            |> Keeper_context_core.resume_checkpoint_of_context
          in
          Runtime_agent.continue_from_checkpoint ~sw ~net:env#net ~config
            ~checkpoint ?on_event ())
  in
  check int "one provider request" 1 (Exact_output_fixture.post_count server);
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
  let completed =
    match result with
    | Ok completed -> completed
    | Error error -> fail (Agent_core.Error.to_string error)
  in
  (match completed.Runtime_agent.stop_reason with
   | Runtime_agent.Completed -> ()
   | _ -> fail "provider answer must complete the run");
  check string "provider answer survives dispatch" answer
    (Agent_core.Types.text_of_content completed.response.content);
  if expected_stream then
    check string "streaming observer receives the answer delta" answer
      (Buffer.contents deltas)

let () =
  run "runtime agent streaming capability"
    (List.map
       (fun (name, entry) ->
         name,
         [ test_case "non-streaming model with observer uses JSON" `Quick
             (run_case entry ~supports_native_streaming:false ~observe:true)
         ; test_case "streaming model with observer keeps SSE" `Quick
             (run_case entry ~supports_native_streaming:true ~observe:true)
         ; test_case "streaming model without observer uses JSON" `Quick
             (run_case entry ~supports_native_streaming:true ~observe:false)
         ])
       [ "fresh", Fresh; "cooperative", Cooperative; "checkpoint", Checkpoint ])
