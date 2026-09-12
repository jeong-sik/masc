module Pool = Masc_http_client.Pool

type request_mode = Buffered_request | Streaming_request

let request mode pool ~clock ~url ~headers ~responses ~chunks =
  match mode with
  | Buffered_request ->
    (* No request timeout: a failed client scope must settle this wait. *)
    Pool.request pool ~method_:`POST ~url ~headers ~body:"request" ()
  | Streaming_request ->
    Pool.request_streaming pool ~clock ~idle_timeout_sec:30.0
      ~method_:`POST ~url ~headers ~body:"request"
      ~on_response:(fun ~status:_ ~headers:_ -> incr responses)
      ~on_chunk:(fun chunk -> chunks := chunk :: !chunks) ()
    |> Result.map (function
      | Pool.Streamed { response; _ } | Pool.Buffered response -> response)

let start_server ~sw ~net requests =
  let listener = Eio.Net.listen ~sw ~backlog:8 net
    (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let callback _ request body =
    let body = Eio.Buf_read.(of_flow ~max_size:4096 body |> take_all) in
    requests := (Cohttp.Request.resource request, body) :: !requests;
    Cohttp_eio.Server.respond_string ~status:`OK ~body:"healthy" ()
  in
  let server = Cohttp_eio.Server.make ~callback () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run listener server ~on_error:raise);
  match Eio.Net.listening_addr listener with
  | `Tcp (_, port) -> Printf.sprintf "http://127.0.0.1:%d/request" port
  | `Unix _ -> Alcotest.fail "expected a TCP listener"

let test_failed_scope mode () =
  Eio_main.run (fun env ->
    (* This is a fixture deadline, outside every pool API. In particular the
       streaming idle timer cannot rescue a blocked response-header wait. *)
    try
      Eio.Time.with_timeout_exn env#clock 5.0 (fun () ->
        Eio.Switch.run (fun sw ->
          let requests = ref [] in
          let url = start_server ~sw ~net:env#net requests in
          let pool = Pool.create ~sw ~env () in
          let responses = ref 0 in
          let chunks = ref [] in
          let send headers =
            request mode pool ~clock:env#clock ~url ~headers ~responses ~chunks
          in
          (* httpun rejects this before enqueueing the request. Piaf's sending
             fiber fails, leaving no queued response callback to settle its
             caller. The pool must observe its owned client scope instead. *)
          let failure = send [ "content-length", "-1" ] in
          (match failure with
           | Ok _ -> Alcotest.fail "invalid body length unexpectedly succeeded"
           | Error message ->
             Alcotest.(check string) "original sending-fiber failure is returned"
               (Printexc.to_string
                  (Failure "httpun.Client_connection.request: invalid body length"))
               message);
          Alcotest.(check int) "invalid request never reached the server" 0
            (List.length !requests);
          Alcotest.(check int) "failed headers never notified the caller" 0 !responses;
          Alcotest.(check (list string)) "failed request delivered no chunks" [] !chunks;
          let failed_stats = Pool.stats pool in
          Alcotest.(check int) "failed client is not idle" 0 failed_stats.total_idle;
          Alcotest.(check int) "failed header wait is no longer in flight" 0
            failed_stats.total_inflight;
          Alcotest.(check int) "failure occurred after client creation" 1
            failed_stats.create_count_total;
          for _ = 1 to 2 do
            match send [] with
            | Error message -> Alcotest.failf "pool did not recover: %s" message
            | Ok response ->
              Alcotest.(check int) "later valid response status" 200 response.status;
              Alcotest.(check string) "later valid response body" "healthy" response.body
          done;
          Alcotest.(check (list (pair string string)))
            "only the two valid requests were dispatched"
            [ "/request", "request"; "/request", "request" ] !requests;
          let recovered_stats = Pool.stats pool in
          Alcotest.(check int) "recovery creates a replacement client" 2
            recovered_stats.create_count_total;
          Alcotest.(check int) "replacement client remains reusable" 1
            recovered_stats.reuse_count_total;
          Alcotest.(check int) "only the replacement is parked" 1
            recovered_stats.total_idle;
          (match mode with
           | Buffered_request -> ()
           | Streaming_request ->
             Alcotest.(check int) "both valid responses reached the caller" 2 !responses;
             Alcotest.(check string) "both valid bodies reached the chunk callback"
               "healthyhealthy" (String.concat "" (List.rev !chunks)));
          Pool.shutdown pool))
    with Eio.Time.Timeout ->
      Alcotest.fail "outer fixture deadline expired: the failed client scope did not settle its caller")

let () =
  Alcotest.run "Pool scope failure"
    [ "real HTTP/1",
      [ Alcotest.test_case "buffered request observes sending-fiber failure" `Quick
          (test_failed_scope Buffered_request)
      ; Alcotest.test_case "streaming headers observe sending-fiber failure" `Quick
          (test_failed_scope Streaming_request)
      ]
    ]
