open Agent_core
open Alcotest
module Internal = Agent_core__
module Runtime = Internal.Execution_runtime
module Codec = Internal.Execution_codec_executor
module Writer = Internal.Execution_lane_writer
module Scope = Internal.Execution_agent_scope
module Context = Internal.Execution_context
module Event = Internal.Execution_event
module Binding = Binding_identity
module Projection = Agent.Execution_projection

let value = function
  | Ok value -> value
  | Error detail -> fail detail
;;

let scope_value = function
  | Ok value -> value
  | Error error -> fail (Scope.error_to_string error)
;;

let writer_value = function
  | Ok value -> value
  | Error error -> fail (Writer.scope_failure_to_string error)
;;

let projection_value = function
  | Ok value -> value
  | Error error -> fail (Projection.error_to_string error)
;;

let binding () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~model_id:"projection-test"
    ~base_url:"http://projection.invalid"
    ~api_key:""
    ~request_path:"/v1/chat/completions"
    ()
  |> Binding.of_provider_config ~transport:Binding.Injected
  |> value
;;

let child_response : Types.api_response =
  { id = "projection-child-response"
  ; model = "projection-child-model"
  ; stop_reason = Types.EndTurn
  ; content = [ Llm_provider.Types.Text "child-finished" ]
  ; usage = None
  ; telemetry = None
  }
;;

let child_transport : Llm_provider.Llm_transport.t =
  Llm_provider.Llm_transport.custom ({ complete_sync =
      (fun _request ->
        { Llm_provider.Llm_transport.response = Ok child_response; latency_ms = Some 0 })
  ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok child_response)
  })
;;

let child_agent ~net =
  let options =
    { Agent.default_options with
      transport = Some child_transport
    ; provider_config =
        Some
          (Llm_provider.Provider_config.make
             ~kind:Llm_provider.Provider_config.OpenAI_compat
             ~provider_id:"test"
             ~base_url:"http://projection.invalid"
             ~model_id:"projection-child-model"
             ~api_key:""
             ~headers:[ "Content-Type", "application/json" ]
             ~request_path:"/v1/chat/completions"
             ())
    }
  in
  Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
    ~net
    ~config:
      { (Types.default_config ~model:"projection-child-model") with name = "child-agent" }
    ~options
    ()
;;

let invocation () =
  let schedule : Tool_contract.schedule =
    { planned_index = 0
    ; batch_index = 0
    ; batch_size = 1
    ; execution_mode = Tool_contract.Serial
    }
  in
  Tool_contract.Invocation.create
    ~tool_use_id:"projection-tool-use"
    ~turn:1
    ~schedule
    ~completion:Tool_contract.Continue_after_success
;;

let public_locator scope =
  Scope.scope_locator scope
  |> Scope.scope_locator_to_yojson
  |> Agent.execution_locator_of_yojson
  |> value
;;

let make_dir fs prefix =
  let native_path = Filename.temp_file prefix ".dir" in
  Sys.remove native_path;
  let dir = Eio.Path.(fs / native_path) in
  Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
  dir
;;

let node_kinds page =
  List.filter_map
    (fun (event : Projection.event) ->
       match event.payload with
       | Projection.Node_opened node -> Some node
       | Projection.Node_updated _ | Projection.Node_closed _ -> None)
    page.Projection.events
;;

