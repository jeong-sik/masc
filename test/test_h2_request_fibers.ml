open Alcotest
module Response = Masc.Http_server_eio.Response
module Request = Masc.Http_server_eio.Request
module Stream_end = Masc.Http_h2_stream.Stream_end
module Response_body = Masc.Http_h2_stream.Response_body

let reqd_of_h2 ~stream_end h2_reqd =
  Masc.Http_reqd.of_h2 ~stream_end
    ~ledger:(Masc.Http_h2_response_ledger.current_exn ()) h2_reqd

let stalled_after_s = Server_mcp_transport_http_headers.sse_stalled_after_s

(* A registry on a mock clock: its response flushes stall only when a test
   moves that clock past the bound. *)
let registry ?(clock = Eio_mock.Clock.make ()) () =
  Server_h2_stream_registry.create ~clock ~stalled_after_s ()

type dispatch = Inline_reader | Request_fibers

(* The server's end of the connection. With a [pace] the peer takes [chunk]
   bytes at once and [chunk] more every [interval] seconds of [clock]: a
   slow link. A write the allowance does not cover waits for the clock.
   Reads pass through. *)
module Server_socket = struct
  type pace =
    { clock : float Eio.Time.clock_ty Eio.Resource.t
    ; chunk : int
    ; interval : float
    }

  type tag = [ `Generic ]

  type t =
    { flow : [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t
    ; pace : pace option
    ; mutable allowance : int
    ; mutable refill_at : float
    }

  let read_methods = []
  let single_read t dst = Eio.Flow.single_read t.flow dst

  let rec first_bytes n = function
    | [] -> []
    | buf :: rest ->
      if Cstruct.length buf >= n
      then [ Cstruct.sub buf 0 n ]
      else buf :: first_bytes (n - Cstruct.length buf) rest

  let rec single_write t bufs =
    match t.pace with
    | None -> Eio.Flow.single_write t.flow bufs
    | Some pace ->
      if t.allowance = 0
      then (
        Eio.Time.sleep_until pace.clock t.refill_at;
        t.allowance <- pace.chunk;
        t.refill_at <- t.refill_at +. pace.interval;
        single_write t bufs)
      else (
        let written = Eio.Flow.single_write t.flow (first_bytes t.allowance bufs) in
        t.allowance <- t.allowance - written;
        written)

  let copy t ~src = Eio.Flow.Pi.simple_copy ~single_write t ~src
  let shutdown t command = Eio.Flow.shutdown t.flow command
  let close t = Eio.Flow.close t.flow
end

let server_socket_handler = Eio.Net.Pi.stream_socket (module Server_socket)

let server_socket ?pace (flow : _ Eio.Net.stream_socket) =
  let chunk, refill_at =
    match pace with
    | None -> 0, 0.0
    | Some (pace : Server_socket.pace) ->
      pace.chunk, Eio.Time.now pace.clock +. pace.interval in
  Eio.Resource.T
    ( { Server_socket.flow = (flow :> [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t)
      ; pace
      ; allowance = chunk
      ; refill_at
      }
    , server_socket_handler )

let with_connection ?streams ?resources ?(client_window = 65535l) ?pace dispatch handler run =
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
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
            Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
              Eio.Promise.resolve occupy ();
              Eio.Promise.await released));
          Eio.Promise.await occupied;
          let server_flow, client_flow = Eio_unix.Net.socketpair_stream ~sw () in
          let server_flow = server_socket ?pace server_flow in
          let server = Eio.Fiber.fork_promise ~sw (fun () ->
            Eio.Switch.run (fun conn_sw ->
              let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 54321) in
              let error_handler = Server_h2_gateway.make_error_handler () in
              match dispatch with
              | Inline_reader ->
                let resources = Masc.Http_h2_response_ledger.create
                  ~max_pending_bytes:H2_response_limits.default_max_pending_bytes in
                H2_eio.Server.create_connection_handler ~sw:conn_sw
                  ~request_handler:(fun client_addr reqd ->
                    Masc.Http_h2_response_ledger.with_request resources ~sw:conn_sw
                      (fun () ->
                        let stream_end =
                          Stream_end.create ~stream_sw:conn_sw ~clock ~stalled_after_s
                            ~request:(H2.Reqd.request reqd) reqd in
                        handler ~stream_end client_addr reqd))
                  ~error_handler addr server_flow
              | Request_fibers ->
                Server_bootstrap_http.serve_h2_connection ~clock ?streams ?resources ~sw:conn_sw
                  ~h2_request_handler:handler ~h2_error_handler:error_handler addr server_flow)) in
          let closing = ref false in
          let client = H2_eio.Client.create_connection ~sw
            ~config:{ H2.Config.default with initial_window_size = client_window }
            ~error_handler:(fun _ -> if not !closing then fail "unexpected H2 connection error")
            client_flow in
          (* The H2 client's reader fiber always has a read in flight on
             [client_flow]. Eio defers close(2) until that read finishes, so
             closing would never reach the server. shutdown reaches the peer
             at once and ends the in-flight read; [sw] closes the FD. *)
          let close_client () =
            if not !closing then (
              closing := true;
              Eio.Flow.shutdown client_flow `All) in
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
      (* h2 also ends the body of a stream the server reset, before it
         calls [error_handler]; only [Complete] is a whole response. *)
      let rec read () = H2.Body.Reader.schedule_read reader
        ~on_eof:(fun () ->
          match H2.Body.Reader.completion reader with
          | H2.Body.Reader.Complete -> Eio.Promise.resolve resolve
            (Ok (H2.Status.to_code response.status, Buffer.contents bytes))
          | H2.Body.Reader.Aborted -> Eio.Promise.resolve resolve (Error ())
          | H2.Body.Reader.Pending -> fail "response body ended while still pending")
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

(* Runs [run] with the console sink captured. [run] gets [logged], the
   number of captured lines naming a text. *)
let with_log_capture run =
  let lines = ref [] in
  let logged text =
    List.length (List.filter (fun line -> String_util.contains_substring line text) !lines) in
  Console_sink.For_testing.reset ();
  Console_sink.For_testing.set_writer (Some (fun line -> lines := line :: !lines));
  Fun.protect ~finally:Console_sink.For_testing.reset (fun () -> run logged)

let large_json = `Assoc ["text", `String (String.make 20000 'x')]
let flow_control_body = String.make (2 * 65535) 'w'

