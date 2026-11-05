(* The runtime's provider transport takes its connections from the installed
   cache (RFC-0492 §3.1): two runs against one provider origin share one
   connection, and the runtime health response reports it (RFC-0492 §6). *)

module Fixture = Exact_output_fixture
module Health = Server_routes_http_runtime_health_fleet

let answer =
  Yojson.Safe.to_string
    (`Assoc
        [ "id", `String "cache-wiring"
        ; "model", `String "fixture"
        ; ( "choices"
          , `List
              [ `Assoc
                  [ "index", `Int 0
                  ; "message", `Assoc [ "role", `String "assistant"; "content", `String "done" ]
                  ; "finish_reason", `String "stop"
                  ]
              ] )
        ; ( "usage"
          , `Assoc [ "prompt_tokens", `Int 1; "completion_tokens", `Int 1; "total_tokens", `Int 2 ] )
        ])
;;

let count name json = Yojson.Safe.Util.(member name json |> to_int)

let test_two_runs_share_one_connection () =
  Eio_main.run
  @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Alcotest.(check bool) "no cache is reported before one is installed" true
    (Health.provider_connection_cache_json () = `Null);
  try
    Eio.Switch.run
    @@ fun sw ->
    let provider =
      Fixture.start_server ~sw ~net ~clock (Fixture.Reply_with (fun _ _ -> `OK, answer))
    in
    Provider_connection_cache_ref.install (Llm_provider.Http_client.create_cache ~sw ~clock ());
    let provider_cfg =
      Llm_provider.Provider_config.make
        ~kind:Llm_provider.Provider_config.OpenAI_compat
        ~model_id:"fixture"
        ~base_url:provider.base_url
        ~api_key:"synthetic-local-key"
        ~request_path:"/chat/completions"
        ~tool_stream:false
        ()
    in
    let run () =
      let config =
        Runtime_agent.default_config
          ~media_store:(Agent_core.History.Memory_store.create ())
          ~name:"cache-wiring"
          ~provider_cfg
          ~system_prompt:""
          ~tools:[]
      in
      match Runtime_agent.run_blocks ~sw ~net ~config [ Agent_core.Types.Text "hello" ] with
      | Ok { Runtime_agent.stop_reason = Runtime_agent.Completed _; _ } -> ()
      | Ok _ -> Alcotest.fail "the run did not complete"
      | Error error -> Alcotest.failf "the run failed: %s" (Agent_core.Error.to_string error)
    in
    run ();
    run ();
    let cache = Health.provider_connection_cache_json () in
    Alcotest.(check int) "one connection opened" 1 (count "created_total" cache);
    Alcotest.(check int) "the second run reused it" 1 (count "reused_total" cache);
    Alcotest.(check int) "it is parked again" 1 (count "idle_total" cache);
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let () =
  Alcotest.run
    "provider_connection_cache_wiring"
    [ ( "runtime transport"
      , [ Alcotest.test_case "two runs share one connection" `Quick
            test_two_runs_share_one_connection
        ] )
    ]
;;
