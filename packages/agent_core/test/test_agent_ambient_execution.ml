open Agent_sdk
open Alcotest
module Internal = Agent_sdk__
module Context = Internal.Execution_context
module Scope = Internal.Execution_agent_scope

let expect_ambient_child ~agent_name run =
  let observed = ref None in
  let result =
    Context.with_child_scope_factory
      (fun ~agent_name ->
         observed := Some agent_name;
         Error Scope.Run_not_found)
      run
  in
  check (option string) "exact child agent identity" (Some agent_name) !observed;
  match result with
  | Error (detailed : Agent.detailed_error) ->
    (match detailed.error, detailed.provider_failure with
     | Error.Internal _, None -> ()
     | _ -> fail "ambient child scope failure was not preserved")
  | Ok _ -> fail "ambient child scope failure was not preserved"
;;

let test_all_agent_entrypoints_consume_ambient_child () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let agent_name = "ambient-child-agent" in
  let make_agent () =
    Agent.create
      ~net:(Eio.Stdenv.net env)
      ~config:{ (Types.default_config ~model:"unused") with name = agent_name }
      ()
  in
  expect_ambient_child ~agent_name (fun () ->
    Agent.run_detailed ~sw (make_agent ()) "regular");
  expect_ambient_child ~agent_name (fun () ->
    Agent.Advanced.run_blocks_detailed
      ~sw
      ~api_strategy:Agent.Sync
      ~on_tool_boundary:(fun _ -> Agent.Advanced.Continue)
      (make_agent ())
      [ Types.Text "advanced" ]);
  expect_ambient_child ~agent_name (fun () ->
    Agent.run_turn_stream_detailed ~sw ~on_event:(fun _ -> ()) (make_agent ()))
;;

let test_explicit_store_conflicts_with_ambient_child () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let runtime =
    match
      Agent.create_execution_runtime
        ~sw
        ~domain_mgr:(Eio.Stdenv.domain_mgr env)
        ~domain_count:1
    with
    | Ok runtime -> runtime
    | Error error -> fail (Error.to_string error)
  in
  let native_path = Filename.temp_file "oas-ambient-conflict-" ".dir" in
  Sys.remove native_path;
  let dir = Eio.Path.(Eio.Stdenv.fs env / native_path) in
  Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
  Fun.protect
    ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir)
    (fun () ->
       let store = Agent.execution_store ~runtime ~dir () in
       let factory_called = ref false in
       let agent =
         Agent.create
           ~net:(Eio.Stdenv.net env)
           ~config:
             { (Types.default_config ~model:"unused") with
               name = "ambient-conflict-agent"
             }
           ()
       in
       let result =
         Context.with_child_scope_factory
           (fun ~agent_name:_ ->
              factory_called := true;
              Error Scope.Run_not_found)
           (fun () -> Agent.run_detailed ~sw ~execution_store:store agent "conflict")
       in
       check bool "conflict does not consume either authority" false !factory_called;
       match result with
       | Error (detailed : Agent.detailed_error) ->
         (match detailed.error, detailed.provider_failure with
          | Error.Internal detail, None ->
            check
              string
              "existing conflict remains explicit"
              "execution store and child scope factory are mutually exclusive"
              detail
          | _ -> fail "dual execution authority was not rejected")
       | Ok _ -> fail "dual execution authority was not rejected")
;;

let () =
  Alcotest.run
    "Ambient recursive execution"
    [ ( "authority"
      , [ test_case
            "all Agent entrypoints consume ambient child"
            `Quick
            test_all_agent_entrypoints_consume_ambient_child
        ; test_case
            "explicit store conflicts with ambient child"
            `Quick
            test_explicit_store_conflicts_with_ambient_child
        ] )
    ]
;;