let test_reader_control () =
  let admitted, admit = Eio.Promise.create () in
  let handler ~stream_end _ reqd =
    Eio.Promise.resolve admit ();
    Response.json_value_on_cpu large_json (reqd_of_h2 ~stream_end reqd) in
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
  let handler ~stream_end _ h2_reqd =
    let reqd = reqd_of_h2 ~stream_end h2_reqd in
    match (H2.Reqd.request h2_reqd).target with
    | "/slow" ->
      let respond () =
        Eio.Promise.resolve admit ();
        match meth with
        | `GET -> Response.json_value_on_cpu large_json reqd
        | `POST -> Response.json (Yojson.Safe.to_string large_json) reqd in
      (match meth with
       | `GET -> respond ()
       | `POST ->
           Request.read_body_async reqd (fun body ->
             check string "POST callback receives complete input" "request body" body;
             respond ());
           Eio.Promise.resolve mark_reader_ready ())
    | "/fast" -> Response.json ~compress:false flow_control_body reqd
    | path -> failf "unexpected path %s" path in
  with_connection Request_fibers handler (fun ~env ~client ~client_flow:_ ~release ~close_client:_ ~server:_ ->
    let slow =
      match meth with
      | `GET -> request client "/slow"
      | `POST ->
          (* Do not send DATA until the route has registered its body reader.
             A prebuffered body would invoke EOF inside the request fiber and
             could hide a missing body-completion dispatcher. *)
          let writer, reply = open_request ~meth:`POST client "/slow" in
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
  let handler ~stream_end _ h2_reqd =
    let reqd = reqd_of_h2 ~stream_end h2_reqd in
    match (H2.Reqd.request h2_reqd).target with
    | "/slow" ->
      Eio.Promise.resolve admit ();
      Fun.protect ~finally:(fun () -> Eio.Promise.resolve finish ()) (fun () ->
        Response.json_value_on_cpu large_json reqd)
    | "/fast" -> Response.json ~compress:false "alive" reqd
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

(* RFC 9113 RST_STREAM with CANCEL (0x8) for one client stream. *)
let rst_stream_frame stream_id =
  let frame = Bytes.of_string "\000\000\004\003\000\000\000\000\000\000\000\000\008" in
  Bytes.set_int32_be frame 5 (Int32.of_int stream_id);
  Bytes.to_string frame

let test_reset_releases_stream_scopes () =
  let held_streams = 32 in
  let streams = registry () in
  let admitted = ref 0 and cancelled = ref 0 in
  let all_admitted, admit_all = Eio.Promise.create () in
  let all_cancelled, cancel_all = Eio.Promise.create () in
  let handler ~stream_end _ h2_reqd =
    match (H2.Reqd.request h2_reqd).target with
    | "/hold" ->
      incr admitted;
      if !admitted = held_streams then Eio.Promise.resolve admit_all ();
      (try Eio.Fiber.await_cancel () with Eio.Cancel.Cancelled _ as exn ->
         incr cancelled;
         if !cancelled = held_streams then Eio.Promise.resolve cancel_all ();
         raise exn)
    | "/fast" -> Response.json ~compress:false "alive" (reqd_of_h2 ~stream_end h2_reqd)
    | path -> failf "unexpected path %s" path in
  with_connection ~streams Request_fibers handler
    (fun ~env:_ ~client ~client_flow ~release:_ ~close_client:_ ~server:_ ->
    (* The client numbers its streams 1, 3, 5, ... in request order. *)
    let stream_ids = List.init held_streams (fun index ->
      ignore (request client "/hold");
      (2 * index) + 1) in
    Eio.Promise.await all_admitted;
    check int "every held request owns a stream scope" held_streams
      (Server_h2_stream_registry.active_streams streams);
    List.iter (fun stream_id -> Eio.Flow.copy_string (rst_stream_frame stream_id) client_flow)
      stream_ids;
    (* PING is read after every RST_STREAM, so its ACK proves they were seen. *)
    ping client;
    check int "reset streams leave no scope behind" 0
      (Server_h2_stream_registry.active_streams streams);
    Eio.Promise.await all_cancelled;
    check int "every reset stream cancelled its work" held_streams !cancelled;
    check string "connection keeps serving after the resets" "alive"
      (snd (await_reply (request client "/fast"))))

(* RFC 9113 DATA frame with END_STREAM and a one-byte payload for one client
   stream. On a stream that is already half-closed (remote) it is a stream
   error of type STREAM_CLOSED, which h2 answers with RST_STREAM by itself
   (RFC 9113 §6.1). *)
let closing_data_frame stream_id =
  let frame = Bytes.of_string "\000\000\001\000\001\000\000\000\000x" in
  Bytes.set_int32_be frame 5 (Int32.of_int stream_id);
  Bytes.to_string frame

let test_reset_sent_ends_stream_scope () =
  let streams = registry () in
  let held, hold = Eio.Promise.create () in
  let ended, record_end = Eio.Promise.create () in
  let handler ~stream_end _ h2_reqd =
    match (H2.Reqd.request h2_reqd).target with
    | "/hold" ->
      Eio.Promise.resolve hold ();
      (try Eio.Fiber.await_cancel () with
       | Eio.Cancel.Cancelled (Masc.Http_h2_stream.Stream_reset cause) as exn ->
         Eio.Promise.resolve record_end cause;
         raise exn)
    | "/fast" -> Response.json ~compress:false "alive" (reqd_of_h2 ~stream_end h2_reqd)
    | path -> failf "unexpected path %s" path in
  with_connection ~streams Request_fibers handler
    (fun ~env:_ ~client ~client_flow ~release:_ ~close_client:_ ~server:_ ->
    let reply = request client "/hold" in
    Eio.Promise.await held;
    (* Whichever of these two frames, or the client's own END_STREAM, arrives
       second lands on a half-closed stream. masc reports nothing here; the
       RST_STREAM is h2's own. *)
    Eio.Flow.copy_string (closing_data_frame 1 ^ closing_data_frame 1) client_flow;
    check bool "the scope ended because h2 wrote RST_STREAM" true
      (match Eio.Promise.await ended with
       | Masc.Http_h2_stream.Reset_by_us -> true
       | _ -> false);
    check bool "the client saw its stream reset" true
      (Result.is_error (Eio.Promise.await reply));
    ping client;
    check int "the reset stream leaves no scope behind" 0
      (Server_h2_stream_registry.active_streams streams);
    check string "connection keeps serving after the reset" "alive"
      (snd (await_reply (request client "/fast"))))

(* A handler that fails after its headers went out ends at the catch site in
   [serve_h2_connection]. Its body producer, forked on the stream switch, is
   cancelled with the handler's own exception; the bytes it reserved and never
   flushed go back to the ledger; the client sees its stream reset. No error
   handler answers a started response, so the reset logs the failure, once. *)
let test_failure_after_headers_releases_the_stream () =
  let streams = registry () in
  let resources = Masc.Http_h2_response_ledger.create
    ~max_pending_bytes:H2_response_limits.default_max_pending_bytes in
  let partial = "partial" in
  let failure = "fixture failure after the headers" in
  let reserved = ref 0 in
  let ended, record_end = Eio.Promise.create () in
  let handler ~stream_end _ h2_reqd =
    let reqd = reqd_of_h2 ~stream_end h2_reqd in
    match (H2.Reqd.request h2_reqd).target with
    | "/partial" ->
      Eio.Fiber.fork ~sw:(Stream_end.switch stream_end) (fun () ->
        try Eio.Fiber.await_cancel () with
        | Eio.Cancel.Cancelled (Masc.Http_h2_stream.Stream_reset cause) as exn ->
          Eio.Promise.resolve record_end cause;
          raise exn);
      let writer = Masc.Http_reqd.respond_with_streaming ~flush_headers_immediately:true
        reqd (Httpun.Response.create `OK) in
      Masc.Http_reqd.Body_writer.write_string writer partial;
      reserved := Masc.Http_h2_response_ledger.pending_bytes resources;
      failwith failure
    | "/fast" -> Response.json ~compress:false "alive" reqd
    | path -> failf "unexpected path %s" path in
  with_log_capture @@ fun logged ->
  with_connection ~streams ~resources Request_fibers handler
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    let reply = request client "/partial" in
    check bool "the scope ended with the handler's own exception" true
      (match Eio.Promise.await ended with
       | Masc.Http_h2_stream.Raised (Failure _) -> true
       | _ -> false);
    check bool "the client saw its stream reset" true
      (Result.is_error (Eio.Promise.await reply));
    check int "the handler failed while holding a reservation" (String.length partial)
      !reserved;
    ping client;
    check int "the reservation went back to the ledger" 0
      (Masc.Http_h2_response_ledger.pending_bytes resources);
    check int "the stream left no scope behind" 0
      (Server_h2_stream_registry.active_streams streams);
    check int "the reset logs the failure once" 1 (logged failure);
    check string "connection keeps serving after the failure" "alive"
      (snd (await_reply (request client "/fast"))))

let test_connection_closes_pending_work () =
  let admitted, admit = Eio.Promise.create () in
  let cancelled, mark_cancelled = Eio.Promise.create () in
  let child_started, start_child = Eio.Promise.create () in
  let child_cancelled, cancel_child = Eio.Promise.create () in
  let handler ~stream_end _ h2_reqd =
    let reqd = reqd_of_h2 ~stream_end h2_reqd in
    match (H2.Reqd.request h2_reqd).target with
    | "/slow" ->
      Eio.Promise.resolve admit ();
      (try
         Response.json_value_on_cpu large_json reqd;
         fail "worker unexpectedly admitted disconnected request"
       with Eio.Cancel.Cancelled _ as exn ->
         Eio.Promise.resolve mark_cancelled ();
         raise exn)
    | "/child" ->
      Eio.Fiber.fork ~sw:(Stream_end.switch stream_end) (fun () ->
        Eio.Promise.resolve start_child ();
        try Eio.Fiber.await_cancel () with Eio.Cancel.Cancelled _ as exn ->
          Eio.Promise.resolve cancel_child ();
          raise exn);
      Response.json ~compress:false "started" reqd
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

(* A handler that fails before any response is answered by the connection's
   error handler, which logs the failure. Nothing else logs it again. *)
let test_handler_error_is_stream_local () =
  let failure = "fixture handler failure" in
  let handler ~stream_end _ h2_reqd =
    match (H2.Reqd.request h2_reqd).target with
    | "/fail" -> failwith failure
    | "/fast" -> Response.json ~compress:false "alive" (reqd_of_h2 ~stream_end h2_reqd)
    | path -> failf "unexpected path %s" path in
  with_log_capture @@ fun logged ->
  with_connection Request_fibers handler (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    check int "handler exception becomes stream 500" 500
      (fst (await_reply (request client "/fail")));
    ping client;
    check int "the error handler's line is the only one" 1 (logged failure);
    check string "sibling survives handler exception" "alive"
      (snd (await_reply (request client "/fast"))))

(* RFC-0518 D2. The registry runs on a mock clock that only the test moves,
   so a flush crosses the bound exactly when the test says. The client opens
   each stream's window to [stalled_window] bytes and reads a body only when
   the test asks: h2 opens the window again only for bytes the client read. *)
let stalled_window = 1024
let stalled_body = String.make (4 * stalled_window) 's'

(* What the stall line of a request starts with: its method and its path
   without the query. *)
let stall_line_of ?(meth = "GET") path = Printf.sprintf "[h2] %s %s:" meth path

(* A request whose response the client reads only when the test asks.
   [status] resolves when the headers arrive, [reset] with the error h2
   reports for the stream, and [body] with the response body reader. *)
let open_stream ?(meth = `GET) ?(body = "") client path =
  let status, resolve_status = Eio.Promise.create () in
  let reset, resolve_reset = Eio.Promise.create () in
  let response_body, resolve_body = Eio.Promise.create () in
  let request = H2.Request.create ~scheme:"http" meth path
    ~headers:(H2.Headers.of_list [":authority", "localhost"]) in
  let writer = H2_eio.Client.request client ~flush_headers_immediately:true request
    ~error_handler:(fun error ->
      if not (Eio.Promise.is_resolved reset) then Eio.Promise.resolve resolve_reset error)
    ~response_handler:(fun response reader ->
      Eio.Promise.resolve resolve_body reader;
      Eio.Promise.resolve resolve_status (H2.Status.to_code response.status)) in
  send_body writer body;
  status, reset, response_body

(* Reads the rest of [reader] into [bytes]: [Ok body] when the stream ended
   with END_STREAM, [Error ()] when it was reset. *)
let read_to_end reader bytes =
  let ended, resolve_end = Eio.Promise.create () in
  let rec read () = H2.Body.Reader.schedule_read reader
    ~on_eof:(fun () ->
      Eio.Promise.resolve resolve_end
        (match H2.Body.Reader.completion reader with
         | H2.Body.Reader.Complete -> Ok (Buffer.contents bytes)
         | H2.Body.Reader.Aborted | H2.Body.Reader.Pending -> Error ()))
    ~on_read:(fun chunk ~off ~len ->
      Buffer.add_string bytes (Bigstringaf.substring chunk ~off ~len);
      read ()) in
  read ();
  Eio.Promise.await ended

(* [open_stream] whose body the test drains at once with [read_all]. *)
let open_unread ?meth ?body client path =
  let status, reset, response_body = open_stream ?meth ?body client path in
  let read_all () = read_to_end (Eio.Promise.await response_body) (Buffer.create 256) in
  status, reset, read_all

(* Each PING round trip gives the server a turn; [ready] is a server-side
   state the test waits for without a wall clock. *)
let ping_until client ready =
  let rec go remaining =
    if not (ready ()) then (
      if remaining = 0 then fail "the server did not reach the expected state";
      ping client;
      go (remaining - 1)) in
  go 20

let stalled_ledger () =
  Masc.Http_h2_response_ledger.create
    ~max_pending_bytes:H2_response_limits.default_max_pending_bytes

(* The error h2 reports to the client for RST_STREAM(INTERNAL_ERROR). *)
let reset_with_internal_error reset =
  match Eio.Promise.await reset with
  | `Protocol_error (H2.Error_code.InternalError, _) -> true
  | _ -> false

(* A streaming response to a client whose stream window is zero. No body
   byte can move, and after its request the client sends nothing that would
   give the connection's writer a turn, so the HEADERS frame has to leave on
   its own. The handler answers once the request has ended, and the clock
   never moves: no keepalive and no stall reset carries the frame out. *)
let test_zero_window_client_gets_the_headers () =
  let streams = registry () in
  let resources = stalled_ledger () in
  let held = "data: held by the window\n\n" in
  let handler ~stream_end _ h2_reqd =
    let request_ended, record_request_end = Eio.Promise.create () in
    H2.Body.Reader.schedule_read (H2.Reqd.request_body h2_reqd)
      ~on_eof:(Eio.Promise.resolve record_request_end)
      ~on_read:(fun _ ~off:_ ~len:_ -> ());
    Eio.Promise.await request_ended;
    let writer = Masc.Http_reqd.respond_with_streaming
      (reqd_of_h2 ~stream_end h2_reqd) (Httpun.Response.create `OK) in
    Masc.Http_reqd.Body_writer.write_string writer held;
    Eio.Fiber.await_cancel () in
  with_connection ~streams ~resources ~client_window:0l Request_fibers handler
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    (* The SETTINGS exchange is over before the request goes out: none of
       its frames gives the server's writer a turn once the response has
       started. *)
    ping client;
    let status, _, _ = open_stream client "/held" in
    check int "the headers arrived" 200 (Eio.Promise.await status);
    check int "the window still holds the body" (String.length held)
      (Masc.Http_h2_response_ledger.pending_bytes resources))

(* A streaming response whose client does not read it. At the bound the
   stream is reset, its flush is answered [`Closed], its reservation goes back
   to the ledger, and one warn line names the request. One second earlier
   nothing has happened. *)