let test_live_and_restart_projection () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun runtime_sw ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let runtime =
    Agent.create_execution_runtime ~sw:runtime_sw ~domain_mgr ~domain_count:1
    |> Result.map_error Error.to_string
    |> value
  in
  let internal_runtime =
    Runtime.create ~sw:runtime_sw ~domain_mgr ~domain_count:1
    |> Result.map_error Runtime.create_error_to_string
    |> value
  in
  let codec = Codec.of_runtime internal_runtime in
  let fs = Eio.Stdenv.fs env in
  let dir = make_dir fs "agent_core-projection-live-" in
  let other_dir = make_dir fs "agent_core-projection-other-" in
  Fun.protect
    ~finally:(fun () ->
      Eio.Path.rmtree ~missing_ok:true dir;
      Eio.Path.rmtree ~missing_ok:true other_dir)
    (fun () ->
       let projection_ref = ref None in
       let locator_ref = ref None in
       writer_value
         (Writer.run ~codec ~dir (fun ~sw writer ->
            let root = scope_value (Scope.start ~writer ~agent_name:"root-agent") in
            let locator = public_locator root in
            locator_ref := Some locator;
            let projection =
              projection_value (Agent.open_execution_projection ~runtime ~dir locator)
            in
            projection_ref := Some projection;
            check bool "running root has no terminal receipt" true
              (Option.is_none (projection_value (Agent.read_execution_terminal projection)));
            let first =
              projection_value
                (Projection.read_page
                   projection
                   ~after:(Projection.beginning_cursor projection)
                   ~limit:1
                   ())
            in
            check int "first page has root open" 1 (List.length first.events);
            check
              int
              "first high watermark"
              1
              (Projection.cursor_seq first.high_watermark);
            let turn = scope_value (Scope.open_turn root ~ordinal:1) in
            let live =
              projection_value
                (Projection.read_page projection ~after:first.next_cursor ~limit:8 ())
            in
            check int "live page observes committed turn" 1 (List.length live.events);
            check
              int
              "live high watermark advanced"
              2
              (Projection.cursor_seq live.high_watermark);
            let frozen =
              projection_value
                (Projection.read_page
                   projection
                   ~after:first.next_cursor
                   ~through:first.high_watermark
                   ~limit:8
                   ())
            in
            check int "frozen page excludes later commit" 0 (List.length frozen.events);
            let provider =
              scope_value (Scope.open_provider_attempt turn ~ordinal:0 (binding ()))
            in
            let durable =
              scope_value
                (Scope.open_invocation
                   provider
                   ~invocation:(invocation ())
                   ~tool_name:"recursive-tool"
                   ~input:(`Assoc []))
            in
            (match
               Scope.execute durable ~invoke:(fun ~start_child ~tool_name:_ ~input:_ ->
                 Context.with_child_scope_factory start_child (fun () ->
                   match
                     Agent.run
                       ~sw
                       (child_agent ~net:(Eio.Stdenv.net env))
                       "run as recursive Agent tool"
                   with
                   | Ok _ -> "child-finished", Types.Tool_succeeded
                   | Error error -> fail (Error.to_string error)))
             with
             | Ok (Scope.Executed _) -> ()
             | Ok (Scope.Replayed _) ->
               fail "fresh recursive effect unexpectedly replayed"
             | Error error -> fail (Scope.error_to_string error));
            scope_value (Scope.close_provider_attempt provider Event.Succeeded);
            scope_value (Scope.close_turn turn Event.Succeeded);
            scope_value (Scope.finish root Event.Succeeded)));
       let projection = Option.get !projection_ref in
       let locator = Option.get !locator_ref in
       let terminal = projection_value (Agent.read_execution_terminal projection)
         |> Option.get in
       check bool "recursive tool attempt is recorded" true terminal.has_tool_attempts;
       check int "only the enclosing root ToolResult is returned" 1
         (List.length terminal.settled_tool_results);
       (match terminal.disposition with
        | {Agent.outcome=Terminal_succeeded; recovery=Retire} -> ()
        | _ -> fail "settled recursive call must retain its canonical disposition");
       let through = projection_value (Projection.current_cursor projection) in
       check bool "final cursor advanced" true (Projection.cursor_seq through > 2);
       Eio.Fiber.all
         (List.init 16 (fun _ () ->
            let observed = projection_value (Projection.current_cursor projection) in
            check
              int
              "concurrent refresh observes one authority"
              (Projection.cursor_seq through)
              (Projection.cursor_seq observed)));
       let all =
         projection_value
           (Projection.read_page
              projection
              ~after:(Projection.beginning_cursor projection)
              ~through
              ~limit:128
              ())
       in
       let requests = projection_value (Projection.provider_requests projection ()) in
       check int "root request query excludes nested Agent request snapshots" 1 (List.length requests);
       (match requests with
        | [{Projection.provenance=None;_}] -> ()
        | [] | _::_ -> fail "root query borrowed a nested Agent request receipt");
       let nodes = node_kinds all in
       let agent_runs =
         List.filter_map
           (fun (node : Projection.node) ->
              match node.kind with
              | Projection.Agent_run { agent_name } ->
                Some (agent_name, Option.is_some node.parent_node_id)
              | Projection.Agent_turn _
              | Projection.Provider_attempt _
              | Projection.Output_block _
              | Projection.Tool_invocation _
              | Projection.Tool_attempt -> None)
           nodes
       in
       check
         (list (pair string bool))
         "recursive run hierarchy is lossless"
         [ "root-agent", false; "child-agent", true ]
         agent_runs;
       let child_node =
         List.find
           (fun (node : Projection.node) ->
              match node.kind with
              | Projection.Agent_run { agent_name } ->
                String.equal agent_name "child-agent"
              | Projection.Agent_turn _
              | Projection.Provider_attempt _
              | Projection.Output_block _
              | Projection.Tool_invocation _
              | Projection.Tool_attempt -> false)
           nodes
       in
       let parent_node_id = Option.get child_node.parent_node_id in
       let parent_node =
         List.find
           (fun (node : Projection.node) ->
              Projection.Node_id.equal node.node_id parent_node_id)
           nodes
       in
       (match parent_node.kind with
        | Projection.Tool_attempt -> ()
        | Projection.Agent_run _
        | Projection.Agent_turn _
        | Projection.Provider_attempt _
        | Projection.Output_block _
        | Projection.Tool_invocation _ ->
          fail "recursive public Agent.run was not parented by Tool_attempt");
       check
         bool
         "recursive public Agent.run settled"
         true
         (List.exists
            (fun (event : Projection.event) ->
               match event.payload with
               | Projection.Node_closed { node_id; terminal = Projection.Succeeded } ->
                 Projection.Node_id.equal node_id child_node.node_id
               | Projection.Node_opened _
               | Projection.Node_updated _
               | Projection.Node_closed _ -> false)
            all.events);
       check
         int
         "one exact tool attempt"
         1
         (List.length
            (List.filter
               (fun (node : Projection.node) ->
                  match node.kind with
                  | Projection.Tool_attempt -> true
                  | Projection.Agent_run _
                  | Projection.Agent_turn _
                  | Projection.Provider_attempt _
                  | Projection.Output_block _
                  | Projection.Tool_invocation _ -> false)
               nodes));
       let reopened =
         let wal = Eio.Path.(dir / "events.v1.wal") in
         Eio.Path.with_open_out ~append:true ~create:`Never wal (fun file ->
           Eio.Flow.copy_string "non-authoritative-tail" file;
           Eio.File.sync file);
         let wal_size_with_tail = String.length (Eio.Path.load wal) in
         let reopened =
           projection_value (Agent.open_execution_projection ~runtime ~dir locator)
         in
         check
           int
           "read-only open does not repair or truncate tail"
           wal_size_with_tail
           (String.length (Eio.Path.load wal));
         reopened
       in
       let reopened_through = projection_value (Projection.current_cursor reopened) in
       check
         int
         "restart catch-up reaches same authority"
         (Projection.cursor_seq through)
         (Projection.cursor_seq reopened_through);
       (match
          Projection.read_page
            reopened
            ~after:(Projection.beginning_cursor reopened)
            ~limit:0
            ()
        with
        | Error (Projection.Invalid_limit 0) -> ()
        | Ok _ | Error _ -> fail "non-positive transport limit was not typed");
       writer_value
         (Writer.run ~codec ~dir:other_dir (fun ~sw:_ writer ->
            let other = scope_value (Scope.start ~writer ~agent_name:"other-agent") in
            scope_value (Scope.finish other Event.Succeeded)));
       match Agent.open_execution_projection ~runtime ~dir:other_dir locator with
       | Error (Projection.Locator_not_found _) -> ()
       | Ok _ | Error _ -> fail "locator from another directory was not rejected")
;;

let test_settled_invocation_projection () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let runtime = Agent.create_execution_runtime ~sw ~domain_mgr:env#domain_mgr
      ~domain_count:1 |> Result.map_error Error.to_string |> value in
  let internal_runtime = Runtime.create ~sw ~domain_mgr:env#domain_mgr ~domain_count:1
      |> Result.map_error Runtime.create_error_to_string |> value in
  let codec = Codec.of_runtime internal_runtime in
  let dir = make_dir env#fs "agent_core-settled-projection-" in
  Eio.Switch.on_release sw (fun () -> Eio.Path.rmtree ~missing_ok:true dir);
  let open_call scope ordinal name =
    let turn = scope_value (Scope.open_turn scope ~ordinal) in
    let provider = scope_value (Scope.open_provider_attempt turn ~ordinal:0 (binding ())) in
    let invocation = Tool_contract.Invocation.create
        ~tool_use_id:"reused-provider-id" ~turn:ordinal
        ~schedule:{Tool_contract.planned_index=0; batch_index=0; batch_size=1;
                   execution_mode=Tool_contract.Serial}
        ~completion:Tool_contract.Continue_after_success in
    let call = scope_value (Scope.open_invocation provider ~invocation ~tool_name:name
        ~input:(`Assoc ["occurrence", `Int ordinal])) in
    turn, provider, call in
  let close_call turn provider =
    scope_value (Scope.close_provider_attempt provider Event.Succeeded);
    scope_value (Scope.close_turn turn Event.Succeeded) in
  let locator = writer_value (Writer.run ~codec ~dir (fun ~sw:_ writer ->
    let root = scope_value (Scope.start ~writer ~agent_name:"settled-root") in
    let locator = public_locator root in
    let projection = projection_value (Agent.open_execution_projection ~runtime ~dir locator) in
    let turn, provider, call = open_call root 1 "parent-tool" in
    ignore (scope_value (Scope.execute call ~invoke:(fun ~start_child ~tool_name:_ ~input:_ ->
      let child = scope_value (start_child ~agent_name:"nested-tool-agent") in
      let child_turn, child_provider, child_call = open_call child 1 "nested-tool" in
      ignore (scope_value (Scope.execute child_call ~invoke:(fun ~start_child:_ ~tool_name:_ ~input:_ ->
        "nested result", Types.Tool_succeeded)));
      close_call child_turn child_provider;
      scope_value (Scope.finish child Event.Succeeded);
      "parent result", Types.Tool_succeeded)));
    close_call turn provider;
    let turn, provider, blocked = open_call root 2 "blocked-tool" in
    scope_value (Scope.settle_unattempted_invocation blocked ~content:"prehook denied"
      ~outcome:(Types.Tool_failed {failure_kind=Non_retryable_tool_error;
                                  error_class=Some Deterministic}));
    close_call turn provider;
    let turn, provider, invalid = open_call root 3 "invalid-tool" in
    ignore (scope_value (Scope.execute invalid ~invoke:(fun ~start_child:_ ~tool_name:_ ~input:_ ->
      "schema rejected", Types.Tool_failed {failure_kind=Validation_error;
                                            error_class=Some Deterministic})));
    close_call turn provider;
    let records = projection_value (Projection.settled_tool_invocations projection) in
    check (list string) "root results exclude recursive children"
      ["parent-tool"; "blocked-tool"; "invalid-tool"]
      (List.map (fun (record : Projection.settled_tool_invocation) -> record.tool_name) records);
    check (list bool) "attempt evidence distinguishes prehook from validation"
      [true; false; true]
      (List.map (fun (record : Projection.settled_tool_invocation) -> record.attempt_admitted) records);
    check (list int) "reused IDs keep separate turn occurrences" [1; 2; 3]
      (List.map (fun (record : Projection.settled_tool_invocation) ->
        Tool_contract.Invocation.turn record.invocation) records);
    List.iter (fun (record : Projection.settled_tool_invocation) ->
      let ordinal = Tool_contract.Invocation.turn record.invocation in
      check bool "exact canonical input" true
        (record.input = `Assoc ["occurrence", `Int ordinal])) records;
    (match records with
     | [first; second; third] -> check bool "canonical settlement order" true
         (first.settlement_seq < second.settlement_seq && second.settlement_seq < third.settlement_seq)
     | [] | _ :: _ -> fail "expected three settled root occurrences");
    (* Unsettled admission never becomes an executed observation. *)
    let (_turn, _provider, _pending) = open_call root 4 "unsettled-tool" in
    check int "unsettled result is absent" 3
      (List.length (projection_value (Projection.settled_tool_invocations projection)));
    scope_value (Scope.abort root (Scope.Cancelled
      {reason=Some "fixture closes the unsettled invocation before read-only reopen";
       data=None}));
    locator)) in
  let reopened = projection_value (Agent.open_execution_projection ~runtime ~dir locator) in
  check int "restart projection retains the same settled occurrences" 3
    (List.length (projection_value (Projection.settled_tool_invocations reopened)))
;;

let test_cursor_codec_is_closed_and_versioned () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let runtime =
    Agent.create_execution_runtime
      ~sw
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~domain_count:1
    |> Result.map_error Error.to_string
    |> value
  in
  let dir = make_dir (Eio.Stdenv.fs env) "agent_core-projection-cursor-" in
  Fun.protect
    ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir)
    (fun () ->
       let codec_runtime =
         Runtime.create ~sw ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~domain_count:1
         |> Result.map_error Runtime.create_error_to_string
         |> value
       in
       let codec = Codec.of_runtime codec_runtime in
       let locator =
         writer_value
           (Writer.run ~codec ~dir (fun ~sw:_ writer ->
              let scope = scope_value (Scope.start ~writer ~agent_name:"cursor-agent") in
              let locator = public_locator scope in
              scope_value (Scope.finish scope Event.Succeeded);
              locator))
       in
       let projection =
         projection_value (Agent.open_execution_projection ~runtime ~dir locator)
       in
       let cursor = Projection.beginning_cursor projection in
       let fields =
         match Projection.cursor_to_yojson cursor with
         | `Assoc fields -> fields
         | _ -> fail "cursor encoder did not emit object"
       in
       let decode json = Projection.cursor_of_yojson (`Assoc json) in
       (match decode (("unknown", `Null) :: fields) with
        | Error (Projection.Unexpected_cursor_field "unknown") -> ()
        | Ok _ | Error _ -> fail "unknown cursor field was not typed");
       (match decode (("version", `Int 1) :: fields) with
        | Error (Projection.Duplicate_cursor_field Projection.Version) -> ()
        | Ok _ | Error _ -> fail "duplicate cursor field was not typed");
       (match decode (List.remove_assoc "sequence" fields) with
        | Error (Projection.Missing_cursor_field Projection.Sequence) -> ()
        | Ok _ | Error _ -> fail "missing cursor field was not typed");
       let future =
         List.map
           (function
             | "version", _ -> "version", `Int 2
             | field -> field)
           fields
       in
       (match decode future with
        | Error (Projection.Unsupported_cursor_version { expected = 1; actual = 2 }) -> ()
        | Ok _ | Error _ -> fail "future cursor version was not typed");
       let external_source = Projection.External_source.of_string "discord" |> value in
       check
         string
         "external cause source has a stable round-trip form"
         "discord"
         (Projection.External_source.to_string external_source);
       let current = projection_value (Projection.current_cursor projection) in
       let current_seq = Projection.cursor_seq current in
       let ahead_seq = current_seq + 1 in
       let ahead_fields =
         List.map
           (function
             | "sequence", _ -> "sequence", `Int ahead_seq
             | field -> field)
           fields
       in
       let ahead =
         match decode ahead_fields with
         | Ok cursor -> cursor
         | Error error -> fail (Projection.cursor_decode_error_to_string error)
       in
       (match
          Projection.read_page projection ~after:cursor ~through:ahead ~limit:1 ()
        with
        | Error
            (Projection.Cursor_ahead
               { cursor_role = Projection.Through; cursor_seq; high_watermark }) ->
          check int "through cursor is identified" ahead_seq cursor_seq;
          check int "through authority is exact" current_seq high_watermark
        | Ok _ | Error _ -> fail "ahead through cursor role was not typed");
       match
         Projection.read_page projection ~after:ahead ~through:current ~limit:1 ()
       with
       | Error
           (Projection.Cursor_ahead
              { cursor_role = Projection.After; cursor_seq; high_watermark }) ->
         check int "after cursor is identified" ahead_seq cursor_seq;
         check int "after authority is exact" current_seq high_watermark
       | Ok _ | Error _ -> fail "ahead after cursor role was not typed")
