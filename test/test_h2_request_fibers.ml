open Alcotest
module Helpers = Server_h2_gateway_helpers

type dispatch = Inline_reader | Request_fibers

let with_connection dispatch handler run =
  Eio_main.run (fun env ->
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
      Eio.Switch.run (fun sw ->
        let pool = Domain_pool.create ~sw ~domain_count:1 env#domain_mgr in
        let previous = Domain_pool_ref.get () in
        Eio.Switch.on_release sw (fun () ->
          match previous with
          | None -> Domain_pool_ref.clear_for_tests ()
          | Some pool -> Domain_pool_ref.set pool);
        Domain_pool_ref.set pool;
        Executor_pool_ref.For_testing.with_pool (Domain_pool.executor_pool pool) (fun () ->
          let occupied, occupy = Eio.Promise.create () in
          let released, release_worker = Eio.Promise.create () in
          let release () =
            if not (Eio.Promise.is_resolved released) then Eio.Promise.resolve release_worker () in
          Eio.Switch.on_release sw release;
          Eio.Fiber.fork ~sw (fun () ->
            Domain_pool_ref.submit_cpu_or_inline (fun () ->
              Eio.Promise.resolve occupy ();
              Eio.Promise.await released));
          Eio.Promise.await occupied;
          let server_flow, client_flow = Eio_unix.Net.socketpair_stream ~sw () in
          let server = Eio.Fiber.fork_promise ~sw (fun () ->
            Eio.Switch.run (fun conn_sw ->
              let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 54321) in
              let error_handler = Server_h2_gateway.make_error_handler () in
              match dispatch with
              | Inline_reader ->
                H2_eio.Server.create_connection_handler ~sw:conn_sw
                  ~request_handler:(handler ~request_sw:conn_sw) ~error_handler addr server_flow
              | Request_fibers ->
                Server_bootstrap_http.serve_h2_connection ~sw:conn_sw
                  ~h2_request_handler:handler ~h2_error_handler:error_handler addr server_flow)) in
          let closing = ref false in
          let client = H2_eio.Client.create_connection ~sw
            ~config:{ H2.Config.default with initial_window_size = 65535l }
            ~error_handler:(fun _ -> if not !closing then fail "unexpected H2 connection error")
            client_flow in
          let close_client () =
            if not !closing then (
              closing := true;
              Eio.Flow.close client_flow) in
          run ~env ~client ~client_flow ~release ~close_client ~server;
          release ();
          close_client ();
          Eio.Promise.await_exn server))))

let open_request ?(meth = `GET) client path =
  let reply, resolve = Eio.Promise.create () in
  let request = H2.Request.create ~scheme:"http" meth path
    ~headers:(H2.Headers.of_list
      [":authority", "localhost"; "accept-encoding", "gzip"]) in
  let writer = H2_eio.Client.request client ~flush_headers_immediately:true request
    ~error_handler:(fun _ ->
      if not (Eio.Promise.is_resolved reply) then Eio.Promise.resolve resolve (Error ()))
    ~response_handler:(fun response reader ->
      let bytes = Buffer.create 256 in
      let rec read () = H2.Body.Reader.schedule_read reader
        ~on_eof:(fun () -> Eio.Promise.resolve resolve
          (Ok (H2.Status.to_code response.status, Buffer.contents bytes)))
        ~on_read:(fun chunk ~off ~len ->
          Buffer.add_string bytes (Bigstringaf.substring chunk ~off ~len);
          read ()) in
      read ()) in
  writer, reply

let send_body writer body =
  H2.Body.Writer.write_string writer body;
  H2.Body.Writer.flush writer (fun _ -> H2.Body.Writer.close writer)

let request ?(meth = `GET) ?(body = "") client path =
  let writer, reply = open_request ~meth client path in
  send_body writer body;
  reply

let await_reply reply =
  match Eio.Promise.await reply with
  | Ok response -> response
  | Error () -> fail "H2 stream failed before its response"

