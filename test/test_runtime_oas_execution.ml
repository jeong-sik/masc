open Agent_sdk

let () = Mirage_crypto_rng_unix.use_default ()

let fail_sdk error = Alcotest.fail (Error.to_string error)

let get_ok_string = function
  | Ok value -> value
  | Error detail -> Alcotest.fail detail
;;

let make_agent ~net ?context ?checkpoint_sink ~name ~text () =
  let response : Types.api_response =
    { id = "test-response"
    ; model = "test-model"
    ; stop_reason = EndTurn
    ; content = [ Text text ]
    ; usage = None
    ; telemetry = None
    }
  in
  let transport : Llm_provider.Llm_transport.t =
    { complete_sync =
        (fun _request ->
          { Llm_provider.Llm_transport.response = Ok response; latency_ms = Some 0 })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok response)
    }
  in
  let options =
    { Agent.default_options with
      transport = Some transport
    ; provider =
        Some
          { Provider.provider = Provider.Local { base_url = "http://test.invalid/v1" }
          ; model_id = "test-model"
          ; api_key_env = "OAS_TEST_PROVIDER_KEY"
          }
    }
  in
  Agent.create
    ~net
    ~config:{ (Types.default_config ~model:"test-model") with name }
    ?context
    ~options
    ?checkpoint_sink
    ()
;;

let prepared_store prepared =
  match Runtime_oas_execution.execution_store prepared with
  | Some store -> store
  | None -> Alcotest.fail "expected durable OAS execution store"
;;

let slot_count base_path =
  let slots = Filename.concat base_path ".masc/oas-execution/slots" in
  Sys.readdir slots |> Array.length
;;

let run_count base_path =
  let runs = Filename.concat base_path ".masc/oas-execution/runs" in
  Sys.readdir runs |> Array.length
;;

let only_slot_path base_path =
  let slots = Filename.concat base_path ".masc/oas-execution/slots" in
  match Sys.readdir slots |> Array.to_list with
  | [ leaf ] -> Filename.concat slots leaf
  | leaves ->
    Alcotest.failf "expected one recovery slot, found %d" (List.length leaves)
;;

let initialize env sw base_path =
  match
    Runtime_oas_execution.initialize
      ~sw
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~fs:(Eio.Stdenv.fs env)
      ~base_path
      ~domain_count:1
  with
  | Ok () -> ()
  | Error error ->
    Alcotest.fail (Runtime_oas_execution.init_error_to_string error)
;;

let find_free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname socket with
      | Unix.ADDR_INET (_, port) -> port
      | Unix.ADDR_UNIX _ -> Alcotest.fail "expected an INET test socket")
;;