let test_stalled_flush_resets_the_stream () =
  let clock = Eio_mock.Clock.make () in
  let streams = registry ~clock () in
  let resources = stalled_ledger () in
  let registered, register = Eio.Promise.create () in
  let flushed, record_flush = Eio.Promise.create () in
  let ended, record_end = Eio.Promise.create () in
  let handler ~stream_end _ h2_reqd =
    let reqd = reqd_of_h2 ~stream_end h2_reqd in
    match (H2.Reqd.request h2_reqd).target with
    | "/stalled" ->
      let writer = Masc.Http_reqd.respond_with_streaming ~flush_headers_immediately:true
        reqd (Httpun.Response.create `OK) in
      Masc.Http_reqd.Body_writer.write_string writer stalled_body;
      Masc.Http_reqd.Body_writer.flush writer (Eio.Promise.resolve record_flush);
      Eio.Promise.resolve register ();
      (try Eio.Fiber.await_cancel () with
       | Eio.Cancel.Cancelled (Masc.Http_h2_stream.Stream_reset cause) as exn ->
         Eio.Promise.resolve record_end cause;
         raise exn)
    | "/fast" -> Response.json ~compress:false "alive" reqd
    | path -> failf "unexpected path %s" path in
  with_log_capture @@ fun logged ->
  with_connection ~streams ~resources ~client_window:(Int32.of_int stalled_window)
    Request_fibers handler
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    let status, reset, _ = open_unread client "/stalled" in
    Eio.Promise.await registered;
    check int "the response started" 200 (Eio.Promise.await status);
    Eio_mock.Clock.set_time clock (stalled_after_s -. 1.0);
    ping client;
    check bool "a flush one second short of the bound keeps its stream" false
      (Eio.Promise.is_resolved ended || Eio.Promise.is_resolved reset);
    check int "nothing is logged before the bound" 0 (logged (stall_line_of "/stalled"));
    Eio_mock.Clock.set_time clock stalled_after_s;
    check bool "the scope ended as stalled" true
      (match Eio.Promise.await ended with
       | Masc.Http_h2_stream.Stalled -> true
       | _ -> false);
    check bool "the client got RST_STREAM(INTERNAL_ERROR)" true
      (reset_with_internal_error reset);
    check bool "the waiting flush was answered as closed" true
      (match Eio.Promise.await flushed with `Closed -> true | `Written -> false);
    check int "the unsent bytes went back to the ledger" 0
      (Masc.Http_h2_response_ledger.pending_bytes resources);
    check int "one warn line names the stalled request" 1
      (logged (stall_line_of "/stalled"));
    check int "the stalled stream left no scope behind" 0
      (Server_h2_stream_registry.active_streams streams);
    check string "the connection keeps serving" "alive"
      (snd (await_reply (request client "/fast"))))

(* A client that reads gets its flush answered, and the clock moving far
   past the bound afterwards cuts nothing. *)
let test_reading_client_keeps_its_stream () =
  let clock = Eio_mock.Clock.make () in
  let streams = registry ~clock () in
  let flushed, record_flush = Eio.Promise.create () in
  let finish, finish_response = Eio.Promise.create () in
  let handler ~stream_end _ h2_reqd =
    let reqd = reqd_of_h2 ~stream_end h2_reqd in
    let writer = Masc.Http_reqd.respond_with_streaming ~flush_headers_immediately:true
      reqd (Httpun.Response.create `OK) in
    Masc.Http_reqd.Body_writer.write_string writer stalled_body;
    Masc.Http_reqd.Body_writer.flush writer (Eio.Promise.resolve record_flush);
    Eio.Promise.await finish;
    Masc.Http_reqd.Body_writer.write_string writer "end";
    Masc.Http_reqd.Body_writer.close writer in
  with_log_capture @@ fun logged ->
  with_connection ~streams ~client_window:(Int32.of_int stalled_window)
    Request_fibers handler
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    let reply = request client "/reading" in
    check bool "the reading client answers the flush" true
      (match Eio.Promise.await flushed with `Written -> true | `Closed -> false);
    Eio_mock.Clock.set_time clock (2.0 *. stalled_after_s);
    ping client;
    check int "the stream keeps its scope" 1
      (Server_h2_stream_registry.active_streams streams);
    check int "nothing is logged as stalled" 0 (logged (stall_line_of "/reading"));
    Eio.Promise.resolve finish_response ();
    check string "the client gets the whole body" (stalled_body ^ "end")
      (snd (await_reply reply)))

(* An error answer h2 opens while the stream's work reports a failure gets
   the bound too: a failure of the handler itself, or one that escapes the
   deferred body work [Http_h2_stream.dispatch] runs. The client leaves the
   answer unread with a window smaller than the diagnostic. At the bound the
   scope ends, the reservation goes back, and the answer is over for the
   client too (RFC-0518 §5). *)
let test_stalled_error_answer_ends source () =
  let clock = Eio_mock.Clock.make () in
  let streams = registry ~clock () in
  let resources = stalled_ledger () in
  let window = 8 in
  let failure = "fixture failure before any response" in
  let handler ~stream_end _ h2_reqd =
    match source with
    | `Handler -> failwith failure
    | `Body_callback ->
      Masc.Http_reqd.read_body (reqd_of_h2 ~stream_end h2_reqd) ~max_bytes:1024
        ~on_body:(fun _ -> failwith failure)
        ~on_error:(function
          | Masc.Http_reqd.Internal exn -> raise exn
          | Masc.Http_reqd.Too_large _ -> fail "a 12-byte body is not too large") in
  with_log_capture @@ fun logged ->
  with_connection ~streams ~resources ~client_window:(Int32.of_int window)
    Request_fibers handler
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    let status, _, read_all =
      match source with
      | `Handler -> open_unread client "/fail"
      | `Body_callback -> open_unread ~meth:`POST ~body:"request body" client "/fail" in
    check int "the error handler answered" 500 (Eio.Promise.await status);
    ping client;
    check int "the error answer holds the stream scope" 1
      (Server_h2_stream_registry.active_streams streams);
    check bool "the diagnostic is reserved while it waits" true
      (Masc.Http_h2_response_ledger.pending_bytes resources > 0);
    Eio_mock.Clock.set_time clock (stalled_after_s -. 1.0);
    ping client;
    check int "one second short of the bound it still holds the scope" 1
      (Server_h2_stream_registry.active_streams streams);
    Eio_mock.Clock.set_time clock stalled_after_s;
    ping_until client (fun () -> Server_h2_stream_registry.active_streams streams = 0);
    check int "the diagnostic went back to the ledger" 0
      (Masc.Http_h2_response_ledger.pending_bytes resources);
    (* The answer is over for the client too. h2 0.13.0 ends it with the
       bytes the window took and END_STREAM (h2#278); a reset would do. *)
    let (_ : (string, unit) result) = read_all () in
    check int "the error handler logged the failure once" 1 (logged failure);
    check int "one warn line names the stalled answer" 1
      (logged (stall_line_of "/fail"
         ~meth:(match source with `Handler -> "GET" | `Body_callback -> "POST"))))

(* RFC-0518 D3. A body reaches h2 in slices, and the bound runs from one
   slice's leaving to the next's. [long_body] is two slices longer than what
   h2 holds of a body, so its tail waits in the queue. The client's window
   holds one slice and the client reads one slice a minute, so the body
   takes three minutes: past the bound, but never more than a minute on one
   slice. *)
let long_body_slices = Response_body.slices_in_h2 + 2
let long_body = String.init (long_body_slices * Response_body.slice_bytes)
    (fun n -> Char.chr (97 + n mod 26))

(* The minutes in which that client reads the slices after the first. *)
let long_body_minutes = List.init (long_body_slices - 1) (fun n -> n + 1)

(* Reads [n] more bytes of [reader] into [into]. The client opens the
   stream's window again for the bytes it read. *)
let read_exactly reader into n =
  let target = Buffer.length into + n in
  let read, resolve = Eio.Promise.create () in
  let rec go () =
    if Buffer.length into >= target then Eio.Promise.resolve resolve (Ok ())
    else H2.Body.Reader.schedule_read reader
      ~on_eof:(fun () -> Eio.Promise.resolve resolve (Error "the body ended early"))
      ~on_read:(fun chunk ~off ~len ->
        Buffer.add_string into (Bigstringaf.substring chunk ~off ~len);
        go ()) in
  go ();
  match Eio.Promise.await read with Ok () -> () | Error reason -> fail reason

(* Reads the next DATA frame of the body into [into] and returns its length.
   h2's client keeps every frame apart and returns the frame's credit when
   it is read (client_connection.ml [process_data_frame], body.ml
   [do_execute_read]). *)
let read_frame reader into =
  let frame, resolve = Eio.Promise.create () in
  H2.Body.Reader.schedule_read reader
    ~on_eof:(fun () -> Eio.Promise.resolve resolve (Error "the body ended early"))
    ~on_read:(fun chunk ~off ~len ->
      Buffer.add_string into (Bigstringaf.substring chunk ~off ~len);
      Eio.Promise.resolve resolve (Ok len));
  match Eio.Promise.await frame with Ok len -> len | Error reason -> fail reason

let long_body_handler source ~stream_end _ h2_reqd =
  let reqd = reqd_of_h2 ~stream_end h2_reqd in
  let response = Httpun.Response.create `OK in
  match source with
  | `Whole -> Masc.Http_reqd.respond_with_string reqd response long_body
  | `Streamed ->
    let writer = Masc.Http_reqd.respond_with_streaming reqd response in
    Masc.Http_reqd.Body_writer.write_string writer long_body;
    Masc.Http_reqd.Body_writer.close writer

