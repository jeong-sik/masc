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
  let previous = Llm_provider.Catalog_snapshot.current () in
  Eio.Switch.on_release sw (fun () ->
    Llm_provider.Catalog_snapshot.publish previous);
  let source =
    Printf.sprintf
      "[[models]]\nmodel_id = %S\nprovider_name = \"fixture\"\nbase = %S\nmax_context_tokens = 8192\nmax_output_tokens = 128\nsupports_native_streaming = %b\n"
      model_id base supports_native_streaming
  in
  match Llm_provider.Model_catalog.of_toml_string ~source:"stream-dispatch-test" source with
  | Ok catalog -> (Llm_provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Some (catalog)) ~providers:(None)))
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
    Runtime_agent.default_config ~media_store:(Agent_core.History.Memory_store.create ()) ~name:"stream-dispatch-test"
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
      | Agent_core.Hooks.AfterRestoredTurn _
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
        | Fresh ->
          Runtime_agent.run ~sw ~net:env#net ~config ?on_event
            ~execution_capture:(Runtime_agent.execution_capture config) goal
        | Cooperative ->
          Runtime_agent.run ~sw ~net:env#net ~config ?on_event
            ~cooperative_yield_probe:(fun _ -> Ok Runtime_agent.Continue)
            ~execution_capture:(Runtime_agent.execution_capture config) goal
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
            ~checkpoint ?on_event ?cooperative_yield_probe
            ~execution_capture:(Runtime_agent.execution_capture config) ())
    |> Result.map_error Runtime_agent.run_failure_error
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
      | Runtime_agent.Completed _ -> ()
      | _ -> fail "provider answer must complete the run");
     check string "provider answer survives dispatch" answer
       (Llm_provider.Types.text_of_content completed.response.content)
   | Fail_scope_sink -> fail "unreachable provider effect after scope refusal");
  check (list string) "completed progress precedes existing collection hook"
    [if observe then answer else ""] !progress_at_collection;
  check string "observer receives the answer through the selected transport"
    (if observe then answer else "") (Buffer.contents deltas)

(* Drive the actual Keeper occurrence/media consumers, rather than treating
   text-only observer delivery as proof of a working tool loop. The rejected
   call precedes the admitted one: synthesizing the filtered AfterTurn
   response would lose its original inventory and assign the wrong block. *)
