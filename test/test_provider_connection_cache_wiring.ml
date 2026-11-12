(* The runtime's provider transport takes its connections from the installed
   cache (RFC-0492 §3.1): two runs against one provider origin share one
   connection, and the [/health?full=1] response reports it without naming
   the origin (RFC-0492 §6, RFC-0132). A run on a domain other than the one
   that installed the cache opens its own connection, because Eio refuses a
   switch from another domain. A Keeper turn streams, so the streaming path
   shares the connection the same way. The cache leaves with its switch. *)

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

let health_port = 8935

(* The [provider_connection_cache] section of the [/health?full=1] response,
   after the snapshot it is served from is computed again. *)
let full_health_cache () =
  let request_authority =
    match Server_request_authority.of_host_port ~host:"localhost" ~port:health_port with
    | Ok authority -> authority
    | Error `Malformed -> Alcotest.fail "the health authority is malformed"
  in
  let request = Httpun.Request.create `GET "/health?full=1" in
  Server_routes_http_runtime.For_testing.refresh_full_health_snapshot_now ~request_authority
    request;
  Yojson.Safe.Util.member "provider_connection_cache"
    (Server_routes_http_runtime.make_health_response_json ~request_authority request)
;;

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
    Provider_connection_cache_ref.install ~sw ~mono_clock:(Eio.Stdenv.mono_clock env)
      ~idle_ttl_seconds:idle_ttl_s;
    f ~sw ~net provider;
    Eio.Switch.fail sw Exit
  with
  | Exit ->
    Alcotest.(check bool) "the cache is uninstalled with its switch" true
      (Option.is_none (Provider_connection_cache_ref.for_this_domain ()))
;;

let test_two_runs_share_one_connection () =
  Eio_main.run
  @@ fun env ->
  Alcotest.(check bool) "no cache is reported before one is installed" true
    (Health.provider_connection_cache_json () = `Null);
  with_provider_and_cache env (fun ~sw ~net provider ->
    Masc_test_deps.init_eio_clock ~sw env;
    run_once ~sw ~net (provider_cfg provider);
    run_once ~sw ~net (provider_cfg provider);
    let cache = full_health_cache () in
    Alcotest.(check int) "one connection opened" 1 (count "created_total" cache);
    Alcotest.(check int) "the second run reused it" 1 (count "reused_total" cache);
    Alcotest.(check int) "it is parked again" 1 (count "idle_total" cache);
    Alcotest.(check int) "on its one origin" 1 (count "idle_max_per_origin" cache);
    Alcotest.(check (list string)) "no field names an origin"
      [ "idle_total"
      ; "idle_max_per_origin"
      ; "reused_total"
      ; "created_total"
      ; "closed_total"
      ; "closed_after_reuse"
      ]
      (Yojson.Safe.Util.keys cache));
  Alcotest.(check bool) "no cache is reported once its switch is released" true
    (Health.provider_connection_cache_json () = `Null)
;;

let test_reconnect_uses_fresh_transport_and_restores_reuse () =
  Eio_main.run @@ fun env ->
  with_provider_and_cache env (fun ~sw ~net provider ->
    Masc_test_deps.init_eio_clock ~sw env;
    let cfg = provider_cfg provider in
    run_once ~sw ~net cfg;
    Provider_connection_cache_ref.with_fresh_connections (fun () ->
      Alcotest.(check bool) "recovery has no connection cache" true
        (Option.is_none (Provider_connection_cache_ref.for_this_domain ()));
      run_once ~sw ~net cfg);
    run_once ~sw ~net cfg;
    Alcotest.(check int) "all three requests reached the provider" 3 (Fixture.post_count provider);
    let cache = Health.provider_connection_cache_json () in
    Alcotest.(check int) "the fresh transport did not borrow a cache lease" 1
      (count "created_total" cache);
    Alcotest.(check int) "the surrounding transport resumes cache reuse" 1
      (count "reused_total" cache))
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

(* Reads one HTTP/1.1 request head and answers [response], on every request
   of a connection; with [close_after_first] the connection closes after the
   first answer. *)
