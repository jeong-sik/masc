(* A separate process exits after Core settles the ToolResult but before the
   host saves the tool-result checkpoint. A returned Error would terminally
   abort the journal and would not represent this interruption. *)
open Masc

let model_id = "execution-restart-fixture"
let agent_name = "execution-restart-agent"
let system_prompt = "Use the fixture tool and report its receipt."
let goal = "Run the persisted effect."
let seed = [Agent_core.Types.user_msg "Earlier context, before this operation."]
let crash_exit = 86

let tool_reply =
  {|{"id":"tool-reply","model":"execution-restart-fixture","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"effect-call-1","type":"function","function":{"name":"persisted_effect","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}

let final_reply =
  {|{"id":"final-reply","model":"execution-restart-fixture","choices":[{"index":0,"message":{"role":"assistant","content":"effect receipt preserved"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}

let write path bytes =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () ->
    output_string channel bytes;
    flush channel;
    Unix.fsync (Unix.descr_of_out_channel channel))

let read path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
    really_input_string channel (in_channel_length channel))

let record root name =
  let channel = open_out_gen [Open_wronly; Open_creat; Open_append; Open_binary]
      0o600 (Filename.concat root (name ^ ".events")) in
  Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () ->
    output_string channel "observed\n";
    flush channel;
    Unix.fsync (Unix.descr_of_out_channel channel))

let count root name =
  let path = Filename.concat root (name ^ ".events") in
  if Sys.file_exists path then
    read path |> String.split_on_char '\n'
    |> List.filter (fun line -> line <> "") |> List.length
  else 0

let or_fail = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Agent_core.Error.to_string error)

let install_catalog ~sw =
  let previous = Llm_provider.Model_catalog.global () in
  Eio.Switch.on_release sw (fun () -> match previous with
    | None -> Llm_provider.Model_catalog.clear_global ()
    | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
  let source = Printf.sprintf
      "[[models]]\nid_prefix = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 8192\nmax_output_tokens = 128\nsupports_native_streaming = false\n" model_id in
  match Llm_provider.Model_catalog.of_toml_string ~source:"execution-restart-test" source with
  | Ok catalog -> Llm_provider.Model_catalog.set_global catalog
  | Error detail -> Alcotest.fail detail

let setup ~sw env ~root ~reply ~require_receipt =
  Masc_test_deps.init_eio_clock ~sw env;
  install_catalog ~sw;
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      ~on_request_before_reply:(fun () -> record root "provider")
      (Exact_output_fixture.Reply_with (fun _ body ->
        if require_receipt then (
          let open Yojson.Safe.Util in
          let receipts = body |> Yojson.Safe.from_string |> member "messages" |> to_list
            |> List.filter (fun message -> member "role" message = `String "tool")
            |> List.map (fun message -> member "content" message |> to_string) in
          Alcotest.(check (list string)) "settled result reaches resumed provider"
            ["effect receipt"] receipts);
        `OK, reply)) in
  let provider_cfg = Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"fixture"
      ~model_id ~base_url:server.base_url ~request_path:"/v1/chat/completions" () in
  let tool = Agent_core.Tool.create ~name:"persisted_effect"
      ~description:"Record one externally visible effect" ~parameters:[]
      (fun _ ->
        record root "handler";
        Ok {Agent_core.Types.content="effect receipt"; content_blocks=None; _meta=None}) in
  let hooks = { Agent_core.Hooks.empty with
    pre_tool_use = Some (fun _ -> record root "gate"; Agent_core.Hooks.Continue);
    post_tool_use = Some (fun _ -> record root "observer"; Agent_core.Hooks.Continue) } in
  let config = Runtime_agent.default_config ~name:agent_name ~provider_cfg
      ~system_prompt ~tools:[tool] in
  let config = {config with initial_messages=seed; hooks=Some hooks} in
  let runtime = Agent_core.Agent.create_execution_runtime ~sw
      ~domain_mgr:env#domain_mgr ~domain_count:1 |> or_fail in
  let dir = Eio.Path.(env#fs / Filename.concat root "journal") in
  config, runtime, dir

let child root =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let config, runtime, dir = setup ~sw env ~root ~reply:tool_reply ~require_receipt:false in
  Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
  let execution_store = Agent_core.Agent.execution_store ~runtime ~dir
      ~on_scope_ready:(fun locator ->
        Agent_core.Agent.execution_locator_to_yojson locator |> Yojson.Safe.to_string
        |> write (Filename.concat root "locator.json");
        Ok ()) () in
  let checkpoint_sink (snapshot : Agent_core.Agent.checkpoint_snapshot) =
    match snapshot.stage with
    | Agent_core.Agent.After_assistant_collected ->
      let checkpoint = {snapshot.checkpoint with session_id="execution-restart-session"} in
      write (Filename.concat root "checkpoint.json")
        (Agent_core.Checkpoint.to_string checkpoint);
      Ok ()
    | Agent_core.Agent.After_tool_results_appended -> Unix._exit crash_exit
    | Agent_core.Agent.After_context_injection
    | Agent_core.Agent.After_rejected_response_dropped -> Ok ()
  in
  let config = {config with execution_store=Some execution_store;
    checkpoint_sink=Some checkpoint_sink} in
  let _ = Runtime_agent.run ~sw ~net:env#net ~config goal |> or_fail in
  Alcotest.fail "child returned instead of stopping at the settled result boundary"

let assert_counts root ~providers =
  List.iter (fun name -> Alcotest.(check int) (name ^ " observed once") 1 (count root name))
    ["handler"; "gate"; "observer"];
  Alcotest.(check int) "provider request count" providers (count root "provider")

let run_restart () =
  let root = Filename.temp_file "runtime-execution-restart-" ".dir" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> Eio.Path.rmtree ~missing_ok:true Eio.Path.(env#fs / root));
  (* Spawn rather than fork the multithreaded Eio runtime. The child owns its
     provider fixture and all Core execution domains. *)
  let process = Eio.Process.spawn ~sw env#process_mgr
      [Sys.executable_name; "--execution-restart-child"; root] in
  (match Eio.Time.with_timeout_exn env#clock
      Exact_output_fixture.fixture_wait_seconds (fun () -> Eio.Process.await process) with
   | `Exited code -> Alcotest.(check int) "hard interruption boundary" crash_exit code
   | `Signaled signal -> Alcotest.failf "child died from signal %d" signal);
  assert_counts root ~providers:1;
  let config, runtime, dir = setup ~sw env ~root ~reply:final_reply ~require_receipt:true in
  let locator = match read (Filename.concat root "locator.json") |> Yojson.Safe.from_string
      |> Agent_core.Agent.execution_locator_of_yojson with
    | Ok locator -> locator | Error detail -> Alcotest.fail detail in
  let checkpoint = match read (Filename.concat root "checkpoint.json") |> Yojson.Safe.from_string
      |> Agent_core.Checkpoint.of_json with
    | Ok checkpoint -> checkpoint | Error detail -> Alcotest.fail detail in
  let terminal = ref None in
  let resume config input =
    let execution_store = Agent_core.Agent.execution_store ~runtime ~dir ~resume:locator
        ~on_terminal_disposition:(fun disposition -> terminal := Some disposition; Ok ()) () in
    let config = {config with Runtime_agent.execution_store=Some execution_store} in
    Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds
      (fun () -> Runtime_agent.run ~sw ~net:env#net ~config
        ~agent_core_checkpoint:checkpoint input)
  in
  (match resume config "A different operation must not reuse this scope." with
   | Error _ -> () | Ok _ -> Alcotest.fail "changed original input was accepted");
  assert_counts root ~providers:1;
  (match resume {config with name="another-agent"} goal with
   | Error _ -> () | Ok _ -> Alcotest.fail "changed Agent identity was accepted");
  assert_counts root ~providers:1;
  let result = resume config goal |> or_fail in
  Alcotest.(check string) "run continues with the preserved ToolResult"
    "effect receipt preserved" (Agent_core.Types.text_of_content result.response.content);
  assert_counts root ~providers:2;
  (match !terminal with
   | Some {Agent_core.Agent.outcome=Terminal_succeeded; recovery=Retire} -> ()
   | _ -> Alcotest.fail "resumed call did not preserve its terminal disposition");
  (match resume config goal with
   | Error _ -> () | Ok _ -> Alcotest.fail "terminal scope executed again");
  assert_counts root ~providers:2

let () =
  match Array.to_list Sys.argv with
  | [_; "--execution-restart-child"; root] -> child root
  | _ -> Alcotest.run "native execution process restart"
      ["settled ToolResult", [Alcotest.test_case "replay and identity boundaries" `Quick run_restart]]