let completed_media_and_tools ?(execution_actor = Some "actual-keeper")
    ?(reported_model = model_id) ?(duplicate_rejected_id = false) entry () =
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
    `Assoc ["type", `String "tool_use"; "id", `String (if duplicate_rejected_id then "accepted-call" else "rejected-call");
      "name", `String "unregistered_fixture_tool"; "input", `Assoc []];
    `Assoc ["type", `String "tool_use"; "id", `String "accepted-call";
      "name", `String "fixture_effect"; "input", `Assoc []]] in
  let response ~id ~content ~stop_reason =
    Yojson.Safe.to_string (`Assoc [
      "id", `String id; "type", `String "message"; "role", `String "assistant";
      "model", `String reported_model; "content", content;
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
  let protocol_errors = ref [] in
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
      | Keeper_chat_events.Agent_core_stream_protocol_error error ->
        protocol_errors := error :: !protocol_errors
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
    | Agent_core.Hooks.AfterRestoredTurn _
    | Agent_core.Hooks.BeforeTurn _ | Agent_core.Hooks.BeforeTurnParams _
    | Agent_core.Hooks.PreToolUse _ | Agent_core.Hooks.PostToolUse _
    | Agent_core.Hooks.PostToolUseFailure _ | Agent_core.Hooks.OnStop _
    | Agent_core.Hooks.OnError _ | Agent_core.Hooks.OnToolError _ ->
      Agent_core.Hooks.Continue) } in
  let executions = ref 0 in
  let submitting_response = ref None in
  let tool = Agent_core.Tool.create ~name:"fixture_effect"
    ~description:"Return a synthetic effect receipt" ~parameters:[] (fun _ ->
      incr executions;
      submitting_response := Runtime_response_identity_scope.current ();
      Runtime_response_identity_scope.without_identity (fun () ->
        check bool "an uncaptured nested runtime cannot borrow the invoking model" true
          (Option.is_none (Runtime_response_identity_scope.current ())));
      Runtime_response_identity_scope.with_scope ~actor:(Some "nested") ~runtime_id:"nested-alias"
        ~provider_id:None (fun ~hooks:_ ~wrap_tool:_ ->
          check bool "a nested native run starts without its parent's identity" true
            (Option.is_none (Runtime_response_identity_scope.current ())));
      check bool "the submitting invocation retains its original identity" true
        (Runtime_response_identity_scope.current () = !submitting_response);
      Ok {Agent_core.Types.content="fixture effect"; content_blocks=None; _meta=None}) in
  let config = Runtime_agent.default_config ~media_store:(Agent_core.History.Memory_store.create ()) ~name:"agent_core-fixture-runtime"
      ~provider_cfg ~system_prompt ~tools:[tool] in
  let config = {config with hooks=Some hooks; execution_actor} in
  let result = Eio.Time.with_timeout_exn env#clock
    Exact_output_fixture.fixture_wait_seconds (fun () ->
      match entry with
      | Fresh ->
        Runtime_agent.run ~sw ~net:env#net ~config ~on_event
          ~execution_capture:(Runtime_agent.execution_capture config) goal
      | Cooperative -> Runtime_agent.run ~sw ~net:env#net ~config ~on_event
          ~cooperative_yield_probe:(fun _ -> Ok Runtime_agent.Continue)
          ~execution_capture:(Runtime_agent.execution_capture config) goal
      | Checkpoint | Cooperative_checkpoint ->
        let context = Keeper_context_core.create ~eio:true ~system_prompt in
        let checkpoint = Keeper_context_core.append context (Agent_core.Types.user_msg goal)
          |> Keeper_context_core.resume_checkpoint_of_context in
        let cooperative_yield_probe = match entry with
          | Cooperative_checkpoint -> Some (fun _ -> Ok Runtime_agent.Continue)
          | Checkpoint -> None
          | Fresh | Cooperative -> fail "unreachable checkpoint entry" in
        Runtime_agent.continue_from_checkpoint ~sw ~net:env#net ~config
          ~checkpoint ~on_event ?cooperative_yield_probe
          ~execution_capture:(Runtime_agent.execution_capture config) ())
    |> Result.map_error Runtime_agent.run_failure_error in
  let completed = match result with
    | Ok completed -> completed
    | Error error -> fail (Agent_core.Error.to_string error) in
  check int "one admitted effect executes" 1 !executions;
  let expected_model = if String.trim reported_model = "" then None else Some reported_model in
  (match execution_actor, expected_model, !submitting_response with
   | None, _, None | _, None, None -> ()
   | None, _, Some _ | _, None, Some _ -> fail "missing wire evidence must not invent response identity"
   | Some _, Some _, None -> fail "the native tool must retain its actual provider response identity"
   | Some actor, Some reported_model, Some identity ->
     check string "the tool belongs to the earlier response, not the final one"
       "media-tools" identity.response_id;
     check string "the admitted invocation owns the identity" "accepted-call" identity.tool_use_id;
     check int "the source ordinal survives removal of the preceding ToolUse"
       1 identity.source_tool_use_ordinal;
     check string "actual provider identity is retained" "fixture" identity.provider_id;
     check string "the host actor is independent of its synthetic agent name" actor identity.actor;
     check string "actual reported model is retained" reported_model identity.model_id);
  check bool "the completed native scope does not leak into its caller" true
    (Option.is_none (Runtime_response_identity_scope.current ()));
  check int "completed response preserves the Keeper stream contract" 0
    (List.length !protocol_errors);
  check int "both provider responses reach collection" 2 !collections;
  check int "tool loop completes with two provider responses" 2 !replies;
  check string "terminal response survives" answer
    (Llm_provider.Types.text_of_content completed.response.content);
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
  let config = Runtime_agent.default_config ~media_store:(Agent_core.History.Memory_store.create ()) ~name:"failed-progress"
    ~provider_cfg ~system_prompt ~tools:[] in
  let result = Eio.Time.with_timeout_exn env#clock
    Exact_output_fixture.fixture_wait_seconds (fun () ->
      Runtime_agent.run ~sw ~net:env#net ~config
        ~on_event:(fun event -> events := event :: !events)
        ~execution_capture:(Runtime_agent.execution_capture config) goal) in
  (* #52969: the refused request reached the transport, so the failure keeps
     the attempt it made instead of reporting a missing capture. *)
  (match result with
   | Error
       (Runtime_agent.Failed_after_dispatch
          { runtime_observation = observation; error = _ }) ->
     check string "the capture keeps the runtime identity" "failed-progress"
       observation.runtime_id;
     check int "the refused request is the captured attempt" 1
       (List.length observation.attempts);
     check bool "the captured attempt carries the provider error" true
       (List.for_all
          (fun (attempt : Runtime_observation.runtime_attempt) ->
             Option.is_some attempt.error)
          observation.attempts);
     check bool "the capture is execution evidence" true
       (match observation.execution_evidence with
        | Runtime_observation.Captured_execution -> true
        | Runtime_observation.Uncaptured_failure _ -> false);
     check string "the outcome receipt records the failure" "failed"
       (Keeper_execution_receipt.runtime_outcome_to_string
          (Keeper_agent_error.runtime_outcome_of_observation
             ~lane_failover_applied:false (Some observation)))
   | Error (Runtime_agent.Failed_before_dispatch error) ->
     failf "a refused provider request lost its capture: %s"
       (Agent_core.Error.to_string error)
   | Ok _ -> fail "provider refusal must remain a failed completion");
  check int "one refused JSON request" 1 (Exact_output_fixture.post_count server);
  check int "refusal does not synthesize a successful response" 0 (List.length !events)

let missing_admission_map_has_no_occurrence_identity () =
  Eio_main.run @@ fun _ ->
  Runtime_response_identity_scope.with_scope ~actor:(Some "actual-keeper")
    ~runtime_id:"runtime" ~provider_id:(Some "provider") (fun ~hooks ~wrap_tool ->
      let response : Agent_core.Types.api_response =
        { id="response"; model="reported-model"; unreadable_tool_uses = []; stop_reason=StopToolUse; usage=None
        ; content=[ToolUse {id="duplicate";name="first";input=`Assoc []};
                   ToolUse {id="duplicate";name="second";input=`Assoc []}]
        ; telemetry=Some (Llm_provider.Types.with_reported_model ~model:"reported-model" None) } in
      ignore (Agent_core.Hooks.invoke_validated hooks.after_turn
        (Agent_core.Hooks.AfterTurn {turn=1;response;tool_source_map=None}));
      let ran = ref false in
      let tool=Agent_core.Tool.create ~name:"first" ~description:"probe" ~parameters:[] (fun _ ->
        ran:=true;
        check bool "wire IDs alone cannot replace the missing admission map" true
          (Option.is_none (Runtime_response_identity_scope.current ()));
        Ok {Agent_core.Types.content="ok";content_blocks=None;_meta=None}) |> wrap_tool in
      let invocation=Agent_core.Tool_contract.Invocation.create ~tool_use_id:"duplicate" ~turn:1
        ~schedule:{planned_index=0;batch_index=0;batch_size=2;execution_mode=Serial}
        ~completion:Continue_after_success in
      (match Agent_core.Tool.execute ~invocation tool (`Assoc []) with
       | Ok _ -> () | Error error -> fail error.message);
      check bool "unknown metadata does not block the tool" true !ran)