let slice_window = Int32.of_int Response_body.slice_bytes

let test_steady_reader_gets_a_long_body source () =
  let clock = Eio_mock.Clock.make () in
  let streams = registry ~clock () in
  with_log_capture @@ fun logged ->
  with_connection ~streams ~resources:(stalled_ledger ()) ~client_window:slice_window
    Request_fibers (long_body_handler source)
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    let status, reset, response_body = open_stream client "/long" in
    check int "the response started" 200 (Eio.Promise.await status);
    let reader = Eio.Promise.await response_body in
    let received = Buffer.create (String.length long_body) in
    List.iter (fun minute ->
      Eio_mock.Clock.set_time clock (60.0 *. float_of_int minute);
      ping client;
      check int (Printf.sprintf "nothing stalled by minute %d" minute) 0
        (logged (stall_line_of "/long"));
      check bool (Printf.sprintf "the stream is open at minute %d" minute) false
        (Eio.Promise.is_resolved reset);
      read_exactly reader received Response_body.slice_bytes;
      ping client)
      long_body_minutes;
    check bool "the client got the whole body" true
      (read_to_end reader received = Ok long_body);
    check int "no stall line at all" 0 (logged (stall_line_of "/long")))

(* RFC-0518 D3 on a slow link. The client's window holds the whole body, so
   only the socket holds it back: each minute it takes what h2 holds of a
   body at most, and a little more. h2 hands a socket everything the window
   allows as one write and answers the flushes inside it when all of it is
   through, for this body after three minutes. With two slices in h2 at a
   time, each write crosses within a minute and the client that keeps reading
   gets the whole body. *)
let test_steady_reader_on_a_slow_socket_gets_a_long_body () =
  let in_h2 = Response_body.slices_in_h2 * Response_body.slice_bytes in
  let body = String.init (4 * in_h2) (fun n -> Char.chr (97 + n mod 26)) in
  let handler ~stream_end _ h2_reqd =
    Masc.Http_reqd.respond_with_string (reqd_of_h2 ~stream_end h2_reqd)
      (Httpun.Response.create `OK) body in
  let clock = Eio_mock.Clock.make () in
  let streams = registry ~clock () in
  let pace =
    { Server_socket.clock = (clock :> float Eio.Time.clock_ty Eio.Resource.t)
    ; chunk = in_h2 + 2048
    ; interval = 60.0
    } in
  with_log_capture @@ fun logged ->
  with_connection ~streams ~resources:(stalled_ledger ()) ~pace
    ~client_window:(Int32.of_int (2 * String.length body))
    Request_fibers handler
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    let status, reset, response_body = open_stream client "/long" in
    check int "the response started" 200 (Eio.Promise.await status);
    let reader = Eio.Promise.await response_body in
    let received = Buffer.create (String.length body) in
    read_exactly reader received in_h2;
    List.iter (fun minute ->
      Eio_mock.Clock.set_time clock (60.0 *. float_of_int minute);
      read_exactly reader received in_h2;
      check bool (Printf.sprintf "the stream is open at minute %d" minute) false
        (Eio.Promise.is_resolved reset))
      [1; 2; 3];
    check bool "the client got the whole body" true
      (read_to_end reader received = Ok body);
    check int "no stall line" 0 (logged (stall_line_of "/long")))

(* RFC-0518 D3 on a slow link that two responses share. h2 gives the socket
   one stream's bytes at a time and picks the stream by a fair queue over
   the bytes each got (scheduler.ml [flush]). With one long body in flight
   the short response waits for the write in progress and no longer: two
   slices of the long body, which this socket takes within the minute. With the whole long body in h2
   that write is the body, three minutes of it. *)
let test_a_short_response_does_not_wait_for_a_long_one () =
  let in_h2 = Response_body.slices_in_h2 * Response_body.slice_bytes in
  let long = String.init (4 * in_h2) (fun n -> Char.chr (97 + n mod 26)) in
  let short = "short" in
  let short_answered, answer_short = Eio.Promise.create () in
  let handler ~stream_end _ h2_reqd =
    let reqd = reqd_of_h2 ~stream_end h2_reqd in
    let response = Httpun.Response.create `OK in
    match (H2.Reqd.request h2_reqd).target with
    | "/long" -> Masc.Http_reqd.respond_with_string reqd response long
    | "/short" ->
      Masc.Http_reqd.respond_with_string reqd response short;
      Eio.Promise.resolve answer_short ()
    | path -> failf "unexpected path %s" path in
  let clock = Eio_mock.Clock.make () in
  let streams = registry ~clock () in
  let pace =
    { Server_socket.clock = (clock :> float Eio.Time.clock_ty Eio.Resource.t)
    ; chunk = in_h2 + 2048
    ; interval = 60.0
    } in
  with_connection ~streams ~resources:(stalled_ledger ()) ~pace
    ~client_window:(Int32.of_int (2 * String.length long))
    Request_fibers handler
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    let status, _, long_response = open_stream client "/long" in
    check int "the long response started" 200 (Eio.Promise.await status);
    let reader = Eio.Promise.await long_response in
    let received = Buffer.create (String.length long) in
    read_exactly reader received in_h2;
    let short_status, _, short_response = open_stream client "/short" in
    Eio.Promise.await short_answered;
    Eio_mock.Clock.set_time clock 60.0;
    check int "the short response started in the second minute" 200
      (Eio.Promise.await short_status);
    check bool "the short response ended in the second minute" true
      (read_to_end (Eio.Promise.await short_response) (Buffer.create 16) = Ok short);
    read_exactly reader received in_h2;
    List.iter (fun minute ->
      Eio_mock.Clock.set_time clock (60.0 *. float_of_int minute);
      read_exactly reader received in_h2)
      [2; 3];
    check bool "the client got the whole long body" true
      (read_to_end reader received = Ok long))

(* A client that reads none of a long body: one slice fits its window, the
   next ones wait in h2 and behind it, and at the bound the stream is reset.
   The stall line names the path without the query, which can carry a
   token. *)
let test_idle_reader_of_a_long_body_is_cut () =
  let clock = Eio_mock.Clock.make () in
  let streams = registry ~clock () in
  let resources = stalled_ledger () in
  with_log_capture @@ fun logged ->
  with_connection ~streams ~resources ~client_window:slice_window
    Request_fibers (long_body_handler `Whole)
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    let status, reset, response_body = open_stream client "/long?token=fixture" in
    check int "the response started" 200 (Eio.Promise.await status);
    ping client;
    check bool "the body holds its reservation" true
      (Masc.Http_h2_response_ledger.pending_bytes resources > 0);
    Eio_mock.Clock.set_time clock (stalled_after_s -. 1.0);
    ping client;
    check int "one second short of the bound the stream is open" 1
      (Server_h2_stream_registry.active_streams streams);
    Eio_mock.Clock.set_time clock stalled_after_s;
    ping_until client (fun () -> Server_h2_stream_registry.active_streams streams = 0);
    check bool "the client got RST_STREAM(INTERNAL_ERROR)" true
      (reset_with_internal_error reset);
    check bool "the body did not end whole" true
      (read_to_end (Eio.Promise.await response_body) (Buffer.create 16) = Error ());
    check int "the reservation went back to the ledger" 0
      (Masc.Http_h2_response_ledger.pending_bytes resources);
    check int "one warn line names the long body" 1 (logged (stall_line_of "/long"));
    check int "the query stays out of the log" 0 (logged "token="))

(* A whole body shorter than one slice is a single slice, and a client
   that leaves it unread is cut at the bound all the same. *)
let test_idle_reader_of_a_short_body_is_cut () =
  let clock = Eio_mock.Clock.make () in
  let streams = registry ~clock () in
  let resources = stalled_ledger () in
  let handler ~stream_end _ h2_reqd =
    Masc.Http_reqd.respond_with_string (reqd_of_h2 ~stream_end h2_reqd)
      (Httpun.Response.create `OK) stalled_body in
  with_log_capture @@ fun logged ->
  with_connection ~streams ~resources ~client_window:(Int32.of_int stalled_window)
    Request_fibers handler
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    let status, reset, _ = open_unread client "/short" in
    check int "the response started" 200 (Eio.Promise.await status);
    Eio_mock.Clock.set_time clock (stalled_after_s -. 1.0);
    ping client;
    check int "one second short of the bound the stream is open" 1
      (Server_h2_stream_registry.active_streams streams);
    Eio_mock.Clock.set_time clock stalled_after_s;
    ping_until client (fun () -> Server_h2_stream_registry.active_streams streams = 0);
    check bool "the client got RST_STREAM(INTERNAL_ERROR)" true
      (reset_with_internal_error reset);
    check int "the reservation went back to the ledger" 0
      (Masc.Http_h2_response_ledger.pending_bytes resources);
    check int "one warn line names the short body" 1 (logged (stall_line_of "/short")))

(* A stream whose peer takes nothing keeps getting frames, as an SSE stream
   gets its keepalives. They wait behind the frame the peer does not take
   and start no count of their own: the stream is cut one bound after the
   first frame. *)
