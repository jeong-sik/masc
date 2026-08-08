open Agent_sdk
open Alcotest
module Internal = Agent_sdk__
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
  ; content = [ Types.Text "child-finished" ]
  ; usage = None
  ; telemetry = None
  }
;;

let child_transport : Llm_provider.Llm_transport.t =
  { complete_sync =
      (fun _request ->
        { Llm_provider.Llm_transport.response = Ok child_response; latency_ms = Some 0 })
  ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok child_response)
  }
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
  Agent.create
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
  let dir = make_dir fs "oas-projection-live-" in
  let other_dir = make_dir fs "oas-projection-other-" in
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
  let dir = make_dir (Eio.Stdenv.fs env) "oas-projection-cursor-" in
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

let () =
  Alcotest.run
    "Execution projection"
    [ ( "authority"
      , [ test_case "live and restart projection" `Quick test_live_and_restart_projection
        ; test_case
            "cursor codec is closed and versioned"
            `Quick
            test_cursor_codec_is_closed_and_versioned
        ] )
    ]
;;