(* #52969: the [runtime_execution_terminal] rows one capture emitted. *)
let terminal_rows ~since_seq observation_id =
  Log.Ring.recent ~since_seq ~module_filter:"Telemetry" ~order:`Oldest_first ()
  |> List.filter (fun (row : Log.Ring.entry) ->
    Yojson.Safe.Util.member "event" row.details = `String "runtime_execution_terminal"
    && Yojson.Safe.Util.member "observation_id" row.details = `String observation_id)

let row_field key (row : Log.Ring.entry) = Yojson.Safe.Util.member key row.details

let fixture_config ~name base_url =
  let provider_cfg = Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"fixture" ~model_id
    ~base_url ~request_path:"/v1/chat/completions" () in
  Runtime_agent.default_config ~media_store:(Agent_core.History.Memory_store.create ())
    ~name ~provider_cfg ~system_prompt ~tools:[]

let body_deadline_s = 0.3
let body_deadline_floor_ms = 200

(* Agent Core arms the body deadline outside the run's transport, so the
   deadline cancels the request first and becomes the run's error after it.
   The attempt still closes once, with that error and the time it ran. *)
let sync_body_timeout_closes_its_attempt_with_the_timeout () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  install_catalog ~sw ~supports_native_streaming:false ();
  Log.set_level Log.Info;
  let since_seq = (Log.Ring.bounds ()).total - 1 in
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
    (Exact_output_fixture.Delay_then_reply
       (Exact_output_fixture.fixture_wait_seconds, json_response)) in
  let config = fixture_config ~name:"body-timeout" server.base_url in
  let config = { config with body_timeout_s = Some body_deadline_s } in
  let result = Eio.Time.with_timeout_exn env#clock
    Exact_output_fixture.fixture_wait_seconds (fun () ->
      Runtime_agent.run ~sw ~net:env#net ~config
        ~execution_capture:(Runtime_agent.execution_capture config) goal) in
  match result with
  | Error (Runtime_agent.Failed_after_dispatch { runtime_observation; error }) ->
    (match runtime_observation.attempts with
     | [ attempt ] ->
       check (option string) "the attempt carries the run's timeout error"
         (Some (Agent_core.Error.to_string error)) attempt.error;
       check bool "the attempt keeps the time the request ran" true
         (match attempt.latency_ms with
          | Some latency_ms -> latency_ms >= body_deadline_floor_ms
          | None -> false)
     | attempts -> failf "one request, %d attempts" (List.length attempts));
    (match terminal_rows ~since_seq runtime_observation.observation_id with
     | [ row ] ->
       check bool "the terminal reports a failure" true
         (row_field "outcome" row = `String "failure")
     | rows -> failf "one request, %d terminal events" (List.length rows));
    check int "one request reached the provider" 1 (Exact_output_fixture.post_count server)
  | Error (Runtime_agent.Failed_before_dispatch error) ->
    failf "a timed-out request lost its capture: %s" (Agent_core.Error.to_string error)
  | Ok _ -> fail "a request past its body deadline must fail the run"

