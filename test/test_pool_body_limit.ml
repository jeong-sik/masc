module Pool = Masc_http_client.Pool

let payload = "complete"
let limit = String.length payload

let with_runtime f () =
  Eio_main.run (fun env ->
    (* Same outer fixture deadline as the neighbouring actual pool tests. *)
    Eio.Time.with_timeout_exn env#clock 5.0 (fun () ->
      Eio.Switch.run (fun sw -> f env sw)))

(* Probe connections contain no HTTP. Completion is published after a real
   request's socket closes, so a refused body cannot leave a hidden client. *)
let start_server ~sw env respond =
  let listener = Eio.Net.listen ~sw ~backlog:8 env#net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let completed = Eio.Stream.create 1 in
  let requests = ref 0 in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec accept () =
      let handled = Eio.Switch.run (fun connection_sw ->
        let flow, _ = Eio.Net.accept ~sw:connection_sw listener in
        let reader = Eio.Buf_read.of_flow flow ~max_size:4096 in
        let handled = ref false in
        let rec headers () =
          if Eio.Buf_read.line reader <> "" then headers () in
        let rec request () =
          let _request_line = Eio.Buf_read.line reader in
          headers ();
          handled := true;
          incr requests;
          respond !requests flow;
          request () in
        (try request () with End_of_file -> ());
        !handled) in
      if handled then Eio.Stream.add completed ();
      accept () in
    accept ());
  let port = match Eio.Net.listening_addr listener with
    | `Tcp (_, port) -> port
    | `Unix _ -> Alcotest.fail "expected TCP listener" in
  Printf.sprintf "http://127.0.0.1:%d/body" port, completed, requests

let fixed_response ?(status = "200 OK") flow body =
  Eio.Flow.copy_string
    (Printf.sprintf "HTTP/1.1 %s\r\nContent-Length: %d\r\n\r\n%s"
       status (String.length body) body) flow

let require_response = function
  | Ok response -> response
  | Error detail -> Alcotest.fail detail

type oversized = Fixed | Chunked | Close_delimited

let test_oversized ?(status = 200) kind = with_runtime (fun env sw ->
  let oversized = payload ^ "!" in
  let url, completed, requests = start_server ~sw env (fun index flow ->
    if index > 1 then fixed_response flow payload
    else
      (* No body/end marker/EOF: refusal must precede whole-body completion. *)
      Eio.Flow.copy_string
        (match kind with
         | Fixed -> Printf.sprintf
             "HTTP/1.1 %d fixture\r\nContent-Length: %d\r\n\r\n"
             status (String.length oversized)
         | Chunked -> Printf.sprintf
             "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n%x\r\n%s\r\n"
             (String.length oversized) oversized
         | Close_delimited ->
             "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n" ^ oversized)
        flow) in
  let pool = Pool.create ~sw ~env () in
  (match Pool.request pool ~max_body_bytes:limit ~method_:`GET ~url () with
   | Ok _ -> Alcotest.fail "oversized response was returned as success"
   | Error message ->
     Alcotest.(check string) "receive refusal names its bound"
       (Printf.sprintf "HTTP %d: body exceeds %d bytes" status limit) message);
  Eio.Stream.take completed;
  Alcotest.(check int) "partial connection was not parked" 0
    (Pool.stats pool).total_idle;
  let response = Pool.request pool ~max_body_bytes:limit ~method_:`GET ~url ()
      |> require_response in
  Alcotest.(check string) "subsequent complete response" payload response.body;
  Alcotest.(check int) "a new connection replaces the refused one" 2
    (Pool.stats pool).create_count_total;
  Alcotest.(check int) "no hidden replay" 2 !requests;
  Pool.shutdown pool;
  Eio.Stream.take completed)

let test_complete_and_http_error = with_runtime (fun env sw ->
  let url, completed, requests = start_server ~sw env (fun index flow ->
    fixed_response ~status:(if index = 1 then "200 OK" else "503 Unavailable")
      flow payload) in
  let pool = Pool.create ~sw ~env () in
  List.iter (fun status ->
    let response = Pool.request pool ~max_body_bytes:limit ~method_:`GET ~url ()
        |> require_response in
    Alcotest.(check int) "original HTTP status" status response.status;
    Alcotest.(check string) "exact-bound body preserved" payload response.body)
    [200; 503];
  Alcotest.(check int) "complete connection remains reusable" 1
    (Pool.stats pool).reuse_count_total;
  Alcotest.(check int) "one request per response" 2 !requests;
  Pool.shutdown pool;
  Eio.Stream.take completed)

let test_unlimited_default = with_runtime (fun env sw ->
  let body = payload ^ "!" in
  let url, completed, _ = start_server ~sw env (fun _ flow -> fixed_response flow body) in
  let pool = Pool.create ~sw ~env () in
  let response = Pool.request pool ~method_:`GET ~url () |> require_response in
  Alcotest.(check string) "omitting the bound keeps the full response" body response.body;
  Pool.shutdown pool;
  Eio.Stream.take completed)

let test_cancellation_closes_partial_body = with_runtime (fun env sw ->
  let body_started, start_body = Eio.Promise.create () in
  let url, completed, _ = start_server ~sw env (fun _ flow ->
    Eio.Flow.copy_string
      (Printf.sprintf "HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\nx" limit) flow;
    Eio.Promise.resolve start_body ()) in
  let pool = Pool.create ~sw ~env () in
  let request_scope, give_scope = Eio.Promise.create () in
  let cancelled = ref false in
  let exception Fixture_cancel in
  Eio.Fiber.both
    (fun () ->
      try
        Eio.Cancel.sub (fun context ->
          Eio.Promise.resolve give_scope context;
          try
            let _result = Pool.request pool ~max_body_bytes:limit ~method_:`GET ~url () in
            Alcotest.fail "cancelled partial response became a result"
          with Eio.Cancel.Cancelled Fixture_cancel -> cancelled := true)
      with Eio.Cancel.Cancelled Fixture_cancel when !cancelled -> ())
    (fun () ->
      Eio.Promise.await body_started;
      Eio.Cancel.cancel (Eio.Promise.await request_scope) Fixture_cancel);
  Eio.Stream.take completed;
  Alcotest.(check bool) "caller cancellation propagated" true !cancelled;
  Alcotest.(check int) "cancelled connection was closed" 0 (Pool.stats pool).total_idle;
  Alcotest.(check int) "no request remains in flight" 0 (Pool.stats pool).total_inflight;
  Pool.shutdown pool)

let () =
  Alcotest.run "Pool response body limit"
    [ "real HTTP", [
        Alcotest.test_case "fixed length refused before body" `Quick (test_oversized Fixed)
      ; Alcotest.test_case "oversized HTTP error keeps status" `Quick (test_oversized ~status:503 Fixed)
      ; Alcotest.test_case "chunked body refused before end" `Quick (test_oversized Chunked)
      ; Alcotest.test_case "close-delimited body refused before EOF" `Quick (test_oversized Close_delimited)
      ; Alcotest.test_case "exact limit and HTTP failure preserve status/body" `Quick test_complete_and_http_error
      ; Alcotest.test_case "omission adds no default bound" `Quick test_unlimited_default
      ; Alcotest.test_case "cancellation closes partial body" `Quick test_cancellation_closes_partial_body
      ] ]
