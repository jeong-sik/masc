(* The runtime's provider transport takes its connections from the installed
   cache (RFC-0492 §3.1): two runs against one provider origin share one
   connection, and the runtime health response reports it (RFC-0492 §6). A
   run on a domain other than the one that installed the cache opens its own
   connection, because Eio refuses a switch from another domain. A Keeper
   turn streams, so the streaming path shares the connection the same way. *)

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

(* Longer than either test runs, so no parked connection expires. *)
let idle_ttl_s = 60.0

(* The same answer as server-sent events, for a model the catalog marks as
   streaming. The body has a length, so the connection stays open after it. *)
let streamed_answer =
  "data: {\"id\":\"cache-wiring\",\"model\":\"fixture\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"done\"},\"finish_reason\":null}]}\n\n\
   data: {\"id\":\"cache-wiring\",\"model\":\"fixture\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}\n\n\
   data: [DONE]\n\n"
;;

let model_id = "fixture"

let count name json = Yojson.Safe.Util.(member name json |> to_int)

let provider_cfg (provider : Fixture.test_server) =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~provider_id:"fixture"
    ~model_id
    ~base_url:provider.base_url
    ~api_key:"synthetic-local-key"
    ~request_path:"/chat/completions"
    ~tool_stream:false
    ()
;;

let run_once ?on_event ~sw ~net provider_cfg =
  let config =
    Runtime_agent.default_config
      ~media_store:(Agent_core.History.Memory_store.create ())
      ~name:"cache-wiring"
      ~provider_cfg
      ~system_prompt:""
      ~tools:[]
  in
  match Runtime_agent.run_blocks ~sw ~net ~config ?on_event [ Agent_core.Types.Text "hello" ] with
  | Ok { Runtime_agent.stop_reason = Runtime_agent.Completed _; _ } -> ()
  | Ok _ -> Alcotest.fail "the run did not complete"
  | Error error -> Alcotest.failf "the run failed: %s" (Agent_core.Error.to_string error)
;;

(* Runs [f] with a provider fixture and a cache installed on this domain's
   switch, then ends the switch. *)
let with_provider_and_cache ?(behavior = Fixture.Reply_with (fun _ _ -> `OK, answer)) env f =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  try
    Eio.Switch.run
    @@ fun sw ->
    let provider = Fixture.start_server ~sw ~net ~clock behavior in
    Provider_connection_cache_ref.install ~sw ~clock ~idle_ttl_seconds:idle_ttl_s;
    f ~sw ~net provider;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_two_runs_share_one_connection () =
  Eio_main.run
  @@ fun env ->
  Alcotest.(check bool) "no cache is reported before one is installed" true
    (Health.provider_connection_cache_json () = `Null);
  with_provider_and_cache env (fun ~sw ~net provider ->
    run_once ~sw ~net (provider_cfg provider);
    run_once ~sw ~net (provider_cfg provider);
    let cache = Health.provider_connection_cache_json () in
    Alcotest.(check int) "one connection opened" 1 (count "created_total" cache);
    Alcotest.(check int) "the second run reused it" 1 (count "reused_total" cache);
    Alcotest.(check int) "it is parked again" 1 (count "idle_total" cache))
;;

let test_a_run_on_another_domain_opens_its_own_connection () =
  Eio_main.run
  @@ fun env ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  with_provider_and_cache env (fun ~sw:_ ~net provider ->
    let cache_seen_there =
      Eio.Domain_manager.run domain_mgr (fun () ->
        Eio.Switch.run (fun run_sw -> run_once ~sw:run_sw ~net (provider_cfg provider));
        Health.provider_connection_cache_json ())
    in
    Alcotest.(check int) "the other domain reads the cache's statistics" 0
      (count "created_total" cache_seen_there);
    Alcotest.(check int) "the provider got the request" 1 (Fixture.post_count provider);
    let cache = Health.provider_connection_cache_json () in
    Alcotest.(check int) "the cache opened no connection" 0 (count "created_total" cache);
    Alcotest.(check int) "and parked none" 0 (count "idle_total" cache))
;;

(* Marks [model_id] as streaming until [sw] ends. *)
let publish_streaming_model ~sw =
  let previous = Llm_provider.Catalog_snapshot.current () in
  Eio.Switch.on_release sw (fun () -> Llm_provider.Catalog_snapshot.publish previous);
  let source =
    Printf.sprintf
      "[[models]]\nmodel_id = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\n\
       max_context_tokens = 8192\nmax_output_tokens = 128\nsupports_native_streaming = true\n"
      model_id
  in
  match Llm_provider.Model_catalog.of_toml_string ~source:"cache-wiring" source with
  | Ok catalog ->
    Llm_provider.Catalog_snapshot.publish
      (Masc_test_deps.admit_catalogs ~models:(Some catalog) ~providers:None)
  | Error error -> Alcotest.fail error
;;

let test_two_streamed_runs_share_one_connection () =
  Eio_main.run
  @@ fun env ->
  with_provider_and_cache ~behavior:(Fixture.Stream_reply streamed_answer) env
    (fun ~sw ~net provider ->
       Masc_test_deps.init_eio_clock ~sw env;
       publish_streaming_model ~sw;
       let provider_cfg = provider_cfg provider in
       Alcotest.(check bool) "the catalog marks the model as streaming" true
         (Runtime_agent.provider_caps_of_config provider_cfg).supports_native_streaming;
       let on_event (_ : Agent_core.Types.sse_event) = () in
       run_once ~on_event ~sw ~net provider_cfg;
       run_once ~on_event ~sw ~net provider_cfg;
       let cache = Health.provider_connection_cache_json () in
       Alcotest.(check int) "one connection opened" 1 (count "created_total" cache);
       Alcotest.(check int) "the second stream reused it" 1 (count "reused_total" cache);
       Alcotest.(check int) "it is parked again" 1 (count "idle_total" cache))
;;

let () =
  Alcotest.run
    "provider_connection_cache_wiring"
    [ ( "runtime transport"
      , [ Alcotest.test_case "two runs share one connection" `Quick
            test_two_runs_share_one_connection
        ; Alcotest.test_case "a run on another domain opens its own connection" `Quick
            test_a_run_on_another_domain_opens_its_own_connection
        ; Alcotest.test_case "two streamed runs share one connection" `Quick
            test_two_streamed_runs_share_one_connection
        ] )
    ]
;;