let cancelled_turn_closes_its_attempt_as_cancelled () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  install_catalog ~sw ~supports_native_streaming:false ();
  Log.set_level Log.Info;
  let since_seq = (Log.Ring.bounds ()).total - 1 in
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
    (Exact_output_fixture.Delay_then_reply
       (Exact_output_fixture.fixture_wait_seconds, json_response)) in
  let config = fixture_config ~name:"turn-cancel" server.base_url in
  let capture = Runtime_agent.execution_capture config in
  let ended = Eio.Time.with_timeout_exn env#clock
    Exact_output_fixture.fixture_wait_seconds (fun () ->
      Eio.Fiber.first
        (fun () ->
           match Runtime_agent.run ~sw ~net:env#net ~config ~execution_capture:capture goal with
           | Ok _ | Error _ -> `Run_returned)
        (fun () ->
           Eio.Promise.await server.first_request_arrived;
           `Turn_cancelled)) in
  check bool "the turn was cancelled while its request was in flight" true
    (ended = `Turn_cancelled);
  match Runtime_agent.run_failure_of_capture capture (Agent_core.Error.Internal "turn cancelled") with
  | Runtime_agent.Failed_after_dispatch { runtime_observation; error = _ } ->
    (match runtime_observation.attempts with
     | [ attempt ] ->
       check bool "the cancelled attempt is closed" true
         (Option.is_some attempt.error && Option.is_some attempt.latency_ms)
     | attempts -> failf "one request, %d attempts" (List.length attempts));
    (match terminal_rows ~since_seq runtime_observation.observation_id with
     | [ row ] ->
       check bool "the terminal reports a cancellation" true
         (row_field "outcome" row = `String "cancelled")
     | rows -> failf "one request, %d terminal events" (List.length rows))
  | Runtime_agent.Failed_before_dispatch _ ->
    fail "a cancelled request lost its capture"