let test_later_flushes_do_not_extend_the_bound () =
  let clock = Eio_mock.Clock.make () in
  let streams = registry ~clock () in
  let more = Eio.Stream.create 1 in
  let wrote = Eio.Stream.create 1 in
  let handler ~stream_end _ h2_reqd =
    let writer = Masc.Http_reqd.respond_with_streaming ~flush_headers_immediately:true
      (reqd_of_h2 ~stream_end h2_reqd) (Httpun.Response.create `OK) in
    let rec frames frame =
      Masc.Http_reqd.Body_writer.write_string writer frame;
      Masc.Http_reqd.Body_writer.flush writer ignore;
      Eio.Stream.add wrote ();
      Eio.Stream.take more;
      frames ": keepalive\n\n" in
    frames stalled_body in
  with_connection ~streams ~client_window:(Int32.of_int stalled_window)
    Request_fibers handler
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    let status, reset, _ = open_unread client "/frames" in
    check int "the response started" 200 (Eio.Promise.await status);
    Eio.Stream.take wrote;
    List.iter (fun thirds ->
      Eio_mock.Clock.set_time clock (thirds *. stalled_after_s /. 3.0);
      Eio.Stream.add more ();
      Eio.Stream.take wrote)
      [1.0; 2.0];
    ping client;
    check int "the stream is open before the bound" 1
      (Server_h2_stream_registry.active_streams streams);
    Eio_mock.Clock.set_time clock stalled_after_s;
    ping_until client (fun () -> Server_h2_stream_registry.active_streams streams = 0);
    check bool "the client got RST_STREAM(INTERNAL_ERROR)" true
      (reset_with_internal_error reset))

(* A stream ends with two flushes waiting, and the answer of the older one
   raises. The newer one is answered all the same, and the failure is
   reported once the scope is over. Behind a short body the flushes wait in
   h2 and the stream's end answers them; behind a long one they wait for the
   payload h2 does not hold yet, and the body answers them when it ends. *)
let test_every_waiting_flush_is_answered waiting () =
  let body =
    match waiting with
    | `In_h2 -> stalled_body
    | `Behind_payload -> long_body in
  let clock = Eio_mock.Clock.make () in
  let streams = registry ~clock () in
  let failure = "fixture flush answer failure" in
  let registered, register = Eio.Promise.create () in
  let answered, answer = Eio.Promise.create () in
  let handler ~stream_end _ h2_reqd =
    let reqd = reqd_of_h2 ~stream_end h2_reqd in
    match (H2.Reqd.request h2_reqd).target with
    | "/waiting" ->
      let writer = Masc.Http_reqd.respond_with_streaming ~flush_headers_immediately:true
        reqd (Httpun.Response.create `OK) in
      Masc.Http_reqd.Body_writer.write_string writer body;
      Masc.Http_reqd.Body_writer.flush writer (fun _ -> failwith failure);
      Masc.Http_reqd.Body_writer.flush writer (Eio.Promise.resolve answer);
      Eio.Promise.resolve register ();
      Eio.Fiber.await_cancel ()
    | "/fast" -> Response.json ~compress:false "alive" reqd
    | path -> failf "unexpected path %s" path in
  with_log_capture @@ fun logged ->
  with_connection ~streams ~client_window:(Int32.of_int stalled_window)
    Request_fibers handler
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    let _status, _reset, _ = open_unread client "/waiting" in
    Eio.Promise.await registered;
    Eio_mock.Clock.set_time clock stalled_after_s;
    ping_until client (fun () ->
      Server_h2_stream_registry.active_streams streams = 0
      && Eio.Promise.is_resolved answered);
    check bool "the newer flush was answered as closed" true
      (match Eio.Promise.await answered with `Closed -> true | `Written -> false);
    check int "the failed answer is reported once" 1 (logged failure);
    check string "the connection keeps serving" "alive"
      (snd (await_reply (request client "/fast"))))

(* Two fibers write a long payload each to one body. A payload waits whole
   behind the one written before it, so each arrives in one piece: the
   frames of two SSE producers do not mix. *)
let test_two_producers_do_not_interleave () =
  let payload fill = String.make (3 * Response_body.slice_bytes) fill in
  let handler ~stream_end _ h2_reqd =
    let writer = Masc.Http_reqd.respond_with_streaming
      (reqd_of_h2 ~stream_end h2_reqd) (Httpun.Response.create `OK) in
    Eio.Fiber.both
      (fun () -> Masc.Http_reqd.Body_writer.write_string writer (payload 'a'))
      (fun () -> Masc.Http_reqd.Body_writer.write_string writer (payload 'b'));
    Masc.Http_reqd.Body_writer.close writer in
  with_connection ~streams:(registry ()) Request_fibers handler
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    check bool "each payload arrives in one piece" true
      (String.equal (payload 'a' ^ payload 'b') (snd (await_reply (request client "/two")))))

(* A route closes its body while the client still holds bytes back. The
   body is closed from then on: what the route writes afterwards is dropped
   and reserves nothing in the ledger, and a flush it asks for then is
   answered as closed. The client gets exactly what was written before the
   close. *)
let test_write_after_close_is_dropped () =
  let resources = stalled_ledger () in
  let closed, record_closed = Eio.Promise.create () in
  let reserved, record_reserved = Eio.Promise.create () in
  let late_flush, record_late_flush = Eio.Promise.create () in
  let handler ~stream_end _ h2_reqd =
    let writer = Masc.Http_reqd.respond_with_streaming
      (reqd_of_h2 ~stream_end h2_reqd) (Httpun.Response.create `OK) in
    Masc.Http_reqd.Body_writer.write_string writer stalled_body;
    Masc.Http_reqd.Body_writer.close writer;
    Eio.Promise.resolve record_closed (Masc.Http_reqd.Body_writer.is_closed writer);
    Masc.Http_reqd.Body_writer.write_string writer "late";
    Eio.Promise.resolve record_reserved
      (Masc.Http_h2_response_ledger.pending_bytes resources);
    Masc.Http_reqd.Body_writer.flush writer (Eio.Promise.resolve record_late_flush) in
  with_connection ~streams:(registry ()) ~resources
    ~client_window:(Int32.of_int stalled_window)
    Request_fibers handler
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    let reply = request client "/closed" in
    check bool "the body is closed once the route closed it" true
      (Eio.Promise.await closed);
    check int "the late write reserved nothing" (String.length stalled_body)
      (Eio.Promise.await reserved);
    check bool "a flush after the close is answered as closed" true
      (match Eio.Promise.await late_flush with `Closed -> true | `Written -> false);
    check string "the client gets what was written before the close" stalled_body
      (snd (await_reply reply)))

(* A flush answers for everything written before it. The frame is
   [long_body] and the client's window holds one slice, so the flush is
   answered when the last slice went and not before: a producer that waits
   for its flush is held back by the client for the whole frame. *)
let test_flush_waits_for_the_bytes_before_it () =
  let flushed, record_flush = Eio.Promise.create () in
  let handler ~stream_end _ h2_reqd =
    let writer = Masc.Http_reqd.respond_with_streaming
      (reqd_of_h2 ~stream_end h2_reqd) (Httpun.Response.create `OK) in
    Masc.Http_reqd.Body_writer.write_string writer long_body;
    Masc.Http_reqd.Body_writer.flush writer (fun outcome ->
      Eio.Promise.resolve record_flush outcome;
      Masc.Http_reqd.Body_writer.close writer) in
  with_connection ~streams:(registry ()) ~client_window:slice_window
    Request_fibers handler
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    let status, _, response_body = open_stream client "/frame" in
    check int "the response started" 200 (Eio.Promise.await status);
    let reader = Eio.Promise.await response_body in
    let received = Buffer.create (String.length long_body) in
    List.iter (fun slices ->
      read_exactly reader received Response_body.slice_bytes;
      ping client;
      check bool (Printf.sprintf "the flush waits with %d slices read" slices) false
        (Eio.Promise.is_resolved flushed))
      (List.init (long_body_slices - 2) (fun n -> n + 1));
    read_exactly reader received Response_body.slice_bytes;
    check bool "the flush is answered once the last slice went" true
      (match Eio.Promise.await flushed with `Written -> true | `Closed -> false);
    check bool "the client got the whole frame" true
      (read_to_end reader received = Ok long_body))

(* A DATA frame goes on past the end of a slice when the peer's window
   allows. The window holds a slice and a half, so the body starts as a full
   frame and half a frame. The client reads the full frame, which returns
   its credit: the next frame is full again, the rest of the second slice
   with the start of the third. With one slice in h2 that frame ended with
   the second slice, and a client that returns credit frame by frame got
   every credit back as two smaller frames at each slice's end
   (RFC-0518 D3). *)
let test_a_frame_crosses_the_end_of_a_slice () =
  let slice = Response_body.slice_bytes in
  with_connection ~streams:(registry ()) ~resources:(stalled_ledger ())
    ~client_window:(Int32.of_int (slice + (slice / 2)))
    Request_fibers (long_body_handler `Whole)
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    let status, _, response_body = open_stream client "/long" in
    check int "the response started" 200 (Eio.Promise.await status);
    let reader = Eio.Promise.await response_body in
    let received = Buffer.create (String.length long_body) in
    let first = read_frame reader received in
    let second = read_frame reader received in
    let third = read_frame reader received in
    check (list int) "a full frame follows the window's worth"
      [ slice; slice / 2; slice ] [ first; second; third ];
    check bool "the client got the whole body" true
      (read_to_end reader received = Ok long_body))

(* h2 calls the answer to a flush from the connection's write loop, and an
   exception there would end the loop for every stream of the connection.
   The client takes the bytes, the answer raises: its stream is reset, the
   failure is logged once, and the connection keeps serving. *)
