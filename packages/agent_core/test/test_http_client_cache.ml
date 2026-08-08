(** Connection cache tests for Http_client.

    These tests exercise the reusable TCP/TLS connection cache through both
    the high-level {!Complete} API and direct {!Http_client} calls. *)

open Agent_sdk
open Llm_provider

exception Lifecycle_watchdog

let await_promise ~clock ~label promise =
  try Eio.Time.with_timeout_exn clock 1.0 (fun () -> Eio.Promise.await promise) with
  | Eio.Time.Timeout -> Alcotest.failf "%s timed out after 1 second" label
;;

let fresh_port () =
  let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt s Unix.SO_REUSEADDR true;
  Unix.bind s (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port =
    match Unix.getsockname s with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> failwith "not inet"
  in
  Unix.close s;
  port
;;

let start_mock_server ~sw ~net ?(status = `OK) ?capture_headers response_body =
  let port = fresh_port () in
  let handler _conn req body =
    let request_body = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    (match capture_headers with
     | Some seen -> seen := Cohttp.Request.headers req
     | None -> ());
    ignore request_body;
    Cohttp_eio.Server.respond_string ~status ~body:response_body ()
  in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:8
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  Printf.sprintf "http://127.0.0.1:%d" port
;;

let anthropic_response text =
  Printf.sprintf
    {|{"id":"msg-1","type":"message","role":"assistant","model":"mock","content":[{"type":"text","text":"%s"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}|}
    text
;;

let make_anthropic_config base_url =
  Provider_config.make
    ~kind:Provider_config.Anthropic
    ~model_id:"test-model"
    ~base_url
    ~request_path:"/v1/messages"
    ~temperature:0.0
    ~max_tokens:100
    ()
;;

let test_complete_reuses_connection () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_mock_server ~sw ~net:env#net (anthropic_response "cached") in
    let config = make_anthropic_config url in
    let cache = Http_client.create_cache ~sw () in
    (match
       Complete.complete ~sw ~net:env#net ~config ~messages:[] ~connection_cache:cache ()
     with
     | Ok _ -> ()
     | Error _ -> Alcotest.fail "expected Ok first call");
    let stats_after_first = Http_client.cache_stats cache in
    Alcotest.(check int) "one create after first" 1 stats_after_first.create_count_total;
    Alcotest.(check int) "no reuse yet" 0 stats_after_first.reuse_count_total;
    Alcotest.(check int) "one idle connection" 1 stats_after_first.total_idle;
    (match
       Complete.complete ~sw ~net:env#net ~config ~messages:[] ~connection_cache:cache ()
     with
     | Ok _ -> ()
     | Error _ -> Alcotest.fail "expected Ok second call");
    let stats_after_second = Http_client.cache_stats cache in
    Alcotest.(check int) "still one create" 1 stats_after_second.create_count_total;
    Alcotest.(check int) "one reuse" 1 stats_after_second.reuse_count_total;
    Alcotest.(check int) "still one idle" 1 stats_after_second.total_idle;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_eviction_fiber_closes_idle () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_mock_server ~sw ~net:env#net (anthropic_response "cached") in
    let config = make_anthropic_config url in
    let cache = Http_client.create_cache ~sw ~clock:env#clock ~idle_ttl_seconds:0.05 () in
    (match
       Complete.complete ~sw ~net:env#net ~config ~messages:[] ~connection_cache:cache ()
     with
     | Ok _ -> ()
     | Error _ -> Alcotest.fail "expected Ok");
    let stats_after_first = Http_client.cache_stats cache in
    Alcotest.(check int) "one idle before eviction" 1 stats_after_first.total_idle;
    Eio.Time.sleep env#clock 0.2;
    let stats_after_wait = Http_client.cache_stats cache in
    Alcotest.(check int) "idle evicted by fiber" 0 stats_after_wait.total_idle;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_omits_connection_close_header () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let captured = ref (Cohttp.Header.of_list []) in
    let url =
      start_mock_server
        ~sw
        ~net:env#net
        ~capture_headers:captured
        (anthropic_response "cached")
    in
    let config = make_anthropic_config url in
    let cache = Http_client.create_cache ~sw () in
    (match
       Complete.complete ~sw ~net:env#net ~config ~messages:[] ~connection_cache:cache ()
     with
     | Ok _ -> ()
     | Error _ -> Alcotest.fail "expected Ok");
    let conn = Cohttp.Header.get !captured "connection" in
    Alcotest.(check (option string)) "no connection close" None conn;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let anthropic_sse_response text =
  Printf.sprintf
    "event: message_start\n\
     data: \
     {\"type\":\"message_start\",\"message\":{\"id\":\"msg-1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"mock\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":10,\"output_tokens\":0,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}\n\n\
     event: content_block_start\n\
     data: \
     {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n\
     event: content_block_delta\n\
     data: \
     {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"%s\"}}\n\n\
     event: content_block_stop\n\
     data: {\"type\":\"content_block_stop\",\"index\":0}\n\n\
     event: message_delta\n\
     data: \
     {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n\
     event: message_stop\n\
     data: {\"type\":\"message_stop\"}\n\n"
    text
;;

let start_sse_server ~sw ~net response_body =
  let port = fresh_port () in
  let handler _conn _req body =
    let _ = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    let headers = Cohttp.Header.of_list [ "content-type", "text/event-stream" ] in
    Cohttp_eio.Server.respond_string ~status:`OK ~headers ~body:response_body ()
  in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:8
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  Printf.sprintf "http://127.0.0.1:%d" port
;;

let drain_request_headers reader =
  let rec consume () =
    match Eio.Buf_read.line reader with
    | "" -> ()
    | _ -> consume ()
    | exception End_of_file -> ()
  in
  consume ()
;;

let resolve_once promise resolver =
  if not (Eio.Promise.is_resolved promise) then Eio.Promise.resolve resolver ()
;;

let observe_client_eof reader promise resolver =
  let rec consume () =
    match Eio.Buf_read.line reader with
    | _ -> consume ()
    | exception End_of_file -> resolve_once promise resolver
    | exception Eio.Io _ -> resolve_once promise resolver
  in
  consume ()
;;

let start_one_shot_lifecycle_server ~sw ~net ~clock ?body_delay_s body =
  let port = fresh_port () in
  let disconnected, notify_disconnected = Eio.Promise.create () in
  let handler flow _addr =
    let reader = Eio.Buf_read.of_flow flow ~max_size:8192 in
    drain_request_headers reader;
    let response_headers =
      Printf.sprintf
        "HTTP/1.1 200 OK\r\n\
         Content-Length: %d\r\n\
         Content-Type: text/plain\r\n\
         Connection: keep-alive\r\n\
         \r\n"
        (String.length body)
    in
    try
      Eio.Flow.copy_string response_headers flow;
      (match body_delay_s with
       | Some delay_s -> Eio.Time.sleep clock delay_s
       | None -> ());
      Eio.Flow.copy_string body flow;
      observe_client_eof reader disconnected notify_disconnected
    with
    | End_of_file | Eio.Io _ | Unix.Unix_error _ ->
      resolve_once disconnected notify_disconnected
  in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:1
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Net.accept_fork ~sw socket ~on_error:(fun _ -> ()) handler);
  Printf.sprintf "http://127.0.0.1:%d/one-shot" port, disconnected
;;

let with_lifecycle_watchdog ~clock ~label f =
  try
    Eio.Fiber.first f (fun () ->
      Eio.Time.sleep clock 1.0;
      raise Lifecycle_watchdog)
  with
  | Lifecycle_watchdog -> Alcotest.failf "%s did not complete within 1 second" label
;;

let await_client_disconnect ~clock ~label disconnected =
  with_lifecycle_watchdog ~clock ~label (fun () -> Eio.Promise.await disconnected)
;;

let test_cache_switch_releases_idle_connection () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun server_sw ->
  let url, disconnected =
    start_one_shot_lifecycle_server ~sw:server_sw ~net:env#net ~clock:env#clock "cached"
  in
  let cache =
    with_lifecycle_watchdog ~clock:env#clock ~label:"cache-owning switch" (fun () ->
      Eio.Switch.run
      @@ fun cache_sw ->
      let cache = Http_client.create_cache ~sw:cache_sw ~clock:env#clock () in
      (match
         Http_client.get_sync ~cache ~sw:cache_sw ~net:env#net ~url ~headers:[] ()
       with
       | Ok (200, "cached") -> ()
       | Ok (code, body) -> Alcotest.failf "expected 200/cached, got %d/%S" code body
       | Error _ -> Alcotest.fail "expected cached response");
      Alcotest.(check int)
        "one idle connection before cache switch release"
        1
        (Http_client.cache_stats cache).total_idle;
      cache)
  in
  Alcotest.(check int)
    "cache switch release drains idle connections"
    0
    (Http_client.cache_stats cache).total_idle;
  await_client_disconnect
    ~clock:env#clock
    ~label:"cache switch release closes idle connection"
    disconnected