let sequential_requests_close_their_own_attempts () =
  Eio_main.run @@ fun _env ->
  Log.set_level Log.Info;
  let since_seq = (Log.Ring.bounds ()).total - 1 in
  let config = fixture_config ~name:"sequential-attempts" "http://127.0.0.1:9" in
  let capture = Runtime_agent.execution_capture config in
  let response : Agent_core.Types.api_response =
    { id = "reply-1"; model = model_id; unreadable_tool_uses = []; stop_reason = EndTurn
    ; usage = None; content = [ Agent_core.Types.Text answer ]; telemetry = None } in
  let calls = ref 0 in
  let first_entered, enter_first = Eio.Promise.create () in
  let transport = Runtime_agent.For_testing.capture_provider_attempts capture
    (Llm_provider.Llm_transport.custom
       { complete_sync = (fun _ ->
           incr calls;
           (match !calls with
            | 1 -> Eio.Promise.resolve enter_first (); Eio.Fiber.await_cancel ()
            | _ -> ());
           { response = Ok response; latency_ms = None })
       ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _ -> Ok response) }) in
  let request : Llm_provider.Llm_transport.completion_request =
    { config = config.provider_cfg; messages = []; tools = []; admitted_http_body = None
    ; capture_id = None; observe_http_status = None; observe_wire_chunk = None
    ; request_wire_observer = None; stream_idle_timeout_s = None
    ; first_event_timeout_s = None; body_timeout_s = None } in
  let first =
    Eio.Fiber.first
      (fun () -> ignore (transport.invoke_sync request); `Returned)
      (fun () -> Eio.Promise.await first_entered; `Cut_off) in
  check bool "the first request was cut off" true (first = `Cut_off);
  ignore (transport.invoke_sync request);
  match Runtime_agent.run_failure_of_capture capture (Agent_core.Error.Internal "inspect") with
  | Runtime_agent.Failed_after_dispatch { runtime_observation; error = _ } ->
    (match runtime_observation.attempts with
     | [ cut_off; returned ] ->
       check bool "the cut-off request closed its own attempt" true
         (cut_off.attempt_index = 0 && Option.is_some cut_off.error);
       check bool "the second request closed its own attempt" true
         (returned.attempt_index = 1 && Option.is_none returned.error
          && Option.is_some returned.latency_ms)
     | attempts -> failf "two requests, %d attempts" (List.length attempts));
    let rows = terminal_rows ~since_seq runtime_observation.observation_id in
    check bool "one terminal per request, in request order" true
      (List.map (fun row -> row_field "attempt_index" row, row_field "outcome" row) rows
       = [ `Int 0, `String "cancelled"; `Int 1, `String "success" ])
  | Runtime_agent.Failed_before_dispatch _ -> fail "two requests left no attempt"

type media_entry = Structured_run | Stored_continuation | Direct_build | Direct_resume
type media_projection = Reading_projection | Unchanged_projection | No_projection

let media_runtime_config ~base_url ~media_store ~tools =
  let caps = { Llm_provider.Capabilities.openai_compat_chat_capabilities with
    supports_native_streaming = false; supports_multimodal_inputs = false;
    supports_image_input = false; supports_audio_input = false;
    supports_video_input = false; supports_document_input = false } in
  let provider_cfg = Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"fixture" ~model_id
      ~base_url ~request_path:"/v1/chat/completions"
      ~model_capabilities_override:caps () in
  Runtime_agent.default_config ~media_store ~name:"media-projection-admission-fixture"
    ~provider_cfg ~system_prompt ~tools

let media_projection_admission entry projection () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  install_catalog ~sw ~supports_native_streaming:false ();
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Reply json_response) in
  let media_store = Agent_core.History.Memory_store.create () in
  let raw = "canonical document bytes remain in the media store" in
  let stored = match media_store.put ~media_type:"application/pdf" ~raw with
    | Ok stored -> stored
    | Error error -> fail (Agent_core.Error.to_string (Agent_core.Error.Media error)) in
  let document = Agent_core.Types.document_block ~media_type:"application/pdf"
      ~source:(Agent_core.Types.Stored stored) in
  let input = Agent_core.Types.user_msg_blocks [document] in
  let context = Keeper_context_core.create ~eio:true ~system_prompt in
  let checkpoint = Keeper_context_core.append context input
      |> Keeper_context_core.resume_checkpoint_of_context in
  let checkpoint_before = Agent_core.Checkpoint.to_json checkpoint in
  let reading = "prepared document reading reaches the text-only provider" in
  let projections = ref 0 in
  let project messages =
    incr projections;
    check bool "projection receives the original Stored document" true
      (List.exists (fun (message : Agent_core.Types.message) ->
        List.mem document message.content) messages);
    let messages = match projection with
      | Reading_projection -> List.map (fun (message : Agent_core.Types.message) ->
          {message with content=List.map (fun block ->
            if block = document then Agent_core.Types.Text reading else block) message.content}) messages
      | Unchanged_projection -> messages
      | No_projection -> fail "raw admission cannot invoke a projection" in
    Agent_core.History.to_wire_messages media_store messages
      |> Result.map Agent_core.Agent.one_request
      |> Result.map_error (fun error -> Agent_core.Error.Media error) in
  let config = media_runtime_config ~base_url:server.base_url ~media_store ~tools:[] in
  let config = {config with model_input_projection=(match projection with
    | Reading_projection | Unchanged_projection -> Some project
    | No_projection -> None)} in
  check bool "fixture's selected model cannot accept documents" false
    (Runtime_agent.provider_caps_of_config config.provider_cfg).supports_document_input;
  let agent_ref = ref None in
  let from_runtime result =
    Result.map (fun (result : Runtime_agent.run_result) -> result.response) result
    |> Result.map_error Runtime_agent.run_failure_error in
  let built build = match build () with
    | Ok agent -> agent_ref := Some agent; agent
    | Error error -> fail (Agent_core.Error.to_string error) in
  let outcome = Eio.Time.with_timeout_exn env#clock
      Exact_output_fixture.fixture_wait_seconds (fun () -> match entry with
    | Structured_run -> from_runtime
        (Runtime_agent.run_blocks ~sw ~net:env#net ~config ~agent_ref
           ~execution_capture:(Runtime_agent.execution_capture config) [document])
    | Stored_continuation -> from_runtime
        (Runtime_agent.continue_from_checkpoint ~sw ~net:env#net ~config ~checkpoint ~agent_ref
           ~execution_capture:(Runtime_agent.execution_capture config) ())
    | Direct_build ->
      let agent = built (fun () -> Runtime_agent.build ~sw ~net:env#net ~config) in
      Agent_core.Agent.run_blocks ~sw agent [document]
    | Direct_resume ->
      let agent = built (fun () -> Runtime_agent.resume_from_checkpoint ~sw ~net:env#net ~config ~checkpoint) in
      Agent_core.Agent.Advanced.continue ~sw ~api_strategy:Agent_core.Agent.Sync
        ~on_tool_boundary:(fun _ -> Agent_core.Agent.Advanced.Continue) agent
      |> Result.map (function
        | Agent_core.Agent.Advanced.Completed completion -> completion.response
        | Agent_core.Agent.Advanced.Terminal_tool_completed completion -> completion.receipt.response
        | Agent_core.Agent.Advanced.Yielded _ -> fail "no tool boundary can yield this fixture")) in
  (match projection, outcome with
   | Reading_projection, Ok response ->
     check string "projected request receives its actual provider response" answer
       (Llm_provider.Types.text_of_content response.content)
   | (Unchanged_projection | No_projection),
       Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig {field; _})) ->
     check string "media rejection retains the existing capability error" "multimodal_input" field
   | (Reading_projection | Unchanged_projection | No_projection), Error error ->
     fail (Agent_core.Error.to_string error)
   | (Unchanged_projection | No_projection), Ok _ -> fail "unsupported document reached the provider");
  check int "only a supported final projection is dispatched"
    (match projection with Reading_projection -> 1 | Unchanged_projection | No_projection -> 0)
    (Exact_output_fixture.post_count server);
  check int "preflight never runs the selected projection itself"
    (match projection with Reading_projection | Unchanged_projection -> 1 | No_projection -> 0)
    !projections;
  List.iter (fun body ->
    check bool "actual HTTP carries the prepared reading" true
      (String_util.contains_substring body reading);
    check bool "actual HTTP excludes the retained document bytes" false
      (String_util.contains_substring body (Base64.encode_string raw)))
    (Exact_output_fixture.request_bodies server);
  Option.iter (fun agent ->
    check bool "canonical Agent state keeps its original Stored document" true
      (List.exists (fun (message : Agent_core.Types.message) -> List.mem document message.content)
         (Agent_core.Agent.state agent).messages)) !agent_ref;
  check bool "the caller's checkpoint is unchanged" true
    (checkpoint_before = Agent_core.Checkpoint.to_json checkpoint)

let projected_tool_media_is_validated_on_the_next_request () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  install_catalog ~sw ~supports_native_streaming:false ();
  let replies = ref 0 in
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Reply_with (fun _ _ ->
        incr replies;
        `OK, if !replies = 1 then
          {|{"id":"image-call","model":"stream-dispatch-fixture","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"media-tool","type":"function","function":{"name":"image_result","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}|}
        else json_response)) in
  let executions = ref 0 in
  let image = Llm_provider.Types.image_block ~media_type:"image/png"
      ~source:(Llm_provider.Types.Base64
        "iVBORw0KGgoAAAANSUhEUgAAAEAAAAAgCAYAAACinX6EAAAAS0lEQVR4nO3QMQ0AIAwAsInABja4UbwbV0PGkqVHDTRW3ur09mkVAgQIECBAgAABAgQIECBAgAABAgQIECBAgAABAgQIECBAwPyADyLYbQCQNiXPAAAAAElFTkSuQmCC") in
  let tool = Agent_core.Tool.create ~name:"image_result" ~description:"Return an image fixture"
      ~parameters:[] (fun _ ->
        incr executions;
        Ok {Agent_core.Types.content="the image result";content_blocks=Some [image];_meta=None}) in
  let media_store = Agent_core.History.Memory_store.create () in
  let projections = ref 0 in
  let project messages =
    incr projections;
    Agent_core.History.to_wire_messages media_store messages
      |> Result.map Agent_core.Agent.one_request
      |> Result.map_error (fun error -> Agent_core.Error.Media error) in
  let config = media_runtime_config ~base_url:server.base_url ~media_store ~tools:[tool] in
  let config = {config with model_input_projection=Some project} in
  let agent_ref = ref None in
  let outcome = Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds
      (fun () ->
        Runtime_agent.run ~sw ~net:env#net ~config ~agent_ref
          ~execution_capture:(Runtime_agent.execution_capture config) "Read an image result."
        |> Result.map_error Runtime_agent.run_failure_error) in
  (match outcome with
   | Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig {field; _})) ->
     check string "new nested media is refused by the existing capability floor" "multimodal_input" field
   | Error error -> fail (Agent_core.Error.to_string error)
   | Ok _ -> fail "the second request bypassed projected media admission");
  check int "the text request executes the tool exactly once" 1 !executions;
  check int "each request has its own final projected input check" 2 !projections;
  check int "unsupported nested image never reaches a second HTTP request" 1
    (Exact_output_fixture.post_count server);
  let agent = match !agent_ref with Some agent -> agent | None -> fail "the first request must build an agent" in
  check bool "the failed projection keeps the original tool media in canonical history" true
    (List.exists (fun (message : Agent_core.Types.message) ->
      Llm_provider.Types.content_has_image message.content) (Agent_core.Agent.state agent).messages)

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
       ; "execution capture attempts",
         [ test_case "a sync body timeout closes its attempt with the timeout" `Quick
             sync_body_timeout_closes_its_attempt_with_the_timeout
         ; test_case "a cancelled turn closes its attempt as cancelled" `Quick
             cancelled_turn_closes_its_attempt_as_cancelled
         ; test_case "sequential requests close their own attempts" `Quick
             sequential_requests_close_their_own_attempts ]
       ; "projected media admission",
         List.concat_map (fun (name, entry) ->
           [test_case (name ^ ": canonical document can become supported text") `Quick
              (media_projection_admission entry Reading_projection)
           ;test_case (name ^ ": unsupported projected document is refused before HTTP") `Quick
              (media_projection_admission entry Unchanged_projection)])
           ["structured run",Structured_run; "checkpoint continuation",Stored_continuation;
            "direct build",Direct_build; "direct resume",Direct_resume]
         @ [test_case "raw structured input keeps canonical admission" `Quick
              (media_projection_admission Structured_run No_projection)
           ;test_case "raw continuation keeps canonical admission" `Quick
              (media_projection_admission Stored_continuation No_projection)
           ;test_case "new tool-result media is checked before the next request" `Quick
              projected_tool_media_is_validated_on_the_next_request]
       ; "completed media and original tool admission",
         List.map (fun (name, entry) -> test_case name `Quick
           (completed_media_and_tools entry))
           ["fresh", Fresh; "cooperative", Cooperative; "checkpoint", Checkpoint;
            "cooperative checkpoint", Cooperative_checkpoint]
       ; "response identity gaps",
         [test_case "a synthetic agent name cannot replace a missing host actor" `Quick
           (completed_media_and_tools ~execution_actor:None Fresh)
         ; test_case "a blank reported model remains unknown after presentation fallback" `Quick
           (completed_media_and_tools ~reported_model:"" Fresh)
         ; test_case "registered and rejected tools sharing an ID retain the admitted source ordinal" `Quick
           (completed_media_and_tools ~duplicate_rejected_id:true Fresh)
         ; test_case "a missing admission map keeps exact occurrence unknown" `Quick
           missing_admission_map_has_no_occurrence_identity]
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