let test_raising_answer_ends_its_stream_only () =
  let failure = "fixture written answer failure" in
  let handler ~stream_end _ h2_reqd =
    let reqd = reqd_of_h2 ~stream_end h2_reqd in
    match (H2.Reqd.request h2_reqd).target with
    | "/raising" ->
      let writer = Masc.Http_reqd.respond_with_streaming reqd (Httpun.Response.create `OK) in
      Masc.Http_reqd.Body_writer.write_string writer stalled_body;
      Masc.Http_reqd.Body_writer.flush writer (fun _ -> failwith failure);
      Eio.Fiber.await_cancel ()
    | "/fast" -> Response.json ~compress:false "alive" reqd
    | path -> failf "unexpected path %s" path in
  with_log_capture @@ fun logged ->
  with_connection ~streams:(registry ()) Request_fibers handler
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    let _status, reset, _ = open_unread client "/raising" in
    check bool "the stream got RST_STREAM(INTERNAL_ERROR)" true
      (reset_with_internal_error reset);
    check int "the failed answer is reported once" 1 (logged failure);
    check string "the connection keeps serving" "alive"
      (snd (await_reply (request client "/fast"))))

(* RFC-0518 D2 for SSE. [long_body] goes out as one frame through
   [Server_sse_response.send], and [record] gets the answer when [send]
   returns. On HTTP/2 only the stream's flush bound times the frame, slice
   by slice. [fork] says where the [send] runs. *)
let long_frame_handler ~clock ~record ~fork ~stream_end _ h2_reqd =
  let sse =
    Server_sse_response.respond ~clock ~stalled_after_s (reqd_of_h2 ~stream_end h2_reqd)
      (Httpun.Response.create `OK) in
  fork (fun () ->
    record (Server_sse_response.send sse long_body);
    Server_sse_response.close sse)

(* What the stall line of an SSE response starts with. *)
let sse_stall_line_of path = Printf.sprintf "SSE response for %s closed" path

let sent_written sent =
  match Eio.Promise.peek sent with
  | Some Server_sse_response.Written -> true
  | Some (Server_sse_response.Closed | Server_sse_response.Stalled) | None -> false

(* The client reads one slice a minute, so the frame takes three minutes.
   [send] waits the whole time and answers [Written]; nothing logs a stall. *)
let test_steady_reader_gets_a_long_sse_frame () =
  let clock = Eio_mock.Clock.make () in
  let streams = registry ~clock () in
  let sent, record = Eio.Promise.create () in
  with_log_capture @@ fun logged ->
  with_connection ~streams ~resources:(stalled_ledger ()) ~client_window:slice_window
    Request_fibers
    (long_frame_handler ~clock ~record:(Eio.Promise.resolve record) ~fork:(fun send -> send ()))
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    let status, reset, response_body = open_stream client "/frame" in
    check int "the response started" 200 (Eio.Promise.await status);
    let reader = Eio.Promise.await response_body in
    let received = Buffer.create (String.length long_body) in
    List.iter (fun minute ->
      Eio_mock.Clock.set_time clock (60.0 *. float_of_int minute);
      ping client;
      check bool (Printf.sprintf "send still waits at minute %d" minute) false
        (Eio.Promise.is_resolved sent);
      check bool (Printf.sprintf "the stream is open at minute %d" minute) false
        (Eio.Promise.is_resolved reset);
      read_exactly reader received Response_body.slice_bytes;
      ping client)
      long_body_minutes;
    check bool "the client got the whole frame" true
      (read_to_end reader received = Ok long_body);
    check bool "send answered Written" true (sent_written sent);
    check int "the stream logged no stall" 0 (logged (stall_line_of "/frame"));
    check int "the SSE response logged no stall" 0 (logged (sse_stall_line_of "/frame")))

(* Where a frame's [send] runs: on the stream's own fiber, or on a fiber of
   a switch that outlives the stream, as the log, fleet and MCP streams
   send. *)
type sender = On_stream | Off_stream

(* A client that reads one slice of the frame after a minute and then
   nothing. The bound counts from the slice that left last, so the stream is
   reset a bound after that minute. A timer on the whole frame would end it
   a bound after the frame began, a minute earlier. The stream's line is the
   only stall line. A [send] on the stream's own fiber is cancelled with the
   stream and does not return; one on another fiber answers [Closed]. *)
let test_idle_reader_of_a_long_sse_frame_is_cut sender () =
  let clock = Eio_mock.Clock.make () in
  let streams = registry ~clock () in
  let resources = stalled_ledger () in
  let sent, record = Eio.Promise.create () in
  let outside, set_outside = Eio.Promise.create () in
  let fork send =
    match sender with
    | On_stream -> send ()
    | Off_stream -> Eio.Fiber.fork ~sw:(Eio.Promise.await outside) send in
  with_log_capture @@ fun logged ->
  with_connection ~streams ~resources ~client_window:slice_window
    Request_fibers (long_frame_handler ~clock ~record:(Eio.Promise.resolve record) ~fork)
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    Eio.Switch.run @@ fun sw ->
    Eio.Promise.resolve set_outside sw;
    let status, reset, response_body = open_stream client "/frame" in
    check int "the response started" 200 (Eio.Promise.await status);
    let reader = Eio.Promise.await response_body in
    let last_read = 60.0 in
    Eio_mock.Clock.set_time clock last_read;
    ping client;
    read_exactly reader (Buffer.create Response_body.slice_bytes) Response_body.slice_bytes;
    ping client;
    Eio_mock.Clock.set_time clock stalled_after_s;
    ping client;
    check bool "a bound after the frame began, send still waits" false
      (Eio.Promise.is_resolved sent);
    check int "and nothing logged a stall" 0
      (logged (stall_line_of "/frame") + logged (sse_stall_line_of "/frame"));
    Eio_mock.Clock.set_time clock (last_read +. stalled_after_s -. 1.0);
    ping client;
    check int "one second short of the bound the stream is open" 1
      (Server_h2_stream_registry.active_streams streams);
    Eio_mock.Clock.set_time clock (last_read +. stalled_after_s);
    ping_until client (fun () -> Server_h2_stream_registry.active_streams streams = 0);
    check bool "the client got RST_STREAM(INTERNAL_ERROR)" true
      (reset_with_internal_error reset);
    check bool "the frame did not end whole" true
      (read_to_end reader (Buffer.create 16) = Error ());
    check int "the reservation went back to the ledger" 0
      (Masc.Http_h2_response_ledger.pending_bytes resources);
    check int "one stall line names the frame's request" 1 (logged (stall_line_of "/frame"));
    check int "the SSE response logged no stall of its own" 0
      (logged (sse_stall_line_of "/frame"));
    match sender with
    | On_stream ->
      check bool "send did not return" false (Eio.Promise.is_resolved sent)
    | Off_stream ->
      (match Eio.Promise.await sent with
       | Server_sse_response.Closed -> ()
       | Server_sse_response.Written | Server_sse_response.Stalled ->
         fail "send did not answer Closed"))

module Log_stream = Server_routes_http_routes_log_stream

(* A query that only this file's entries match, whatever else the ring gets. *)
let log_stream_module = "h2-request-fibers-log-stream"

let log_stream_query : Server_logs_query.t =
  { limit = 50
  ; level_filter = "WARN"
  ; applied_level = Log.Warn
  ; min_level = Log.level_to_int Log.Warn
  ; module_filter = log_stream_module
  ; since_seq = None
  ; before_seq = None
  ; categories = None
  ; exclude_categories = None
  }

(* The stream's loop runs in [outside], a switch that outlives the HTTP/2
   stream, as the router's switch does. A frame is its entries' messages.
   The workspace of these streams is never replaced. *)
let log_stream_handler ~clock ~outside ~stream_end _ h2_reqd =
  Log_stream.serve ~sw:(Eio.Promise.await outside) ~clock
    ~instance:log_stream_module
    ~current:(fun () -> true)
    ~replaced:Eio.Fiber.await_cancel
    ~encode:(fun (frame : Log_stream.frame) ->
      Printf.sprintf "data: %s\n\n"
        (String.concat "," (List.map (fun (entry : Log.Ring.entry) -> entry.message) frame.entries)))
    ~query:log_stream_query (reqd_of_h2 ~stream_end h2_reqd)

(* How many times [frame] is in [text]. *)
let frames_in text frame =
  let size = String.length frame in
  let rec count at found =
    if at + size > String.length text
    then found
    else if String.equal (String.sub text at size) frame
    then count (at + size) (found + 1)
    else count (at + 1) found in
  count 0 0

(* Keeps reading [reader] into [into] as the bytes arrive. *)
let collect reader into =
  let rec read () = H2.Body.Reader.schedule_read reader
    ~on_eof:ignore
    ~on_read:(fun chunk ~off ~len ->
      Buffer.add_string into (Bigstringaf.substring chunk ~off ~len);
      read ()) in
  read ()

(* The clock a log stream's loop is given: the mock clock, counting the
   sleeps the loop starts on it. The loop takes the time of its next
   keepalive when a send returns, and a client can hold a frame before the
   server's send has returned. A test that moved the time as soon as it held
   the frame would move it under that reading. The loop starts a sleep each
   time it goes back to wait, so a test moves the time once [sleeps] grew.

   The mock clock is the time that passes. What the loop reads is that time
   less [set_back_s], as a wall clock set back by that much reads, and a
   sleep lasts the difference to the reading when it starts, as the server's
   clock sleeps (eio_posix time.ml). [before_sleep] runs when the loop starts
   a sleep, after it began to wait for the ring. *)
module Loop_clock = struct
  type t =
    { clock : Eio_mock.Clock.t
    ; mutable sleeps : int
    ; mutable set_back_s : float
    ; mutable before_sleep : unit -> unit
    }

  type time = float

  let now t = Eio.Time.now t.clock -. t.set_back_s

  let sleep_until t time =
    t.sleeps <- t.sleeps + 1;
    t.before_sleep ();
    Eio.Time.sleep_until t.clock (time +. t.set_back_s)
end

let loop_clock_of clock =
  let loop = { Loop_clock.clock; sleeps = 0; set_back_s = 0.0; before_sleep = ignore } in
  let resource : float Eio.Time.clock_ty Eio.Resource.t =
    Eio.Resource.T (loop, Eio.Time.Pi.clock (module Loop_clock)) in
  loop, resource

let left_out () = Log.emit Log.Warn ~module_name:"h2-request-fibers-left-out" "left out"

(* A log stream on [loop_clock] whose client holds the first frame and whose
   loop is at its wait. [run] gets the count of keepalives received. Once it
   returns the client goes. The response ends the loop: the connection's end
   ends the stream, and no keepalive has to come due for that, so [sw] can
   end with the clock where it is. *)
let with_waiting_log_stream ~clock ~loop ~loop_clock run =
  let outside, set_outside = Eio.Promise.create () in
  with_log_capture @@ fun _ ->
  with_connection ~streams:(registry ~clock ()) ~resources:(stalled_ledger ()) Request_fibers
    (log_stream_handler ~clock:loop_clock ~outside)
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client ~server ->
    Eio.Switch.run @@ fun sw ->
    Eio.Promise.resolve set_outside sw;
    let status, _, response_body = open_stream client "/logs" in
    check int "the response started" 200 (Eio.Promise.await status);
    let received = Buffer.create 256 in
    collect (Eio.Promise.await response_body) received;
    let keepalives () = frames_in (Buffer.contents received) Server_sse_pump.keepalive_frame in
    ping_until client (fun () -> Buffer.length received > 0 && loop.Loop_clock.sleeps > 0);
    check int "the first frame is no keepalive" 0 (keepalives ());
    run ~client ~keepalives;
    close_client ();
    Eio.Promise.await_exn server)