let start_raw_server ?(close_after_first = false) ~sw ~net response =
  let socket =
    Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | _ -> Alcotest.fail "the loopback listener has no TCP port"
  in
  let handler flow _addr =
    let reader = Eio.Buf_read.of_flow flow ~max_size:8192 in
    let rec read_head () =
      match Eio.Buf_read.line reader with
      | "" -> ()
      | _ -> read_head ()
    in
    let rec serve () =
      read_head ();
      Eio.Flow.copy_string response flow;
      if close_after_first then Eio.Flow.shutdown flow `All else serve ()
    in
    try serve () with
    | End_of_file | Eio.Io _ -> ()
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Eio.Net.run_server socket handler ~on_error:(fun _ -> ()));
  Printf.sprintf "http://127.0.0.1:%d" port
;;

(* One server closes a connection after its first answer, so the request
   that reuses it fails. The other answers [Connection: close], so its new
   connection closes as not persistent. The full health response counts both
   in [closed_total] and only the first in [closed_after_reuse]. *)
let test_health_tells_a_reused_connection's_closes_from_a_new_one's () =
  Eio_main.run
  @@ fun env ->
  with_provider_and_cache env (fun ~sw ~net _provider ->
    Masc_test_deps.init_eio_clock ~sw env;
    let cache =
      match Provider_connection_cache_ref.for_this_domain () with
      | Some cache -> cache
      | None -> Alcotest.fail "the cache is installed on this domain"
    in
    let ok_answer = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" in
    let closes_after_first = start_raw_server ~close_after_first:true ~sw ~net ok_answer in
    let answers_close =
      start_raw_server ~sw ~net
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
    in
    let get url = Llm_provider.Http_client.get_sync ~cache ~sw ~net ~url ~headers:[] () in
    (match get closes_after_first with
     | Ok _ -> ()
     | Error _ -> Alcotest.fail "the first request is answered");
    (match get closes_after_first with
     | Error (Llm_provider.Http_client.NetworkError _) -> ()
     | Ok _ | Error _ -> Alcotest.fail "the reused connection the server closed fails");
    (match get answers_close with
     | Ok _ -> ()
     | Error _ -> Alcotest.fail "the closing answer is answered");
    let closed name reason =
      Yojson.Safe.Util.(full_health_cache () |> member name |> member reason |> to_int)
    in
    Alcotest.(check int) "failed requests in all" 1 (closed "closed_total" "request_failed");
    Alcotest.(check int) "of them on a reused connection" 1
      (closed "closed_after_reuse" "request_failed");
    Alcotest.(check int) "not persistent in all" 1 (closed "closed_total" "not_persistent");
    Alcotest.(check int) "none on a reused connection" 0
      (closed "closed_after_reuse" "not_persistent"))
;;

(* The server answers the first POST and closes the connection. The second
   POST, whose body is larger than the socket buffers, reuses that connection
   and is cut off while its bytes go out. The full health response counts it
   as [request_not_delivered], in all and on a reused connection, and not as
   [request_failed] (RFC-0492 §6). *)
let test_health_counts_a_request_cut_off_while_written () =
  Eio_main.run
  @@ fun env ->
  with_provider_and_cache env (fun ~sw ~net _provider ->
    Masc_test_deps.init_eio_clock ~sw env;
    let cache =
      match Provider_connection_cache_ref.for_this_domain () with
      | Some cache -> cache
      | None -> Alcotest.fail "the cache is installed on this domain"
    in
    let url =
      start_raw_server ~close_after_first:true ~sw ~net
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
    in
    let post body =
      Llm_provider.Http_client.post_sync_once ~cache ~net ~url
        ~headers:
          [ "Content-Type", "application/json"
          ; "Content-Length", string_of_int (String.length body)
          ]
        ~body ()
    in
    (match post "{}" with
     | Ok { status = 200; _ } -> ()
     | Ok _ | Error _ -> Alcotest.fail "the first request is answered");
    (match post (String.make (16 * 1024 * 1024) 'x') with
     | Error (Llm_provider.Http_client.Dispatch_started_error (NetworkError _)) -> ()
     | Ok _ | Error _ -> Alcotest.fail "the reused connection the server closed fails");
    let closed name reason =
      Yojson.Safe.Util.(full_health_cache () |> member name |> member reason |> to_int)
    in
    Alcotest.(check int) "not delivered in all" 1 (closed "closed_total" "request_not_delivered");
    Alcotest.(check int) "of them on a reused connection" 1
      (closed "closed_after_reuse" "request_not_delivered");
    Alcotest.(check int) "none counted as a failed request" 0
      (closed "closed_total" "request_failed"))
;;

let () =
  Alcotest.run
    "provider_connection_cache_wiring"
    [ ( "runtime transport"
      , [ Alcotest.test_case "two runs share one connection" `Quick
            test_two_runs_share_one_connection
        ; Alcotest.test_case "a run on another domain opens its own connection" `Quick
            test_a_run_on_another_domain_opens_its_own_connection
        ; Alcotest.test_case "reconnect uses a fresh transport and restores reuse" `Quick
            test_reconnect_uses_fresh_transport_and_restores_reuse
        ; Alcotest.test_case "two streamed runs share one connection" `Quick
            test_two_streamed_runs_share_one_connection
        ; Alcotest.test_case "health tells a reused connection's closes from a new one's"
            `Quick test_health_tells_a_reused_connection's_closes_from_a_new_one's
        ; Alcotest.test_case "health counts a request cut off while written" `Quick
            test_health_counts_a_request_cut_off_while_written
        ] )
    ]
;;