let start_mock_openai_server port =
  match Unix.fork () with
  | 0 ->
    let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Unix.setsockopt socket Unix.SO_REUSEADDR true;
    Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
    Unix.listen socket 4;
    let body =
      {|{"id":"chatcmpl-settlement","object":"chat.completion","model":"test-model","choices":[{"index":0,"message":{"role":"assistant","content":"settled-done"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
    in
    let response =
      Printf.sprintf
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
        (String.length body)
        body
    in
    let buffer = Bytes.create 4096 in
    let rec serve () =
      let client, _ = Unix.accept socket in
      Fun.protect
        ~finally:(fun () -> Unix.close client)
        (fun () ->
          ignore (Unix.read client buffer 0 (Bytes.length buffer));
          ignore (Unix.write_substring client response 0 (String.length response)));
      serve ()
    in
    serve ()
  | pid ->
    Unix.sleepf 0.05;
    pid
;;

let stop_process pid =
  (try Unix.kill pid Sys.sigterm with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
  let rec wait () =
    match Unix.waitpid [] pid with
    | _ -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> ()
  in
  wait ()
;;

let test_runtime_agent_defers_cleanup_until_consumer_settlement () =
  let port = find_free_port () in
  let server_pid = start_mock_openai_server port in
  Fun.protect
    ~finally:(fun () -> stop_process server_pid)
  @@ fun () ->
  Eio_main.run
  @@ fun env ->
  let base_path = Filename.temp_file "masc-oas-consumer-settlement-" ".dir" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  Fun.protect
    ~finally:(fun () ->
      Eio.Path.rmtree
        ~missing_ok:true
        Eio.Path.(Eio.Stdenv.fs env / base_path))
    (fun () ->
      Eio.Switch.run
      @@ fun sw ->
      initialize env sw base_path;
      let consumer_committed = ref false in
      let persisted_terminal = ref None in
      let fail_terminal_persist = ref true in
      let terminal_persist_count = ref 0 in
      let checkpoint_sink (_ : Agent.checkpoint_snapshot) = Ok () in
      let terminal_checkpoint_sink checkpoint =
        if not !consumer_committed
        then Error "terminal checkpoint persisted before consumer commit"
        else (
          incr terminal_persist_count;
          if !fail_terminal_persist
          then Error "injected terminal checkpoint persistence failure"
          else (
            persisted_terminal := Some checkpoint;
            Ok ()))
      in
      let provider_cfg =
        Llm_provider.Provider_config.make
          ~kind:Llm_provider.Provider_config.OpenAI_compat
          ~model_id:"test-model"
          ~base_url:(Printf.sprintf "http://127.0.0.1:%d/v1" port)
          ()
      in
      let config =
        { (Runtime_agent.default_config
             ~name:"consumer-settlement-agent"
             ~provider_cfg
             ~system_prompt:""
             ~tools:[]) with
          session_id = Some "consumer-settlement-session"
        ; checkpoint_sink = Some checkpoint_sink
        ; terminal_checkpoint_sink = Some terminal_checkpoint_sink
        }
      in
      let result =
        match Runtime_agent.run ~sw ~net:(Eio.Stdenv.net env) ~config "finish" with
        | Ok result -> result
        | Error error -> fail_sdk error
      in
      Alcotest.(check string)
        "provider response"
        "settled-done"
        (Types.text_of_response result.response);
      Alcotest.(check int)
        "durable authority retained before consumer settlement"
        1
        (slot_count base_path);
      Alcotest.(check int)
        "terminal sink not called by provider completion"
        0
        !terminal_persist_count;
      let checkpoint =
        match result.checkpoint with
        | Some checkpoint -> checkpoint
        | None -> Alcotest.fail "runtime result omitted its terminal checkpoint"
      in
      Alcotest.(check bool)
        "pre-settlement checkpoint retains recovery authority"
        true
        (Context.keys_in_scope checkpoint.context Context.Session <> []);
      let settlement =
        match result.execution_settlement with
        | Some settlement -> settlement
        | None -> Alcotest.fail "runtime result omitted its settlement handle"
      in
      consumer_committed := true;
      (match Runtime_agent.settle_execution settlement with
       | Error (Agent_sdk.Error.Internal _) -> ()
       | Error error -> fail_sdk error
       | Ok () -> Alcotest.fail "injected terminal persistence failure was ignored");
      Alcotest.(check int)
        "durable authority removed after consumer settlement"
        0
        (slot_count base_path);
      fail_terminal_persist := false;
      (match Runtime_agent.settle_execution settlement with
       | Ok () -> ()
       | Error error -> fail_sdk error);
      let persisted =
        match !persisted_terminal with
        | Some checkpoint -> checkpoint
        | None -> Alcotest.fail "consumer terminal checkpoint was not persisted"
      in
      Alcotest.(check (list string))
        "persisted checkpoint drops private recovery authority"
        []
        (Context.keys_in_scope persisted.context Context.Session);
      (match Runtime_agent.settle_execution settlement with
       | Ok () -> ()
       | Error error -> fail_sdk error);
      Alcotest.(check int)
        "settlement is idempotent"
        2
        !terminal_persist_count)
;;

let test_exact_recovery_record_and_terminal_cleanup () =
  Eio_main.run
  @@ fun env ->
  let base_path = Filename.temp_file "masc-oas-execution-" ".dir" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  Fun.protect
    ~finally:(fun () ->
      Eio.Path.rmtree
        ~missing_ok:true
        Eio.Path.(Eio.Stdenv.fs env / base_path))
    (fun () ->
      let captured_checkpoint = ref None in
      Eio.Switch.run
      (fun sw ->
      initialize env sw base_path;
      let unused_agent =
        make_agent
          ~net:(Eio.Stdenv.net env)
          ~name:"unused-agent"
          ~text:"unused"
          ()
      in
      let runs_before_unused = run_count base_path in
      let unused =
        Runtime_oas_execution.prepare
          ~sw
          ~recovery_key:(Some "test:v1:unused")
          unused_agent
        |> Result.map_error Runtime_oas_execution.prepare_error_to_string
        |> get_ok_string
      in
      (match Runtime_oas_execution.finish unused with
       | Ok () -> ()
       | Error error ->
         Alcotest.fail (Runtime_oas_execution.finish_error_to_string error));
      Alcotest.(check int)
        "unused fresh scope removed"
        runs_before_unused
        (run_count base_path);
      Agent.close unused_agent;
      let checkpoint_sink (snapshot : Agent.checkpoint_snapshot) =
        captured_checkpoint := Some snapshot.checkpoint;
        Ok ()
      in
      let agent =
        make_agent
          ~net:(Eio.Stdenv.net env)
          ~checkpoint_sink
          ~name:"recovery-agent"
          ~text:"first-done"
          ()
      in
      let prepared =
        Runtime_oas_execution.prepare
          ~sw
          ~recovery_key:(Some "test:v1:recoverable")
          agent
        |> Result.map_error Runtime_oas_execution.prepare_error_to_string
        |> get_ok_string
      in
      (match Agent.run ~sw ~execution_store:(prepared_store prepared) agent "hello" with
       | Ok response ->
         Alcotest.(check string) "first response" "first-done" (Types.text_of_response response)
       | Error error -> fail_sdk error);
      Runtime_oas_execution.retain_failure prepared;
      Agent.close agent;
      Alcotest.(check int) "fail-closed slot retained" 1 (slot_count base_path);
      let slot_path = only_slot_path base_path in
      let slot_stat = Unix.stat slot_path in
      Alcotest.(check int)
        "slot permission"
        0o600
        (slot_stat.Unix.st_perm land 0o777);
      let slot_json = Yojson.Safe.from_file slot_path in
      (match slot_json with
       | `Assoc fields ->
         Alcotest.(check (list string))
           "minimal exact slot fields"
           [ "agent_name"; "locator"; "recovery_key"; "schema"; "scope_leaf" ]
           (List.map fst fields |> List.sort String.compare)
       | _ -> Alcotest.fail "recovery slot must be a JSON object"));
      let checkpoint =
        match !captured_checkpoint with
        | Some checkpoint -> checkpoint
        | None -> Alcotest.fail "mutation-boundary checkpoint was not captured"
      in
      Eio.Switch.run
      (fun sw ->
      initialize env sw base_path;
      let resumed_context = Context.copy ~eio:true checkpoint.context in
      let resumed_agent =
        make_agent
          ~net:(Eio.Stdenv.net env)
          ~context:resumed_context
          ~name:"recovery-agent"
          ~text:"unused"
          ()
      in
      let resumed =
        Runtime_oas_execution.prepare
          ~sw
          ~recovery_key:(Some "test:v1:recoverable")
          resumed_agent
        |> Result.map_error Runtime_oas_execution.prepare_error_to_string
        |> get_ok_string
      in
      ignore (prepared_store resumed);
      (match Runtime_oas_execution.finish resumed with
       | Ok () -> ()
       | Error error ->
         Alcotest.fail (Runtime_oas_execution.finish_error_to_string error));
      Alcotest.(check int)
        "unopened resumed scope remains recoverable"
        1
        (slot_count base_path);
      Agent.close resumed_agent;
      let missing_context = Context.create () in
      let mismatched_agent =
        make_agent
          ~net:(Eio.Stdenv.net env)
          ~context:missing_context
          ~name:"recovery-agent"
          ~text:"unused"
          ()
      in
      (match
         Runtime_oas_execution.prepare
           ~sw
           ~recovery_key:(Some "test:v1:recoverable")
           mismatched_agent
       with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail "slot without matching checkpoint must fail closed");
      Agent.close mismatched_agent;
      let terminal_context = Context.create () in
      let terminal_agent =
        make_agent
          ~net:(Eio.Stdenv.net env)
          ~context:terminal_context
          ~name:"terminal-agent"
          ~text:"terminal-done"
          ()
      in
      let terminal =
        Runtime_oas_execution.prepare
          ~sw
          ~recovery_key:(Some "test:v1:terminal")
          terminal_agent
        |> Result.map_error Runtime_oas_execution.prepare_error_to_string
        |> get_ok_string
      in
      (match
         Agent.run
           ~sw
           ~execution_store:(prepared_store terminal)
           terminal_agent
           "finish"
       with
       | Ok response ->
         Alcotest.(check string)
           "terminal response"
           "terminal-done"
           (Types.text_of_response response)
       | Error error -> fail_sdk error);
      (match Runtime_oas_execution.finish terminal with
       | Ok () -> ()
       | Error error ->
         Alcotest.fail (Runtime_oas_execution.finish_error_to_string error));
      Alcotest.(check (list string))
        "terminal recovery context cleared"
        []
        (Context.keys_in_scope terminal_context Context.Session);
      Alcotest.(check int)
        "terminal slot removed without pruning unrelated recovery"
        1
        (slot_count base_path);
      Agent.close terminal_agent;
      let cleanup_failure_context = Context.create () in
      let cleanup_failure_agent =
        make_agent
          ~net:(Eio.Stdenv.net env)
          ~context:cleanup_failure_context
          ~name:"cleanup-failure-agent"
          ~text:"cleanup-failure-done"
          ()
      in
      let cleanup_failure =
        Runtime_oas_execution.prepare
          ~sw
          ~recovery_key:(Some "test:v1:cleanup-failure")
          cleanup_failure_agent
        |> Result.map_error Runtime_oas_execution.prepare_error_to_string
        |> get_ok_string
      in
      (match
         Agent.run
           ~sw
           ~execution_store:(prepared_store cleanup_failure)
           cleanup_failure_agent
           "finish"
       with
       | Ok _ -> ()
       | Error error -> fail_sdk error);
      let recovery_entries =
        Context.keys_in_scope cleanup_failure_context Context.Session
        |> List.filter_map (fun key ->
          Context.get_scoped cleanup_failure_context Context.Session key
          |> Option.map (fun json -> key, json))
      in
      recovery_entries
      |> List.iter (fun (key, _) ->
        Context.delete_scoped cleanup_failure_context Context.Session key);
      (match Runtime_oas_execution.finish cleanup_failure with
       | Error _ -> ()
       | Ok () -> Alcotest.fail "missing recovery context must fail cleanup");
      recovery_entries
      |> List.iter (fun (key, json) ->
        Context.set_scoped cleanup_failure_context Context.Session key json);
      let cleanup_retry =
        Runtime_oas_execution.prepare
          ~sw
          ~recovery_key:(Some "test:v1:cleanup-failure")
          cleanup_failure_agent
        |> Result.map_error Runtime_oas_execution.prepare_error_to_string
        |> get_ok_string
      in
      ignore (prepared_store cleanup_retry);
      Runtime_oas_execution.retain_failure cleanup_retry;
      Agent.close cleanup_failure_agent))
;;

let () =
  Alcotest.run
    "runtime_oas_execution"
    [ ( "recovery"
      , [ Alcotest.test_case
            "runtime consumer settlement defers cleanup"
            `Quick
            test_runtime_agent_defers_cleanup_until_consumer_settlement
        ; Alcotest.test_case
            "exact record and terminal cleanup"
            `Quick
            test_exact_recovery_record_and_terminal_cleanup
        ] )
    ]
;;