(* A log stream whose query leaves out what the ring gets: an entry every
   third of a ping interval, each of which wakes the stream's loop and sends
   nothing. The keepalive goes out every ping interval all the same, so a
   client that reads tells a quiet stream from a dead connection. A
   keepalive time started again at each wake would never come. *)
let test_log_stream_pings_past_entries_its_query_leaves_out () =
  let clock = Eio_mock.Clock.make () in
  let loop, loop_clock = loop_clock_of clock in
  let ping_interval_s = Server_mcp_transport_http_headers.sse_ping_interval_s in
  let third = ping_interval_s /. 3.0 in
  let intervals = 3 in
  with_waiting_log_stream ~clock ~loop ~loop_clock (fun ~client ~keepalives ->
    (* The ring gets an entry the query leaves out at [time]. The loop is
       back at its wait when this returns. *)
    let left_out_at time =
      let slept = loop.Loop_clock.sleeps in
      Eio_mock.Clock.set_time clock time;
      left_out ();
      ping_until client (fun () -> loop.Loop_clock.sleeps > slept) in
    for interval = 1 to intervals do
      let start = float_of_int (interval - 1) *. ping_interval_s in
      left_out_at (start +. third);
      left_out_at (start +. (2.0 *. third));
      check int "no keepalive before a ping interval went by" (interval - 1) (keepalives ());
      left_out_at (start +. ping_interval_s);
      ping_until client (fun () -> keepalives () >= interval);
      check int "one keepalive each ping interval" interval (keepalives ())
    done)

(* The wall clock is set back an hour while a log stream waits for its
   keepalive time. That time is a reading the loop took before the step, and
   a sleep until it would last the hour longer. The loop wakes for an entry
   its query leaves out and goes back to sleep: a ping interval at most. *)
let test_log_stream_keepalive_after_the_clock_is_set_back () =
  let clock = Eio_mock.Clock.make () in
  let loop, loop_clock = loop_clock_of clock in
  let ping_interval_s = Server_mcp_transport_http_headers.sse_ping_interval_s in
  with_waiting_log_stream ~clock ~loop ~loop_clock (fun ~client ~keepalives ->
    let slept = loop.Loop_clock.sleeps in
    loop.Loop_clock.set_back_s <- 3600.0;
    left_out ();
    ping_until client (fun () -> loop.Loop_clock.sleeps > slept);
    Eio_mock.Clock.set_time clock ping_interval_s;
    ping_until client (fun () -> keepalives () >= 1);
    check int "one keepalive a ping interval after the stream last sent" 1 (keepalives ()))

(* A ring that holds a newer entry each time a log stream's loop comes back
   to wait: an entry the query leaves out is added as the loop starts each
   sleep, as a writer on another domain could add one between the loop's read
   and its wait. The wait for the ring then ends first every time and the
   wait for the keepalive time never does. The loop looks at the time when it
   wakes for the ring, so the keepalive goes out. *)
let test_log_stream_pings_while_the_ring_always_holds_a_newer_entry () =
  let clock = Eio_mock.Clock.make () in
  let loop, loop_clock = loop_clock_of clock in
  let ping_interval_s = Server_mcp_transport_http_headers.sse_ping_interval_s in
  with_waiting_log_stream ~clock ~loop ~loop_clock (fun ~client ~keepalives ->
    loop.Loop_clock.before_sleep <- left_out;
    left_out ();
    Eio_mock.Clock.set_time clock ping_interval_s;
    ping_until client (fun () -> keepalives () >= 1);
    check int "one keepalive at the ping interval" 1 (keepalives ()))

(* A log stream whose client reads nothing. The first frame is longer than
   the client's window, so its flush waits, and at the bound the stream is
   reset. The loop runs outside the stream, under [serve]: the reset cancels
   it at its [send], and [sw] can end. The stream's line is the only stall
   line. *)
let test_unread_log_stream_is_reset_at_the_bound () =
  let clock = Eio_mock.Clock.make () in
  let streams = registry ~clock () in
  let resources = stalled_ledger () in
  let outside, set_outside = Eio.Promise.create () in
  with_log_capture @@ fun logged ->
  with_connection ~streams ~resources ~client_window:(Int32.of_int stalled_window)
    Request_fibers
    (log_stream_handler ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t) ~outside)
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    Eio.Switch.run @@ fun sw ->
    Eio.Promise.resolve set_outside sw;
    Log.emit Log.Warn ~module_name:log_stream_module (String.make (2 * stalled_window) 'm');
    let status, reset, response_body = open_stream client "/logs?token=fixture" in
    check int "the response started" 200 (Eio.Promise.await status);
    ping client;
    check bool "the frame holds its reservation" true
      (Masc.Http_h2_response_ledger.pending_bytes resources > 0);
    Eio_mock.Clock.set_time clock (stalled_after_s -. 1.0);
    ping client;
    check int "one second short of the bound the stream is open" 1
      (Server_h2_stream_registry.active_streams streams);
    Eio_mock.Clock.set_time clock stalled_after_s;
    ping_until client (fun () -> Server_h2_stream_registry.active_streams streams = 0);
    check bool "the client got RST_STREAM(INTERNAL_ERROR)" true
      (reset_with_internal_error reset);
    check bool "the frame did not end whole" true
      (read_to_end (Eio.Promise.await response_body) (Buffer.create 16) = Error ());
    check int "the reservation went back to the ledger" 0
      (Masc.Http_h2_response_ledger.pending_bytes resources);
    check int "one stall line names the stream's request" 1 (logged (stall_line_of "/logs"));
    check int "the SSE response logged no stall of its own" 0
      (logged (sse_stall_line_of "/logs")))

(* A log stream whose client resets the stream while the loop waits for the
   ring and for its keepalive time. The loop ends with the stream: [sw],
   which the loop runs in, ends. Nothing moves the clock, so a loop that
   outlived the stream would hold [sw] until the harness gives up. *)
let test_reset_log_stream_ends_its_loop () =
  let clock = Eio_mock.Clock.make () in
  let streams = registry ~clock () in
  let loop, loop_clock = loop_clock_of clock in
  let outside, set_outside = Eio.Promise.create () in
  with_log_capture @@ fun _ ->
  with_connection ~streams ~resources:(stalled_ledger ()) Request_fibers
    (log_stream_handler ~clock:loop_clock ~outside)
    (fun ~env:_ ~client ~client_flow ~release:_ ~close_client:_ ~server:_ ->
    Eio.Switch.run (fun sw ->
      Eio.Promise.resolve set_outside sw;
      let status, _, response_body = open_stream client "/logs" in
      check int "the response started" 200 (Eio.Promise.await status);
      let received = Buffer.create 256 in
      collect (Eio.Promise.await response_body) received;
      ping_until client (fun () -> Buffer.length received > 0 && loop.Loop_clock.sleeps > 0);
      Eio.Flow.copy_string (rst_stream_frame 1) client_flow;
      ping_until client (fun () -> Server_h2_stream_registry.active_streams streams = 0)))