;;

let test_terminal_callback_failure_readback () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let runtime = Agent.create_execution_runtime ~sw
      ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~domain_count:1
    |> Result.map_error Error.to_string |> value in
  let dir = make_dir (Eio.Stdenv.fs env) "agent_core-terminal-callback-" in
  Fun.protect ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir) (fun () ->
    let locator = ref None in
    let agent = child_agent ~net:(Eio.Stdenv.net env) in
    let store = Agent.execution_store ~runtime ~dir
        ~on_scope_ready:(fun value -> locator := Some value; Ok ())
        ~on_terminal_disposition:(fun _ -> Error "host receipt sink unavailable") () in
    (match Agent.run ~sw ~execution_store:store agent "complete once" with
     | Error (Error.Internal _) -> ()
     | Error error -> fail (Error.to_string error)
     | Ok _ -> fail "host terminal sink failure must fail the public call");
    let committed_before = Eio.Path.load Eio.Path.(dir / "events.v1.commit") in
    let projection = projection_value
      (Agent.open_execution_projection ~runtime ~dir (Option.get !locator)) in
    let terminal = projection_value (Agent.read_execution_terminal projection) |> Option.get in
    (match terminal.disposition with
     | {Agent.outcome=Terminal_succeeded; recovery=Retire} -> ()
     | _ -> fail "readback must preserve success committed before host sink failure");
    check bool "provider-only call admits no tool attempt" false terminal.has_tool_attempts;
    check int "provider-only call has no invented ToolResult" 0
      (List.length terminal.settled_tool_results);
    check string "terminal readback never advances durable authority" committed_before
      (Eio.Path.load Eio.Path.(dir / "events.v1.commit")))