let ping client =
  match Eio.Promise.await (H2_eio.Client.ping client) with
  | Ok () -> ()
  | Error `EOF -> fail "connection closed instead of acknowledging PING"

let large_json = `Assoc ["text", `String (String.make 20000 'x')]
let flow_control_body = String.make (2 * 65535) 'w'

let test_reader_control () =
  let admitted, admit = Eio.Promise.create () in
  let handler ~request_sw:_ _ reqd =
    Eio.Promise.resolve admit ();
    Helpers.h2_respond_json_value_on_cpu reqd large_json in
  with_connection Inline_reader handler (fun ~env ~client ~client_flow:_ ~release ~close_client:_ ~server:_ ->
    let slow = request client "/slow" in
    Eio.Promise.await admitted;
    let acknowledged = H2_eio.Client.ping client in
    (* Admission is already waiting on a worker held by this fixture. The
       bounded observation is a baseline reproduction, not a latency gate. *)
    let observed = Eio.Time.with_timeout (Eio.Stdenv.clock env) 0.05
      (fun () -> Ok (Eio.Promise.await acknowledged)) in
    check bool "direct reader cannot acknowledge PING while waiting for CPU" true
      (match observed with Error `Timeout -> true | Ok _ -> false);
    release ();
    ignore (await_reply slow);
    check bool "PING recovers after releasing CPU" true
      (match Eio.Promise.await acknowledged with Ok () -> true | Error `EOF -> false);
    Printf.printf "H2_READER_CONTROL ping_blocked_with_occupied_worker=true\n%!")

let test_multiplexed_progress meth =
  let admitted, admit = Eio.Promise.create () in
  let reader_ready, mark_reader_ready = Eio.Promise.create () in
  let handler ~request_sw:sw _ reqd =
    match (H2.Reqd.request reqd).target with
    | "/slow" ->
      let respond () =
        Eio.Promise.resolve admit ();
        match meth with
        | `GET -> Helpers.h2_respond_json_value_on_cpu reqd large_json
        | `POST -> Helpers.h2_respond_json reqd (Yojson.Safe.to_string large_json) in
      (match meth with
       | `GET -> respond ()
       | `POST ->
           Helpers.h2_read_body ~sw reqd (fun body ->
             check string "POST callback receives complete input" "request body" body;
             respond ());
           Eio.Promise.resolve mark_reader_ready ())
    | "/fast" -> Helpers.h2_respond_json ~compress:false reqd flow_control_body
    | path -> failf "unexpected path %s" path in
  with_connection Request_fibers handler (fun ~env ~client ~client_flow:_ ~release ~close_client:_ ~server:_ ->
    let slow =
      match meth with
      | `GET -> request client "/slow"
      | `POST ->
          (* Do not send DATA until the route has registered its body reader.
             A prebuffered body would invoke EOF inside the request fiber and
             could hide a missing body-completion dispatcher. *)
          let writer, reply = open_request ~meth client "/slow" in
          Eio.Promise.await reader_ready;
          send_body writer "request body";
          reply
    in
    Eio.Promise.await admitted;
    let started = Eio.Time.Mono.now (Eio.Stdenv.mono_clock env) in
    ping client;
    let elapsed = Mtime.Span.to_float_ns
      (Mtime.span started (Eio.Time.Mono.now (Eio.Stdenv.mono_clock env))) /. 1e6 in
    let status, body = await_reply (request client "/fast") in
    check int "sibling stream completes while CPU stays occupied" 200 status;
    check string "WINDOW_UPDATE delivers two initial windows" flow_control_body body;
    check bool "slow response is still queued" false (Eio.Promise.is_resolved slow);
    Printf.printf "H2_REQUEST_FIBERS method=%s occupied_worker_ping_ms=%.6f sibling_bytes=%d\n%!"
      (match meth with `GET -> "GET" | `POST -> "POST") elapsed (String.length body);
    release ();
    check int "slow response resumes after release" 200 (fst (await_reply slow)))

let test_reset_does_not_break_siblings () =
  let admitted, admit = Eio.Promise.create () in
  let finished, finish = Eio.Promise.create () in
  let handler ~request_sw:_ _ reqd =
    match (H2.Reqd.request reqd).target with
    | "/slow" ->
      Eio.Promise.resolve admit ();
      Fun.protect ~finally:(fun () -> Eio.Promise.resolve finish ()) (fun () ->
        Helpers.h2_respond_json_value_on_cpu reqd large_json)
    | "/fast" -> Helpers.h2_respond_json ~compress:false reqd "alive"
    | path -> failf "unexpected path %s" path in
  with_connection Request_fibers handler (fun ~env:_ ~client ~client_flow ~release ~close_client:_ ~server:_ ->
    let slow = request client "/slow" in
    Eio.Promise.await admitted;
    ping client;
    (* RFC 9113 RST_STREAM: 4-byte payload, stream 1 (the first request),
       CANCEL = 8. The PING before/after brackets this raw control frame. *)
    Eio.Flow.copy_string "\000\000\004\003\000\000\000\000\001\000\000\000\008" client_flow;
    ping client;
    check string "reset does not stall sibling" "alive"
      (snd (await_reply (request client "/fast")));
    release ();
    Eio.Promise.await finished;
    ping client;
    check bool "reset stream receives no delayed response" false
      (Eio.Promise.is_resolved slow))

let test_connection_closes_pending_work () =
  let admitted, admit = Eio.Promise.create () in
  let cancelled, mark_cancelled = Eio.Promise.create () in
  let child_started, start_child = Eio.Promise.create () in
  let child_cancelled, cancel_child = Eio.Promise.create () in
  let handler ~request_sw:sw _ reqd =
    match (H2.Reqd.request reqd).target with
    | "/slow" ->
      Eio.Promise.resolve admit ();
      (try
         Helpers.h2_respond_json_value_on_cpu reqd large_json;
         fail "worker unexpectedly admitted disconnected request"
       with Eio.Cancel.Cancelled _ as exn ->
         Eio.Promise.resolve mark_cancelled ();
         raise exn)
    | "/child" ->
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Promise.resolve start_child ();
        try Eio.Fiber.await_cancel () with Eio.Cancel.Cancelled _ as exn ->
          Eio.Promise.resolve cancel_child ();
          raise exn);
      Helpers.h2_respond_json ~compress:false reqd "started"
    | path -> failf "unexpected path %s" path in
  with_connection Request_fibers handler (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client ~server ->
    ignore (request client "/slow");
    Eio.Promise.await admitted;
    ignore (await_reply (request client "/child"));
    Eio.Promise.await child_started;
    close_client ();
    (* CPU remains occupied. Connection completion must cancel both the
       queued response and a normal child fiber, not wait for their work. *)
    Eio.Promise.await_exn server;
    Eio.Promise.await cancelled;
    Eio.Promise.await child_cancelled)

let test_handler_error_is_stream_local () =
  let handler ~request_sw:_ _ reqd =
    match (H2.Reqd.request reqd).target with
    | "/fail" -> failwith "fixture handler failure"
    | "/fast" -> Helpers.h2_respond_json ~compress:false reqd "alive"
    | path -> failf "unexpected path %s" path in
  with_connection Request_fibers handler (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    check int "handler exception becomes stream 500" 500
      (fst (await_reply (request client "/fail")));
    ping client;
    check string "sibling survives handler exception" "alive"
      (snd (await_reply (request client "/fast"))))

let () = run "H2 request fibers" ["connection progress", [
  test_case "direct reader reproduces occupied CPU stall" `Quick test_reader_control;
  test_case "GET preserves PING and WINDOW_UPDATE" `Quick (fun () -> test_multiplexed_progress `GET);
  test_case "POST completion preserves PING and WINDOW_UPDATE" `Quick (fun () -> test_multiplexed_progress `POST);
  test_case "RST_STREAM isolates delayed response" `Quick test_reset_does_not_break_siblings;
  test_case "disconnect cancels requests and child fibers" `Quick test_connection_closes_pending_work;
  test_case "handler failure stays on its stream" `Quick test_handler_error_is_stream_local;
]]