(* RFC-0518 D7. A response serves its producer in [outside], a switch that
   outlives the HTTP/2 stream, as the router's switch does. [produce] gets
   the response, and [released] counts the runs of the producer's cleanup. *)
let served_handler ~clock ~outside ~released ~produce ~stream_end _ h2_reqd =
  let sse =
    Server_sse_response.respond ~clock ~stalled_after_s (reqd_of_h2 ~stream_end h2_reqd)
      (Httpun.Response.create `OK) in
  Server_sse_response.serve ~sw:(Eio.Promise.await outside) sse
    ~release:(fun () -> incr released)
    (fun () -> produce sse)

let served_frame = "data: served\n\n"

let send_served sse =
  match Server_sse_response.send sse served_frame with
  | Server_sse_response.Written -> ()
  | Server_sse_response.Closed | Server_sse_response.Stalled ->
    fail "the served frame was not written"

(* A producer that waits for an event that never comes. The client resets
   the stream: the wait is cancelled and the cleanup runs, on a clock that
   never moves. *)
let test_reset_stream_ends_its_producer () =
  let clock = Eio_mock.Clock.make () in
  let streams = registry ~clock () in
  let released = ref 0 in
  let outside, set_outside = Eio.Promise.create () in
  let waiting, wait = Eio.Promise.create () in
  let produce sse =
    send_served sse;
    Eio.Promise.resolve wait ();
    Eio.Fiber.await_cancel () in
  with_connection ~streams Request_fibers (served_handler ~clock ~outside ~released ~produce)
    (fun ~env:_ ~client ~client_flow ~release:_ ~close_client:_ ~server:_ ->
    Eio.Switch.run (fun sw ->
      Eio.Promise.resolve set_outside sw;
      let status, _, _ = open_stream client "/served" in
      check int "the response started" 200 (Eio.Promise.await status);
      Eio.Promise.await waiting;
      check int "a waiting producer keeps what it holds" 0 !released;
      Eio.Flow.copy_string (rst_stream_frame 1) client_flow;
      ping_until client (fun () -> !released > 0));
    check int "the cleanup ran once" 1 !released;
    check int "the stream left no scope behind" 0
      (Server_h2_stream_registry.active_streams streams))

(* A producer that returns: its response ends whole, and the cleanup runs. *)
let test_returning_producer_ends_its_response_whole () =
  let clock = Eio_mock.Clock.make () in
  let released = ref 0 in
  let outside, set_outside = Eio.Promise.create () in
  with_connection ~streams:(registry ~clock ()) Request_fibers
    (served_handler ~clock ~outside ~released ~produce:send_served)
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    Eio.Switch.run (fun sw ->
      Eio.Promise.resolve set_outside sw;
      let status, _, read_all = open_unread client "/served" in
      check int "the response started" 200 (Eio.Promise.await status);
      check bool "the client got the whole response" true (read_all () = Ok served_frame);
      ping_until client (fun () -> !released > 0));
    check int "the cleanup ran once" 1 !released)

(* A producer that raises after a frame went out. Its response is cut, not
   closed: the client gets RST_STREAM(INTERNAL_ERROR) where a finished
   response has END_STREAM. The failure is logged once, the cleanup runs,
   and [sw], which the producer ran in, ends without the failure. *)
let test_raising_producer_cuts_its_response () =
  let failure = "fixture producer failure" in
  let clock = Eio_mock.Clock.make () in
  let released = ref 0 in
  let outside, set_outside = Eio.Promise.create () in
  let produce sse =
    send_served sse;
    failwith failure in
  with_log_capture @@ fun logged ->
  with_connection ~streams:(registry ~clock ()) Request_fibers
    (served_handler ~clock ~outside ~released ~produce)
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    Eio.Switch.run (fun sw ->
      Eio.Promise.resolve set_outside sw;
      let status, reset, response_body = open_stream client "/served" in
      check int "the response started" 200 (Eio.Promise.await status);
      check bool "the client got RST_STREAM(INTERNAL_ERROR)" true
        (reset_with_internal_error reset);
      check bool "the response did not end whole" true
        (read_to_end (Eio.Promise.await response_body) (Buffer.create 16) = Error ());
      ping_until client (fun () -> !released > 0));
    check int "the cleanup ran once" 1 !released;
    check int "the failure is logged once" 1 (logged failure))

(* A switch that is already ending runs no fiber. The response is closed and
   the cleanup runs all the same; the producer does not run. *)
let test_ending_switch_runs_no_producer () =
  let clock = Eio_mock.Clock.make () in
  let released = ref 0 and produced = ref false in
  let handler ~stream_end _ h2_reqd =
    let sse =
      Server_sse_response.respond ~clock ~stalled_after_s (reqd_of_h2 ~stream_end h2_reqd)
        (Httpun.Response.create `OK) in
    match
      Eio.Switch.run (fun ending ->
        Eio.Switch.fail ending Exit;
        Server_sse_response.serve ~sw:ending sse
          ~release:(fun () -> incr released)
          (fun () -> produced := true))
    with
    | () -> fail "the switch did not end with its failure"
    | exception Exit -> () in
  with_connection ~streams:(registry ~clock ()) Request_fibers handler
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    let status, _, read_all = open_unread client "/served" in
    check int "the response started" 200 (Eio.Promise.await status);
    check bool "the response ended whole and empty" true (read_all () = Ok "");
    check int "the cleanup ran once" 1 !released;
    check bool "the producer did not run" false !produced)

(* [sw] ends while the producer waits for an event. The producer is
   cancelled, not failed: the response ends whole, where a failed producer's
   is reset, and the cleanup runs once. *)
let test_ending_switch_ends_a_waiting_producer () =
  let clock = Eio_mock.Clock.make () in
  let released = ref 0 in
  let outside, set_outside = Eio.Promise.create () in
  let waiting, wait = Eio.Promise.create () in
  let produce sse =
    send_served sse;
    Eio.Promise.resolve wait ();
    Eio.Fiber.await_cancel () in
  with_connection ~streams:(registry ~clock ()) Request_fibers
    (served_handler ~clock ~outside ~released ~produce)
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    let status, _, read_all = open_unread client "/served" in
    (match
       Eio.Switch.run (fun sw ->
         Eio.Promise.resolve set_outside sw;
         check int "the response started" 200 (Eio.Promise.await status);
         Eio.Promise.await waiting;
         check int "a waiting producer keeps what it holds" 0 !released;
         Eio.Switch.fail sw Exit)
     with
     | () -> fail "the switch did not end with its failure"
     | exception Exit -> ());
    check int "the cleanup ran once" 1 !released;
    check bool "the response ended whole" true (read_all () = Ok served_frame))

(* A cleanup that raises. The response still ends whole and [sw], which
   lives as long as the server, does not fail. *)
let test_raising_cleanup_stays_off_the_switch () =
  let clock = Eio_mock.Clock.make () in
  let released = ref 0 in
  let outside, set_outside = Eio.Promise.create () in
  let handler ~stream_end _ h2_reqd =
    let sse =
      Server_sse_response.respond ~clock ~stalled_after_s (reqd_of_h2 ~stream_end h2_reqd)
        (Httpun.Response.create `OK) in
    Server_sse_response.serve ~sw:(Eio.Promise.await outside) sse
      ~release:(fun () ->
        incr released;
        failwith "fixture cleanup failure")
      (fun () -> send_served sse) in
  with_connection ~streams:(registry ~clock ()) Request_fibers handler
    (fun ~env:_ ~client ~client_flow:_ ~release:_ ~close_client:_ ~server:_ ->
    Eio.Switch.run (fun sw ->
      Eio.Promise.resolve set_outside sw;
      let status, _, read_all = open_unread client "/served" in
      check int "the response started" 200 (Eio.Promise.await status);
      check bool "the client got the whole response" true (read_all () = Ok served_frame);
      ping_until client (fun () -> !released > 0));
    check int "the cleanup ran once" 1 !released)

let () = run "H2 request fibers" ["connection progress", [
  test_case "direct reader reproduces occupied CPU stall" `Quick test_reader_control;
  test_case "GET preserves PING and WINDOW_UPDATE" `Quick (fun () -> test_multiplexed_progress `GET);
  test_case "POST completion preserves PING and WINDOW_UPDATE" `Quick (fun () -> test_multiplexed_progress `POST);
  test_case "RST_STREAM isolates delayed response" `Quick test_reset_does_not_break_siblings;
  test_case "RST_STREAM releases stream scopes and fibers" `Quick test_reset_releases_stream_scopes;
  test_case "RST_STREAM h2 writes ends the stream scope" `Quick test_reset_sent_ends_stream_scope;
  test_case "failure after headers releases the stream" `Quick test_failure_after_headers_releases_the_stream;
  test_case "disconnect cancels requests and child fibers" `Quick test_connection_closes_pending_work;
  test_case "handler failure stays on its stream" `Quick test_handler_error_is_stream_local;
  test_case "a zero-window client gets the response headers" `Quick
    test_zero_window_client_gets_the_headers;
]; "flush bound", [
  test_case "an unanswered flush resets its stream at the bound" `Quick
    test_stalled_flush_resets_the_stream;
  test_case "a reading client keeps its stream past the bound" `Quick
    test_reading_client_keeps_its_stream;
  test_case "a stalled error answer from the handler ends at the bound" `Quick
    (test_stalled_error_answer_ends `Handler);
  test_case "a stalled error answer from a body callback ends at the bound" `Quick
    (test_stalled_error_answer_ends `Body_callback);
  test_case "a steady reader gets a whole body past the bound" `Quick
    (test_steady_reader_gets_a_long_body `Whole);
  test_case "a steady reader gets a streamed body past the bound" `Quick
    (test_steady_reader_gets_a_long_body `Streamed);
  test_case "an idle reader of a long body is cut at the bound" `Quick
    test_idle_reader_of_a_long_body_is_cut;
  test_case "an idle reader of a short body is cut at the bound" `Quick
    test_idle_reader_of_a_short_body_is_cut;
  test_case "later flushes do not extend the bound" `Quick
    test_later_flushes_do_not_extend_the_bound;
  test_case "every flush waiting in h2 is answered when the stream ends" `Quick
    (test_every_waiting_flush_is_answered `In_h2);
  test_case "every flush waiting behind payload is answered when the stream ends" `Quick
    (test_every_waiting_flush_is_answered `Behind_payload);
  test_case "two producers on one body do not interleave" `Quick
    test_two_producers_do_not_interleave;
  test_case "a steady reader on a slow socket gets a whole body" `Quick
    test_steady_reader_on_a_slow_socket_gets_a_long_body;
  test_case "after close a write is dropped and a flush is closed" `Quick
    test_write_after_close_is_dropped;
  test_case "a flush waits for the bytes written before it" `Quick
    test_flush_waits_for_the_bytes_before_it;
  test_case "an answer that raises ends its stream only" `Quick
    test_raising_answer_ends_its_stream_only;
  test_case "a frame crosses the end of a slice" `Quick
    test_a_frame_crosses_the_end_of_a_slice;
  test_case "a short response does not wait for a long one" `Quick
    test_a_short_response_does_not_wait_for_a_long_one;
  test_case "a steady reader gets a long SSE frame past the bound" `Quick
    test_steady_reader_gets_a_long_sse_frame;
  test_case "an idle reader of a long SSE frame is cut, its send cancelled" `Quick
    (test_idle_reader_of_a_long_sse_frame_is_cut On_stream);
  test_case "an idle reader of a long SSE frame is cut, a send elsewhere closed" `Quick
    (test_idle_reader_of_a_long_sse_frame_is_cut Off_stream);
  test_case "a log stream pings past entries its query leaves out" `Quick
    test_log_stream_pings_past_entries_its_query_leaves_out;
  test_case "an unread log stream is reset at the bound" `Quick
    test_unread_log_stream_is_reset_at_the_bound;
  test_case "a log stream pings a ping interval after the clock is set back" `Quick
    test_log_stream_keepalive_after_the_clock_is_set_back;
  test_case "a log stream pings while the ring always holds a newer entry" `Quick
    test_log_stream_pings_while_the_ring_always_holds_a_newer_entry;
]; "producer scope", [
  test_case "a reset stream ends its producer" `Quick test_reset_stream_ends_its_producer;
  test_case "a producer that returns ends its response whole" `Quick
    test_returning_producer_ends_its_response_whole;
  test_case "a producer that raises cuts its response" `Quick
    test_raising_producer_cuts_its_response;
  test_case "a switch that is ending runs no producer" `Quick
    test_ending_switch_runs_no_producer;
  test_case "a switch that ends cancels a waiting producer" `Quick
    test_ending_switch_ends_a_waiting_producer;
  test_case "a cleanup that raises stays off the switch" `Quick
    test_raising_cleanup_stays_off_the_switch;
  test_case "a reset log stream ends its loop" `Quick test_reset_log_stream_ends_its_loop;
]]