;;

let test_stream_reuses_connection () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_sse_server ~sw ~net:env#net (anthropic_sse_response "streamed") in
    let config = make_anthropic_config url in
    let cache = Http_client.create_cache ~sw () in
    let got = ref [] in
    (match
       Complete.complete_stream
         ~sw
         ~net:env#net
         ~config
         ~messages:[]
         ~connection_cache:cache
         ~on_event:(function
           | Types.ContentBlockDelta { delta = Types.TextDelta s; _ } -> got := s :: !got
           | _ -> ())
         ()
     with
     | Ok _ -> ()
     | Error _ -> Alcotest.fail "expected Ok stream");
    Alcotest.(check (list string)) "received text" [ "streamed" ] (List.rev !got);
    let stats_after_first = Http_client.cache_stats cache in
    Alcotest.(check int) "one create after stream" 1 stats_after_first.create_count_total;
    Alcotest.(check int) "one idle after stream" 1 stats_after_first.total_idle;
    got := [];
    (match
       Complete.complete_stream
         ~sw
         ~net:env#net
         ~config
         ~messages:[]
         ~connection_cache:cache
         ~on_event:(function
           | Types.ContentBlockDelta { delta = Types.TextDelta s; _ } -> got := s :: !got
           | _ -> ())
         ()
     with
     | Ok _ -> ()
     | Error _ -> Alcotest.fail "expected Ok stream second");
    let stats_after_second = Http_client.cache_stats cache in
    Alcotest.(check int) "one reuse" 1 stats_after_second.reuse_count_total;
    Alcotest.(check int) "still one create" 1 stats_after_second.create_count_total;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_per_host_cap_closes_excess () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_mock_server ~sw ~net:env#net (anthropic_response "cached") in
    let config = make_anthropic_config url in
    let cache = Http_client.create_cache ~sw ~max_idle_per_host:1 () in
    let once () =
      match
        Complete.complete ~sw ~net:env#net ~config ~messages:[] ~connection_cache:cache ()
      with
      | Ok _ -> ()
      | Error _ -> Alcotest.fail "expected Ok concurrent"
    in
    Eio.Fiber.both once once;
    let stats = Http_client.cache_stats cache in
    Alcotest.(check int) "two creates for concurrent" 2 stats.create_count_total;
    Alcotest.(check int) "only one idle due to cap" 1 stats.total_idle;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_one_shot_get_closes_after_response () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url, disconnected =
      start_one_shot_lifecycle_server ~sw ~net:env#net ~clock:env#clock "ok"
    in
    (match Http_client.get_sync ~sw ~net:env#net ~url ~headers:[] () with
     | Ok (200, "ok") -> ()
     | Ok (code, body) -> Alcotest.failf "expected 200/ok, got %d/%S" code body
     | Error _ -> Alcotest.fail "expected Ok response");
    await_client_disconnect ~clock:env#clock ~label:"normal response" disconnected;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_one_shot_get_timeout_closes_connection () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url, disconnected =
      start_one_shot_lifecycle_server
        ~sw
        ~net:env#net
        ~clock:env#clock
        ~body_delay_s:0.2
        "ok"
    in
    (match
       Http_client.get_sync
         ~clock:env#clock
         ~timeout_s:0.05
         ~sw
         ~net:env#net
         ~url
         ~headers:[]
         ()
     with
     | Error (Http_client.TimeoutError { phase = Http_client.Http_operation; _ }) -> ()
     | Error _ -> Alcotest.fail "expected Http_operation timeout"
     | Ok (code, body) -> Alcotest.failf "expected timeout, got %d/%S" code body);
    await_client_disconnect ~clock:env#clock ~label:"timed-out response" disconnected;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_create_cache_rejects_invalid_params () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let expect_invalid_arg f =
      try
        ignore (f ());
        Alcotest.fail "expected Invalid_argument"
      with
      | Invalid_argument _ -> ()
    in
    expect_invalid_arg (fun () -> Http_client.create_cache ~sw ~max_idle_per_host:0 ());
    expect_invalid_arg (fun () -> Http_client.create_cache ~sw ~max_idle_per_host:(-1) ());
    expect_invalid_arg (fun () -> Http_client.create_cache ~sw ~idle_ttl_seconds:0.0 ());
    expect_invalid_arg (fun () ->
      Http_client.create_cache ~sw ~idle_ttl_seconds:(-1.0) ());
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_stream_cancellation_closes_connection () =
  (* Slow SSE server: cancel the fiber mid-body and assert the cached
     connection is closed, not parked back into the cache. *)
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_sse_server ~sw ~net:env#net (anthropic_sse_response "never") in
    let cache = Http_client.create_cache ~sw () in
    let stream () =
      Http_client.with_post_stream
        ~cache
        ~net:env#net
        ~url
        ~headers:[]
        ~body:""
        ~f:(fun reader ->
          (* Read one line then block forever, simulating a stuck consumer. *)
          ignore (Eio.Buf_read.line reader);
          Eio.Time.sleep env#clock 60.0;
          Ok ())
        ()
    in
    (try ignore (Eio.Time.with_timeout_exn env#clock 0.2 stream) with
     | Eio.Time.Timeout -> ());
    let stats = Http_client.cache_stats cache in
    Alcotest.(check int) "cancelled stream does not park connection" 0 stats.total_idle;
    Alcotest.(check int) "one create" 1 stats.create_count_total;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_stream_typed_error_closes_unconsumed_connection () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_sse_server ~sw ~net:env#net "unconsumed stream body" in
    let cache = Http_client.create_cache ~sw () in
    (match
       Http_client.with_post_stream
         ~cache
         ~net:env#net
         ~url
         ~headers:[]
         ~body:""
         ~f:(fun _reader -> Error `Stop)
         ()
     with
     | Ok (Error `Stop) -> ()
     | Ok (Ok _) -> Alcotest.fail "expected typed stream error"
     | Error _ -> Alcotest.fail "expected body callback result");
    let stats = Http_client.cache_stats cache in
    Alcotest.(check int) "typed error does not park connection" 0 stats.total_idle;
    Alcotest.(check int) "one create" 1 stats.create_count_total;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

(* A close-delimited stream reaches EOF precisely BECAUSE the peer went away.
   Draining it proves the body was fully read; it proves nothing about whether
   the socket may serve another request. Parking it would hand the next caller
   a dead connection. *)
let test_stream_connection_close_does_not_park () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let port = fresh_port () in
    let body = "data: one\n\ndata: two\n\n" in
    let handler flow _addr =
      let reader = Eio.Buf_read.of_flow flow ~max_size:8192 in
      drain_request_headers reader;
      try
        Eio.Flow.copy_string
          ("HTTP/1.1 200 OK\r\n\
            Content-Type: text/event-stream\r\n\
            Connection: close\r\n\
            \r\n"
           ^ body)
          flow
      with
      | End_of_file | Eio.Io _ | Unix.Unix_error _ -> ()
    in
    let socket =
      Eio.Net.listen
        env#net
        ~sw
        ~backlog:8
        ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Net.run_server socket handler ~on_error:(fun _ -> ()) ~max_connections:4);
    let url = Printf.sprintf "http://127.0.0.1:%d" port in
    let cache = Http_client.create_cache ~sw () in
    let seen = ref 0 in
    (match
       Http_client.with_post_stream
         ~cache
         ~net:env#net
         ~url
         ~headers:[]
         ~body:""
         ~f:(fun reader ->
           Http_client.read_sse ~reader ~on_data:(fun ~event_type:_ _ -> incr seen) ();
           Ok ())
         ()
     with
     | Ok (Ok ()) -> ()
     | Ok (Error _) | Error _ -> Alcotest.fail "close-delimited stream should drain");
    Alcotest.(check int) "stream fully drained" 2 !seen;
    let stats = Http_client.cache_stats cache in
    Alcotest.(check int) "connection-close stream is not parked" 0 stats.total_idle;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let with_raw_one_dispatch_server
      ?(http_version = "HTTP/1.1")
      ?(status = "200 OK")
      ?(response_headers = fun length -> [ Printf.sprintf "Content-Length: %d" length ])
      ?(encode_body = Fun.id)
      ?(keep_connection = false)
      ?(on_request = fun ~request_index:_ -> ())
      ?(before_response = fun ~clock:_ ~request_index:_ -> ())
      ~response_body
      f
  =
  let exception Raw_server_complete in
  let posts = Atomic.make 0 in
  let result = ref None in
  Eio_main.run
  @@ fun env ->
  (try
     Eio.Switch.run
     @@ fun sw ->
     let net = Eio.Stdenv.net env in
     let clock = Eio.Stdenv.clock env in
     let port = fresh_port () in
     let socket =
       Eio.Net.listen
         net
         ~sw
         ~backlog:8
         ~reuse_addr:true
         (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
     in
     let read_request reader =
       ignore (Eio.Buf_read.line reader : string);
       let rec read_headers content_length =
         let line = Eio.Buf_read.line reader |> String.trim in
         if String.equal line ""
         then content_length
         else (
           let content_length =
             match String.index_opt line ':' with
             | None -> content_length
             | Some separator ->
               let name = String.sub line 0 separator |> String.lowercase_ascii in
               if String.equal name "content-length"
               then
                 String.sub line (separator + 1) (String.length line - separator - 1)
                 |> String.trim
                 |> int_of_string
               else content_length
           in
           read_headers content_length)
       in
       ignore (Eio.Buf_read.take (read_headers 0) reader : string)
     in
     let handle flow _addr =
       let reader = Eio.Buf_read.of_flow ~max_size:max_int flow in
       let rec serve () =
         read_request reader;
         Atomic.incr posts;
         let request_index = Atomic.get posts in
         on_request ~request_index;
         before_response ~clock ~request_index;
         let encoded_body = encode_body response_body in
         let headers =
           "Content-Type: text/plain" :: response_headers (String.length response_body)
         in
         Eio.Flow.copy_string
           (Printf.sprintf
              "%s %s\r\n%s\r\n\r\n%s"
              http_version
              status
              (String.concat "\r\n" headers)
              encoded_body)
           flow;
         if keep_connection then serve ()
       in
       try serve () with
       | End_of_file | Eio.Io _ | Unix.Unix_error _ -> ()
     in
     Eio.Fiber.fork_daemon ~sw (fun () ->
       while true do
         Eio.Net.accept_fork socket ~sw ~on_error:(fun _ -> ()) handle
       done);
     result
     := Some
          (f
             ~sw
             ~net
             ~clock
             ~url:(Printf.sprintf "http://127.0.0.1:%d/one-dispatch" port));
     Eio.Switch.fail sw Raw_server_complete
   with
   | Raw_server_complete -> ());
  let result =
    match !result with
    | Some result -> result
    | None -> Alcotest.fail "raw one-dispatch server completed without a result"
  in
  result, Atomic.get posts
;;

let exercise_raw_one_dispatch_cache
      ?http_version
      ?status
      ?response_headers
      ?encode_body
      ?keep_connection
      ?(response_body = "ok")
      ()
  =
  with_raw_one_dispatch_server
    ?http_version
    ?status
    ?response_headers
    ?encode_body
    ?keep_connection
    ~response_body
  @@ fun ~sw ~net ~clock:_ ~url ->
  let cache = Http_client.create_cache ~sw () in
  let post () =
    Http_client.post_sync_once
      ~cache
      ~net
      ~url
      ~headers:[ "Content-Type", "application/json"; "Content-Length", "2" ]
      ~body:"{}"
      ()
  in
  let first = post () in
  let second = post () in
  first, second, Http_client.cache_stats cache
;;

let exercise_raw_stream_cache
      ?http_version
      ?response_headers
      ?encode_body
      ?keep_connection
      ?(response_body = "ok")
      ()
  =
  with_raw_one_dispatch_server
    ?http_version
    ?response_headers
    ?encode_body
    ?keep_connection
    ~response_body
  @@ fun ~sw ~net ~clock:_ ~url ->
  let cache = Http_client.create_cache ~sw () in
  let post () =
    Http_client.with_post_stream
      ~cache
      ~net
      ~url
      ~headers:[]
      ~body:"{}"
      ~f:Eio.Buf_read.take_all
      ()
  in
  let first = post () in
  let second = post () in
  first, second, Http_client.cache_stats cache
;;

let expect_stream_ok label = function
  | Ok body -> Alcotest.(check string) (label ^ " body") "ok" body
  | Error _ -> Alcotest.fail (label ^ " expected streamed 200 response")
;;

let test_stream_response_cache_eligibility () =
  let close_headers length =
    [ Printf.sprintf "Content-Length: %d" length; "Connection: close" ]
  in
  let (close_first, close_second, close_stats), close_posts =
    exercise_raw_stream_cache ~response_headers:close_headers ()
  in
  expect_stream_ok "connection-close first" close_first;
  expect_stream_ok "connection-close second" close_second;
  Alcotest.(check int) "connection-close POSTs" 2 close_posts;
  Alcotest.(check int) "connection-close creates fresh" 2 close_stats.create_count_total;
  Alcotest.(check int) "connection-close never reuses" 0 close_stats.reuse_count_total;
  Alcotest.(check int) "connection-close never parks" 0 close_stats.total_idle;
  let (unframed_first, unframed_second, unframed_stats), unframed_posts =
    exercise_raw_stream_cache ~response_headers:(fun _ -> []) ()
  in
  expect_stream_ok "unframed first" unframed_first;
  expect_stream_ok "unframed second" unframed_second;
  Alcotest.(check int) "unframed POSTs" 2 unframed_posts;
  Alcotest.(check int) "unframed creates fresh" 2 unframed_stats.create_count_total;
  Alcotest.(check int) "unframed never reuses" 0 unframed_stats.reuse_count_total;
  Alcotest.(check int) "unframed never parks" 0 unframed_stats.total_idle;
  let (http10_first, http10_second, http10_stats), http10_posts =
    exercise_raw_stream_cache ~http_version:"HTTP/1.0" ()
  in
  expect_stream_ok "HTTP/1.0 first" http10_first;
  expect_stream_ok "HTTP/1.0 second" http10_second;
  Alcotest.(check int) "HTTP/1.0 POSTs" 2 http10_posts;
  Alcotest.(check int) "HTTP/1.0 creates fresh" 2 http10_stats.create_count_total;
  Alcotest.(check int) "HTTP/1.0 never reuses" 0 http10_stats.reuse_count_total;
  Alcotest.(check int) "HTTP/1.0 never parks" 0 http10_stats.total_idle;
  let upgrade_headers length =
    [ Printf.sprintf "Content-Length: %d" length
    ; "Connection: upgrade"
    ; "Upgrade: websocket"
    ]
  in
  let (upgrade_first, upgrade_second, upgrade_stats), upgrade_posts =
    exercise_raw_stream_cache ~response_headers:upgrade_headers ()
  in
  expect_stream_ok "Upgrade first" upgrade_first;
  expect_stream_ok "Upgrade second" upgrade_second;
  Alcotest.(check int) "Upgrade POSTs" 2 upgrade_posts;
  Alcotest.(check int) "Upgrade creates fresh" 2 upgrade_stats.create_count_total;
  Alcotest.(check int) "Upgrade never reuses" 0 upgrade_stats.reuse_count_total;
  Alcotest.(check int) "Upgrade never parks" 0 upgrade_stats.total_idle;
  let truncated_length_headers length =
    [ Printf.sprintf "Content-Length: %d" (length + 3) ]
  in
  let (fixed_first, fixed_second, fixed_stats), fixed_posts =
    exercise_raw_stream_cache ~response_headers:truncated_length_headers ()
  in
  expect_stream_ok "truncated content-length first" fixed_first;
  expect_stream_ok "truncated content-length second" fixed_second;
  Alcotest.(check int) "truncated content-length POSTs" 2 fixed_posts;
  Alcotest.(check int)
    "truncated content-length creates fresh"
    2
    fixed_stats.create_count_total;
  Alcotest.(check int)
    "truncated content-length never reuses"
    0
    fixed_stats.reuse_count_total;
  Alcotest.(check int) "truncated content-length never parks" 0 fixed_stats.total_idle;
  let truncated_chunked_headers _ = [ "Transfer-Encoding: chunked" ] in
  let encode_truncated_chunk body = Printf.sprintf "5\r\n%s" body in
  let (chunked_first, chunked_second, chunked_stats), chunked_posts =
    exercise_raw_stream_cache
      ~response_headers:truncated_chunked_headers
      ~encode_body:encode_truncated_chunk
      ()
  in
  expect_stream_ok "truncated chunked first" chunked_first;
  expect_stream_ok "truncated chunked second" chunked_second;
  Alcotest.(check int) "truncated chunked POSTs" 2 chunked_posts;
  Alcotest.(check int)
    "truncated chunked creates fresh"
    2
    chunked_stats.create_count_total;
  Alcotest.(check int) "truncated chunked never reuses" 0 chunked_stats.reuse_count_total;
  Alcotest.(check int) "truncated chunked never parks" 0 chunked_stats.total_idle;
  let final_chunked_headers _ = [ "Transfer-Encoding: chunked" ] in
  let encode_final_chunk body =
    Printf.sprintf "%x\r\n%s\r\n0\r\n\r\n" (String.length body) body
  in
  let (final_first, final_second, final_stats), final_posts =
    exercise_raw_stream_cache
      ~response_headers:final_chunked_headers
      ~encode_body:encode_final_chunk
      ~keep_connection:true
      ()
  in
  expect_stream_ok "final chunked first" final_first;
  expect_stream_ok "final chunked second" final_second;
  Alcotest.(check int) "final chunked POSTs" 2 final_posts;
  Alcotest.(check int) "final chunked creates once" 1 final_stats.create_count_total;
  Alcotest.(check int) "final chunked reuses once" 1 final_stats.reuse_count_total;
  Alcotest.(check int) "final chunked remains parked" 1 final_stats.total_idle
;;

let expect_raw_ok label = function
  | Ok response ->
    Alcotest.(check int) (label ^ " status") 200 response.Http_client.status;
    Alcotest.(check string) (label ^ " body") "ok" response.body
  | Error _ -> Alcotest.fail (label ^ " expected raw 200 response")
;;

let test_one_dispatch_stale_cache_has_no_hidden_retry () =
  let (first, second, stats), posts = exercise_raw_one_dispatch_cache () in
  expect_raw_ok "stale setup" first;
  (match second with
   | Error (Http_client.Dispatch_started_error _) -> ()
   | Ok _ | Error _ ->
     Alcotest.fail "stale cached connection was retried or misclassified");
  Alcotest.(check int) "stale server sees one POST" 1 posts;
  Alcotest.(check int) "stale cache creates once" 1 stats.Http_client.create_count_total;
  Alcotest.(check int) "stale cache attempts once" 1 stats.reuse_count_total;
  Alcotest.(check int) "failed stale connection is not parked" 0 stats.total_idle
;;

let test_one_dispatch_connection_close_and_final_chunked () =
  let close_headers length =
    [ Printf.sprintf "Content-Length: %d" length; "Connection: close" ]
  in
  let (close_first, close_second, close_stats), close_posts =
    exercise_raw_one_dispatch_cache ~response_headers:close_headers ()
  in
  expect_raw_ok "connection-close first" close_first;
  expect_raw_ok "connection-close second" close_second;
  Alcotest.(check int) "connection-close POSTs" 2 close_posts;
  Alcotest.(check int) "connection-close creates fresh" 2 close_stats.create_count_total;
  Alcotest.(check int) "connection-close never reuses" 0 close_stats.reuse_count_total;
  Alcotest.(check int) "connection-close never parks" 0 close_stats.total_idle;
  let chunked_headers _ = [ "Transfer-Encoding: chunked" ] in
  let encode_chunked body =
    Printf.sprintf "%x\r\n%s\r\n0\r\n\r\n" (String.length body) body
  in
  let (chunked_first, chunked_second, chunked_stats), chunked_posts =
    exercise_raw_one_dispatch_cache
      ~response_headers:chunked_headers
      ~encode_body:encode_chunked
      ~keep_connection:true
      ()
  in
  expect_raw_ok "final-chunked first" chunked_first;
  expect_raw_ok "final-chunked second" chunked_second;
  Alcotest.(check int) "final-chunked POSTs" 2 chunked_posts;
  Alcotest.(check int) "final-chunked creates once" 1 chunked_stats.create_count_total;
  Alcotest.(check int) "final-chunked reuses once" 1 chunked_stats.reuse_count_total;
  Alcotest.(check int) "final-chunked remains parked" 1 chunked_stats.total_idle
;;

let test_one_dispatch_ambiguous_framing_quarantines_connection () =
  let cases =
    [ ( "Content-Length plus Transfer-Encoding"
      , fun length ->
          [ Printf.sprintf "Content-Length: %d" length; "Transfer-Encoding: identity" ] )
    ; ( "conflicting Content-Length"
      , fun length ->
          [ Printf.sprintf "Content-Length: %d" (length + 1)
          ; Printf.sprintf "Content-Length: %d" length
          ] )
    ; ("invalid Content-Length", fun _ -> [ "Content-Length: invalid" ])
    ; ("non-final chunked", fun _ -> [ "Transfer-Encoding: chunked, gzip" ])
    ; ("malformed chunked", fun _ -> [ "Transfer-Encoding: gzip,,chunked" ])
    ]
  in
  List.iter
    (fun (label, response_headers) ->
       let (first, second, stats), posts =
         exercise_raw_one_dispatch_cache ~response_headers ()
       in
       expect_raw_ok (label ^ " first") first;
       expect_raw_ok (label ^ " second") second;
       Alcotest.(check int) (label ^ " POSTs") 2 posts;
       Alcotest.(check int) (label ^ " creates fresh") 2 stats.create_count_total;
       Alcotest.(check int) (label ^ " never reuses") 0 stats.reuse_count_total;
       Alcotest.(check int) (label ^ " never parks") 0 stats.total_idle)
    cases
;;

let test_one_dispatch_http_1_0_and_upgrade_semantics () =
  let (http10_first, http10_second, http10_stats), http10_posts =
    exercise_raw_one_dispatch_cache ~http_version:"HTTP/1.0" ()
  in
  expect_raw_ok "HTTP/1.0 first" http10_first;
  expect_raw_ok "HTTP/1.0 second" http10_second;
  Alcotest.(check int) "HTTP/1.0 POSTs" 2 http10_posts;
  Alcotest.(check int) "HTTP/1.0 creates fresh" 2 http10_stats.create_count_total;
  Alcotest.(check int) "HTTP/1.0 never reuses" 0 http10_stats.reuse_count_total;
  Alcotest.(check int) "HTTP/1.0 never parks" 0 http10_stats.total_idle;
  let upgrade_headers length =
    [ Printf.sprintf "Content-Length: %d" length
    ; "Connection: upgrade"
    ; "Upgrade: websocket"
    ]
  in
  let (upgrade_first, upgrade_second, upgrade_stats), upgrade_posts =
    exercise_raw_one_dispatch_cache ~response_headers:upgrade_headers ()
  in
  expect_raw_ok "Upgrade 200 first" upgrade_first;
  expect_raw_ok "Upgrade 200 second" upgrade_second;
  Alcotest.(check int) "Upgrade POSTs" 2 upgrade_posts;
  Alcotest.(check int) "Upgrade creates fresh" 2 upgrade_stats.create_count_total;
  Alcotest.(check int) "Upgrade never reuses" 0 upgrade_stats.reuse_count_total;
  Alcotest.(check int) "Upgrade never parks" 0 upgrade_stats.total_idle;
  let switching_headers _ = [ "Connection: upgrade"; "Upgrade: websocket" ] in
  let (switch_first, switch_second, switch_stats), switch_posts =
    exercise_raw_one_dispatch_cache
      ~status:"101 Switching Protocols"
      ~response_headers:switching_headers
      ~response_body:""
      ()
  in
  let expect_response_received_101 label = function
    | Ok (response : Http_client.raw_sync_response) ->
      Alcotest.(check int) (label ^ " status") 101 response.status
    | Error _ -> Alcotest.fail (label ^ ": expected typed response-received result")
  in
  expect_response_received_101 "101 first" switch_first;
  expect_response_received_101 "101 second" switch_second;
  Alcotest.(check int) "101 POSTs" 2 switch_posts;
  Alcotest.(check int) "101 creates fresh" 2 switch_stats.create_count_total;
  Alcotest.(check int) "101 never reuses" 0 switch_stats.reuse_count_total;
  Alcotest.(check int) "101 never parks" 0 switch_stats.total_idle
;;

let test_one_dispatch_body_timeout_covers_response_headers () =
  let (outcome, stats), posts =
    with_raw_one_dispatch_server
      ~before_response:(fun ~clock ~request_index:_ -> Eio.Time.sleep clock 0.25)
      ~response_body:"ok"
    @@ fun ~sw ~net ~clock ~url ->
    let cache = Http_client.create_cache ~sw () in
    let outcome =
      Http_client.post_sync_once
        ~cache
        ~clock
        ~net
        ~url
        ~headers:[ "Content-Type", "application/json"; "Content-Length", "2" ]
        ~body:"{}"
        ~body_timeout_s:0.05
        ()
    in
    outcome, Http_client.cache_stats cache
  in
  (match outcome with
   | Error
       (Http_client.Dispatch_started_error
          (Http_client.TimeoutError { phase = Http_client.Wall_clock; _ })) -> ()
   | Ok _ -> Alcotest.fail "header stall: expected total body-timeout failure"
   | Error _ -> Alcotest.fail "header stall: timeout was reclassified");
  Alcotest.(check int) "header stall POSTs" 1 posts;
  Alcotest.(check int) "header stall creates once" 1 stats.create_count_total;
  Alcotest.(check int) "header stall never reuses" 0 stats.reuse_count_total;
  Alcotest.(check int) "header stall never parks" 0 stats.total_idle
;;

let test_one_dispatch_caller_cancellation_identity_and_cache () =
  let exception Caller_cancelled in
  let request_seen, notify_request_seen = Eio.Promise.create () in
  let (outcome, after_cancel, fresh, after_fresh), posts =
    with_raw_one_dispatch_server
      ~on_request:(fun ~request_index ->
        if request_index = 1 then resolve_once request_seen notify_request_seen)
      ~before_response:(fun ~clock ~request_index ->
        if request_index = 1 then Eio.Time.sleep clock 0.25)
      ~response_body:"ok"
    @@ fun ~sw ~net ~clock ~url ->
    let cache = Http_client.create_cache ~sw () in
    let post () =
      Http_client.post_sync_once
        ~cache
        ~net
        ~url
        ~headers:[ "Content-Type", "application/json"; "Content-Length", "2" ]
        ~body:"{}"
        ()
    in
    let cancel_context, notify_cancel_context = Eio.Promise.create () in
    let client_outcome, notify_client_outcome = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      let outcome =
        try
          `Returned
            (Eio.Cancel.sub
             @@ fun context ->
             Eio.Promise.resolve notify_cancel_context context;
             post ())
        with
        | Eio.Cancel.Cancelled Caller_cancelled -> `Cancelled
        | _ -> `Wrong_exception
      in
      Eio.Promise.resolve notify_client_outcome outcome);
    let context = await_promise ~clock ~label:"cancel context" cancel_context in
    await_promise ~clock ~label:"first request dispatch" request_seen;
    Eio.Cancel.cancel context Caller_cancelled;
    let outcome = await_promise ~clock ~label:"cancelled client outcome" client_outcome in
    let after_cancel = Http_client.cache_stats cache in
    let fresh = post () in
    outcome, after_cancel, fresh, Http_client.cache_stats cache
  in
  (match outcome with
   | `Cancelled -> ()
   | `Returned (Ok _) -> Alcotest.fail "caller cancellation returned success"
   | `Returned (Error _) ->
     Alcotest.fail "caller cancellation was reclassified as transport/timeout error"
   | `Wrong_exception -> Alcotest.fail "caller cancellation lost exception identity");
  Alcotest.(check int)
    "caller cancellation creates once"
    1
    after_cancel.create_count_total;
  Alcotest.(check int) "caller cancellation never reuses" 0 after_cancel.reuse_count_total;
  Alcotest.(check int) "caller cancellation never parks" 0 after_cancel.total_idle;
  expect_raw_ok "fresh request after caller cancellation" fresh;
  Alcotest.(check int) "caller cancellation plus fresh POSTs" 2 posts;
  Alcotest.(check int)
    "fresh request creates a new connection"
    2
    after_fresh.create_count_total;
  Alcotest.(check int)
    "cancelled connection was not reused"
    0
    after_fresh.reuse_count_total
;;

let () =
  Alcotest.run
    "HTTP Client Connection Cache"
    [ ( "reuse"
      , [ Alcotest.test_case
            "sync connection reused"
            `Quick
            test_complete_reuses_connection
        ; Alcotest.test_case
            "per-host cap closes excess"
            `Quick
            test_per_host_cap_closes_excess
        ] )
    ; ( "lifecycle"
      , [ Alcotest.test_case
            "eviction fiber closes idle"
            `Quick
            test_eviction_fiber_closes_idle
        ; Alcotest.test_case
            "cache switch releases idle connection"
            `Quick
            test_cache_switch_releases_idle_connection
        ; Alcotest.test_case
            "one-shot closes after response"
            `Quick
            test_one_shot_get_closes_after_response
        ; Alcotest.test_case
            "one-shot timeout closes connection"
            `Quick
            test_one_shot_get_timeout_closes_connection
        ] )
    ; ( "headers"
      , [ Alcotest.test_case
            "omits connection close"
            `Quick
            test_omits_connection_close_header
        ] )
    ; ( "stream"
      , [ Alcotest.test_case
            "reuses streaming connection"
            `Quick
            test_stream_reuses_connection
        ; Alcotest.test_case
            "cancellation closes connection"
            `Quick
            test_stream_cancellation_closes_connection
        ; Alcotest.test_case
            "typed error closes unconsumed connection"
            `Quick
            test_stream_typed_error_closes_unconsumed_connection
        ; Alcotest.test_case
            "connection-close stream is not parked"
            `Quick
            test_stream_connection_close_does_not_park
        ; Alcotest.test_case
            "response cache eligibility"
            `Quick
            test_stream_response_cache_eligibility
        ] )
    ; ( "validation"
      , [ Alcotest.test_case
            "create_cache rejects invalid params"
            `Quick
            test_create_cache_rejects_invalid_params
        ] )
    ; ( "one-dispatch framing"
      , [ Alcotest.test_case
            "stale cache has no hidden retry"
            `Quick
            test_one_dispatch_stale_cache_has_no_hidden_retry
        ; Alcotest.test_case
            "connection-close and final chunked"
            `Quick
            test_one_dispatch_connection_close_and_final_chunked
        ; Alcotest.test_case
            "ambiguous framing quarantines connection"
            `Quick
            test_one_dispatch_ambiguous_framing_quarantines_connection
        ; Alcotest.test_case
            "HTTP/1.0 and Upgrade semantics"
            `Quick
            test_one_dispatch_http_1_0_and_upgrade_semantics
        ; Alcotest.test_case
            "body timeout covers response headers"
            `Quick
            test_one_dispatch_body_timeout_covers_response_headers
        ; Alcotest.test_case
            "caller cancellation identity and cache"
            `Quick
            test_one_dispatch_caller_cancellation_identity_and_cache
        ] )
    ]
;;