;;

let test_terminal_unknown_effect_readback () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let runtime = Agent.create_execution_runtime ~sw ~domain_mgr ~domain_count:1
    |> Result.map_error Error.to_string |> value in
  let internal_runtime = Runtime.create ~sw ~domain_mgr ~domain_count:1
    |> Result.map_error Runtime.create_error_to_string |> value in
  let codec = Codec.of_runtime internal_runtime in
  let dir = make_dir (Eio.Stdenv.fs env) "agent_core-terminal-unknown-" in
  Fun.protect ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir) (fun () ->
    let locator = writer_value (Writer.run ~codec ~dir (fun ~sw:_ writer ->
      let scope = scope_value (Scope.start ~writer ~agent_name:"unknown-effect") in
      let turn = scope_value (Scope.open_turn scope ~ordinal:1) in
      let provider = scope_value (Scope.open_provider_attempt turn ~ordinal:0 (binding ())) in
      let tool = scope_value (Scope.open_invocation provider ~invocation:(invocation ())
        ~tool_name:"uncertain-write" ~input:(`Assoc [])) in
      (match Scope.execute tool ~invoke:(fun ~start_child:_ ~tool_name:_ ~input:_ -> raise Exit) with
       | exception Exit -> ()
       | Ok _ -> fail "unknown effect fixture unexpectedly settled"
       | Error error -> fail (Scope.error_to_string error));
      scope_value (Scope.abort scope (Scope.Failed
        {Event.kind=Internal_failure; detail="interrupted after admission"; data=None}));
      (match scope_value (Scope.terminal_recovery_action scope) with
       | Scope.Operator_repair_required Effect_outcome_unknown -> ()
       | Scope.Retire -> fail "writer must report the admitted unknown effect");
      public_locator scope)) in
    let projection = projection_value (Agent.open_execution_projection ~runtime ~dir locator) in
    let terminal = projection_value (Agent.read_execution_terminal projection) |> Option.get in
    (match terminal.disposition with
     | {Agent.outcome=Terminal_failed;
        recovery=Operator_repair_required Effect_outcome_unknown} -> ()
     | _ -> fail "read-only terminal evidence must agree with writer recovery");
    check bool "unknown effect keeps tool admission" true terminal.has_tool_attempts;
    check int "unknown effect does not synthesize a settled result" 0
      (List.length terminal.settled_tool_results))
;;

let test_native_request_provenance_reopen () =
  List.iter (fun stream -> List.iter (fun succeeds ->
    Eio_main.run @@ fun env ->
    try Eio.Switch.run @@ fun sw ->
      let net = Eio.Stdenv.net env in
      let captured = ref None in
      let response =
        {|{"id":"receipt-response","type":"message","role":"assistant","model":"receipt-model","content":[{"type":"text","text":"answer"}],"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":1}}|} in
      let response = if stream && succeeds then
        String.concat "\n\n"
          [ "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"receipt-response\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"receipt-model\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":2,\"output_tokens\":0}}}"
          ; "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"
          ; "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"answer\"}}"
          ; "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}"
          ; "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}"
          ; "event: message_stop\ndata: {\"type\":\"message_stop\"}"
          ; ""; "" ]
        else response in
      let socket = Eio.Net.listen net ~sw ~backlog:4 ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
      let port = match Eio.Net.listening_addr socket with
        | `Tcp (_, port) -> port | `Unix _ -> fail "expected loopback TCP peer" in
      let server = Cohttp_eio.Server.make ~callback:(fun _ _ body ->
        captured := Some Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all);
        let headers = Cohttp.Header.init_with "content-type"
          (if stream && succeeds then "text/event-stream" else "application/json") in
        Cohttp_eio.Server.respond_string ~headers
          ~status:(if succeeds then `OK else `Bad_request) ~body:response ()) () in
      Eio.Fiber.fork_daemon ~sw (fun () ->
        Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
      let runtime = Agent.create_execution_runtime ~sw
        ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~domain_count:1
        |> Result.map_error Error.to_string |> value in
      let dir = make_dir (Eio.Stdenv.fs env) "agent_core-request-reopen-" in
      Fun.protect ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir) (fun () ->
        let locator = ref None in
        let store = Agent.execution_store ~runtime ~dir
          ~on_scope_ready:(fun exact -> locator := Some exact; Ok ()) () in
        let config = Llm_provider.Provider_config.make
          ~kind:Llm_provider.Provider_config.Anthropic ~model_id:"receipt-model"
          ~base_url:(Printf.sprintf "http://127.0.0.1:%d" port)
          ~request_path:"/v1/messages" ~max_tokens:200
          ~model_capabilities_override:
            { Llm_provider.Capabilities.anthropic_capabilities with max_output_tokens = Some 100 } () in
        let options = { Agent.default_options with provider_config=Some config } in
        let agent = Agent.create ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~options
          ~config:{(Types.default_config ~model:"receipt-model") with
            name="receipt-agent"; max_tokens=Some 200}
          ~pre_dispatch_serialization_observer:(fun _ ->
            Error {Llm_provider.Request_wire_observer.reason="observer unavailable"}) () in
        let result = if stream then Agent.run_stream ~sw ~execution_store:store
          ~on_event:(fun _ -> ()) agent "answer once"
        else Agent.run ~sw ~execution_store:store agent "answer once" in
        (match succeeds, result with
         | true, Ok _ | false, Error _ -> ()
         | true, Error error -> fail (Error.to_string error)
         | false, Ok _ -> fail "provider failure became success");
        let locator = match !locator with Some value -> value
          | None -> fail "run has no durable scope locator" in
        let read () =
          let projection = projection_value (Agent.open_execution_projection ~runtime ~dir locator) in
          projection_value (Projection.read_page projection
            ~after:(Projection.beginning_cursor projection) ~limit:128 ()) in
        let snapshot page = List.filter_map (fun (event : Projection.event) ->
          match event.payload with
          | Projection.Node_updated {node_id;update=Projection.Provider_request_snapshot fact} ->
            Some (node_id, fact)
          | Projection.Node_opened _ | Projection.Node_updated _ | Projection.Node_closed _ -> None)
          page.Projection.events in
        let first = read () in
        let projection = projection_value (Agent.open_execution_projection ~runtime ~dir locator) in
        let baseline = projection_value (Projection.current_cursor projection) in
        let old = projection_value (Projection.provider_requests projection ()) in
        check int "root request query sees its provider attempt" 1 (List.length old);
        check int "unchanged same-call boundary excludes historical receipts" 0
          (List.length (projection_value (Projection.provider_requests projection ~after:baseline ())));
        let first_node, fact = match snapshot first with
          | [entry] -> entry | _ -> fail "each provider attempt must own one returned request fact" in
        check bool "receipt belongs to its provider attempt" true
          (List.exists (fun (node : Projection.node) ->
            Projection.Node_id.equal node.node_id first_node &&
            match node.kind with
            | Projection.Provider_attempt _ -> true
            | Projection.Agent_run _ | Projection.Agent_turn _ | Projection.Output_block _
            | Projection.Tool_invocation _ | Projection.Tool_attempt -> false) (node_kinds first));
        (match fact with
         | Llm_provider.Completion_outcome.Serialized request ->
           let body = match !captured with Some body -> body
             | None -> fail "provider never received the body" in
           check int "persisted body length" (String.length body) request.body_bytes;
           check string "persisted body SHA256"
             Agent_core_sha256.(digest_string body |> to_hex) request.body_sha256;
           check (option int) "persisted requested value" (Some 200)
             (Llm_provider.Types.output_token_receipt_requested request.output_token_receipt);
           check (option int) "persisted wire value"
             (Some Yojson.Safe.Util.(Yojson.Safe.from_string body |> member "max_tokens" |> to_int))
             (Llm_provider.Types.output_token_receipt_effective request.output_token_receipt)
         | Llm_provider.Completion_outcome.Not_serialized
         | Llm_provider.Completion_outcome.Cache_reused _
         | Llm_provider.Completion_outcome.External_unobserved
         | Llm_provider.Completion_outcome.Interrupted_unobserved ->
           fail "native serialized evidence was lost before durable projection");
        let reopened = read () in
        match snapshot reopened with
        | [(node, restored)] ->
          check bool "reopen retains owning attempt" true (Projection.Node_id.equal first_node node);
          check bool "reopen retains exact request fact" true
            (Llm_provider.Completion_outcome.equal_request_provenance fact restored)
        | _ -> fail "durable reopen lost or duplicated request provenance");
      Eio.Switch.fail sw Exit
    with Exit -> ()) [true; false]) [false; true]
;;

let test_checkpoint_fact_ownership_and_reopen () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let runtime=Agent.create_execution_runtime ~sw ~domain_mgr:env#domain_mgr ~domain_count:1
      |> Result.map_error Error.to_string |> value in
  let internal_runtime=Runtime.create ~sw ~domain_mgr:env#domain_mgr ~domain_count:1
      |> Result.map_error Runtime.create_error_to_string |> value in
  let dir=make_dir env#fs "agent_core-checkpoint-facts-" in
  Eio.Switch.on_release sw (fun () -> Eio.Path.rmtree ~missing_ok:true dir);
  let template=Agent.checkpoint (child_agent ~net:env#net) in
  let make name stage=Checkpoint_snapshot.create ~stage {template with agent_name=name}
      |> Result.map_error Checkpoint_snapshot.error_to_string |> value in
  let fact=make "checkpoint-root" Checkpoint_snapshot.After_assistant_collected in
  Agent_core.Context.set template.context "producer-mutation" (`Bool true);
  let frozen=Checkpoint_snapshot.checkpoint fact
      |> Result.map_error Checkpoint_snapshot.error_to_string |> value in
  check bool "producer context mutation cannot alter a frozen checkpoint" true
    (Agent_core.Context.get frozen.context "producer-mutation"=None);
  let json=Checkpoint_snapshot.to_yojson fact in
  let checkpoint_json=Checkpoint.to_json {template with agent_name="checkpoint-root"} in
  let invalids=[
    `Assoc ["stage",`String "unknown";"checkpoint",checkpoint_json];
    `Assoc ["stage",`String "after_assistant_collected";"stage",`String "after_assistant_collected";
            "checkpoint",checkpoint_json];
    `Assoc ["stage",`String "after_assistant_collected";"checkpoint",checkpoint_json;"extra",`Null];
    `Assoc ["stage",`String "after_assistant_collected"];
    `Assoc ["stage",`String "after_assistant_collected";"checkpoint",
      (match checkpoint_json with `Assoc fields -> `Assoc (("agent_name",`String "duplicate")::fields)
       | _ -> fail "checkpoint encoder did not emit an object")]] in
  List.iter (fun json -> check bool "malformed checkpoint fact is rejected" true
      (match Checkpoint_snapshot.of_yojson json with Error _->true |Ok _->false)) invalids;
  check bool "checkpoint fact strictly roundtrips" true
    (match Checkpoint_snapshot.of_yojson json with Ok restored->Checkpoint_snapshot.equal restored fact
     | Error _->false);
  let locator=writer_value (Writer.run ~codec:(Codec.of_runtime internal_runtime) ~dir (fun ~sw:_ writer ->
    let root=scope_value (Scope.start ~writer ~agent_name:"checkpoint-root") in
    let locator=public_locator root in
    let projection=projection_value (Agent.open_execution_projection ~runtime ~dir locator) in
    let before=projection_value (Projection.current_cursor projection) in
    check bool "checkpoint cannot cross Agent identity" true
      (match Scope.record_checkpoint root (make "other-agent" Checkpoint_snapshot.After_assistant_collected) with
       | Error _->true |Ok ()->false);
    check bool "rejected checkpoint does not consume source sequence" true
      (before=projection_value (Projection.current_cursor projection));
    scope_value (Scope.record_checkpoint root fact);
    let parent=projection_value (Projection.latest_checkpoint projection) |> Option.get in
    let turn=scope_value (Scope.open_turn root ~ordinal:1) in
    let provider=scope_value (Scope.open_provider_attempt turn ~ordinal:0 (binding ())) in
    let call=scope_value (Scope.open_invocation provider ~invocation:(invocation ())
        ~tool_name:"checkpoint-child" ~input:(`Assoc [])) in
    ignore (scope_value (Scope.execute call ~invoke:(fun ~start_child ~tool_name:_ ~input:_ ->
      let child=scope_value (start_child ~agent_name:"checkpoint-child") in
      scope_value (Scope.record_checkpoint child (make "checkpoint-child" Checkpoint_snapshot.After_input_wait_changed));
      scope_value (Scope.finish child Event.Succeeded);
      "child settled",Types.Tool_succeeded)));
    let latest=projection_value (Projection.latest_checkpoint projection) |> Option.get in
    check bool "later child checkpoint does not replace root checkpoint" true
      (Checkpoint_snapshot.equal latest.snapshot fact && latest.event_id=parent.event_id && latest.through=parent.through);
    scope_value (Scope.close_provider_attempt provider Event.Succeeded);
    scope_value (Scope.close_turn turn Event.Succeeded);
    scope_value (Scope.finish root Event.Succeeded);
    let after=projection_value (Projection.current_cursor projection) in
    check bool "closed execution rejects checkpoint mutation" true
      (match Scope.record_checkpoint root fact with Error _->true |Ok ()->false);
    check bool "closed checkpoint rejection appends no fact" true
      (after=projection_value (Projection.current_cursor projection));
    locator)) in
  let reopened=projection_value (Agent.open_execution_projection ~runtime ~dir locator) in
  let latest=projection_value (Projection.latest_checkpoint reopened) |> Option.get in
  check bool "reopened root checkpoint keeps exact frozen value" true
    (Checkpoint_snapshot.equal latest.snapshot fact)
;;

type publication_interrupt = Publication_break | Publication_cancel

let test_reserved_publication_replays_after_unlock interrupt =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let runtime = Agent.create_execution_runtime ~sw ~domain_mgr:env#domain_mgr
      ~domain_count:1 |> Result.map_error Error.to_string |> value in
  let internal_runtime = Runtime.create ~sw ~domain_mgr:env#domain_mgr ~domain_count:1
      |> Result.map_error Runtime.create_error_to_string |> value in
  let dir = make_dir env#fs "agent_core-reserved-observation-" in
  Eio.Switch.on_release sw (fun () -> Eio.Path.rmtree ~missing_ok:true dir);
  writer_value (Writer.run ~codec:(Codec.of_runtime internal_runtime) ~dir (fun ~sw:_ writer ->
    let scope = scope_value (Scope.start ~writer ~agent_name:"reserved-observation") in
    let bus = Event_bus.create () in
    let config = Event_bus.subscription_config ~capacity:4 ~overflow:Drop_newest
        |> Result.map_error (fun _ -> "invalid fixture subscription") |> value in
    let subscription = Event_bus.subscribe ~config ~filter:Event_bus.filter_tools_only bus in
    let first = ref true and interrupt_publication = ref (fun () -> ()) in
    let observer = Internal.Agent_tool_observer.create ~publish:(fun bus event ->
      Event_bus.publish bus event;
      if !first then (first := false; !interrupt_publication ())) scope in
    observer.register
      ~run_id:(Scope.scope_locator_run_id (Scope.scope_locator scope)) ~event_bus:(Some bus);
    let turn = scope_value (Scope.open_turn scope ~ordinal:1) in
    let provider = scope_value (Scope.open_provider_attempt turn ~ordinal:0 (binding ())) in
    let call = scope_value (Scope.open_invocation provider ~invocation:(invocation ())
        ~tool_name:"reserved-projection-tool" ~input:(`Assoc [])) in
    let effects = ref 0 in
    (match Scope.execute call ~invoke:(fun ~start_child:_ ~tool_name:_ ~input:_ ->
       incr effects; "committed before publication", Types.Tool_succeeded) with
     | Ok (Scope.Executed _) -> ()
     | Ok (Scope.Replayed _) -> fail "fresh effect unexpectedly replayed"
     | Error error -> fail (Scope.error_to_string error));
    scope_value (Scope.close_provider_attempt provider Event.Succeeded);
    scope_value (Scope.close_turn turn Event.Succeeded);
    scope_value (Scope.finish scope Event.Succeeded);
    let occurrence = match Tool_contract.Invocation.occurrence (Scope.bound_invocation call) with
      | Some occurrence -> occurrence | None -> fail "durable call lost canonical occurrence" in
    observer.settled_observers occurrence;
    let projection = projection_value
        (Agent.open_execution_projection ~runtime ~dir (public_locator scope)) in
    let read () = projection_value (Projection.read_page projection
        ~after:(Projection.beginning_cursor projection) ~limit:1024 ()) in
    let before = read () in
    let caught = match Eio.Cancel.sub (fun cancellation ->
      interrupt_publication := (match interrupt with
        | Publication_break -> (fun () -> raise Sys.Break)
        | Publication_cancel -> (fun () ->
            Eio.Cancel.cancel cancellation Exit;
            Eio.Fiber.check ()));
      observer.flush ()) with
      | () -> None
      | exception exn -> Some exn in
    check bool "reserved publication interruption escapes to caller" true
      (match interrupt,caught with
       | Publication_break,Some Sys.Break
       | Publication_cancel,Some (Eio.Cancel.Cancelled Exit) -> true
       | _ -> false);
    let accepted = Event_bus.drain subscription in
    check int "receiver accepted first occurrence before interruption" 1 (List.length accepted);
    (* Outside the cancelled child context, the same coordinator must remain
       usable and retry the unacknowledged source occurrence without effects. *)
    observer.flush ();
    let replay = Event_bus.drain subscription in
    let canonical = projection_value (Projection.read_tool_observations projection
        ~after:(Projection.beginning_cursor projection) ~limit:1024 ()) in
    check int "retry delivers called and completed" 2 (List.length replay);
    check bool "retry retains the accepted unacknowledged event identity" true
      (match accepted,replay with [first],retry::_ -> first=retry | _ -> false);
    check bool "retry matches exact canonical observations in source order" true
      (replay=List.map (fun (observation:Projection.tool_observation) -> observation.event)
        canonical.observations);
    observer.flush ();
    check int "acknowledged source observations do not repeat" 0
      (List.length (Event_bus.drain subscription));
    check int "reserved publication retry never repeats effect" 1 !effects;
    let after = read () in
    check bool "reserved publication failure leaves canonical events and cursor unchanged" true
      (before.events=after.events && before.next_cursor=after.next_cursor);
    let terminal = projection_value (Agent.read_execution_terminal projection) in
    check bool "committed success is not relabelled by reserved publication" true
      (match terminal with
       | Some {Agent.disposition={outcome=Terminal_succeeded;recovery=Retire};_} -> true
       | _ -> false)))
;;

let () =
  Alcotest.run
    "Execution projection"
    [ ( "authority"
      , [ test_case "live and restart projection" `Quick test_live_and_restart_projection
        ; test_case "typed checkpoint facts enforce ownership and reopen" `Quick
            test_checkpoint_fact_ownership_and_reopen
        ; test_case "Sys.Break publication retries after normal mutex unlock" `Quick
            (fun () -> test_reserved_publication_replays_after_unlock Publication_break)
        ; test_case "cancelled publication retries from a fresh context" `Quick
            (fun () -> test_reserved_publication_replays_after_unlock Publication_cancel)
        ; test_case "native sync/stream request evidence survives errors and reopen"
            `Quick test_native_request_provenance_reopen
        ; test_case "settled invocation projection" `Quick test_settled_invocation_projection
        ; test_case "terminal callback failure readback" `Quick test_terminal_callback_failure_readback
        ; test_case "terminal unknown-effect readback" `Quick test_terminal_unknown_effect_readback
        ; test_case
            "cursor codec is closed and versioned"
            `Quick
            test_cursor_codec_is_closed_and_versioned
        ] )
    ]
;;
