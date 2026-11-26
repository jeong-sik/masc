(* What a response that times its own frames needs: the wait, and the bound
   its stall line names. *)
type own_timer =
  { stall : unit -> unit
  ; stalled_after_s : float
  }

(* What ends a frame the client does not take. On HTTP/2 the stream's flush
   bound resets a stream whose oldest flush waits too long
   (Http_h2_stream.Stream_end), and the reset ends the response under
   [send]. That bound counts each 16 KiB slice of a frame, so a client that
   drains a long frame steadily keeps its stream. A timer here would race the
   reset with the same bound and also cut that client once the whole frame
   took longer. HTTP/1.1 has no bound under the response, so the response
   times its frames itself. *)
type stall_bound =
  | Stream_flush_bound
  | Own_timer of own_timer

type t =
  { reqd : Http_reqd.t
  ; writer : Http_reqd.Body_writer.t
  ; closed : unit Eio.Promise.t
  ; resolve_closed : unit Eio.Promise.u
  ; stall_bound : stall_bound
  ; now : unit -> float
  ; frames_written : int Atomic.t
  ; last_written_at : float Atomic.t
  }

type outcome =
  | Written
  | Closed
  | Stalled

type idle =
  | Keepalive
  | Quiet
  | Finish

let keepalive_frame = ": keepalive\n\n"

(* The request's path without its query, which can carry a token. *)
let path t =
  let target = (Http_reqd.request t.reqd).target in
  match String.index_opt target '?' with
  | Some idx -> String.sub target 0 idx
  | None -> target
;;

let open_response ~clock ~stalled_after_s ?flush_headers_immediately reqd response =
  let closed, resolve_closed = Eio.Promise.create () in
  let writer = Http_reqd.respond_with_streaming ?flush_headers_immediately reqd response in
  (* A writer with a stream end is an HTTP/2 stream's, and every flush of
     such a writer waits under that stream's bound (Http_reqd.of_h2). *)
  let stall_bound =
    match Http_reqd.Body_writer.stream_end writer with
    | Some _ -> Stream_flush_bound
    | None ->
      Own_timer { stall = (fun () -> Eio.Time.sleep clock stalled_after_s); stalled_after_s }
  in
  let now () = Eio.Time.now clock in
  { reqd
  ; writer
  ; closed
  ; resolve_closed
  ; stall_bound
  ; now
  ; frames_written = Atomic.make 0
  ; last_written_at = Atomic.make (now ())
  }
;;

let is_closed t = Http_reqd.Body_writer.is_closed t.writer

(* The transport can end the stream under the response before anything here
   closes it: an h2 peer reset, a stalled flush or connection end. httpun
   reports no such end, so an HTTP/1.1 response closes only through [close]
   or a send that did not end [Written]. *)
let await_closed t =
  match Http_reqd.Body_writer.stream_end t.writer with
  | None -> Eio.Promise.await t.closed
  | Some stream_end ->
    Eio.Fiber.first
      (fun () -> Eio.Promise.await t.closed)
      (fun () -> Eio.Promise.await stream_end)
;;

(* Closing the body answers no waiting flush (httpun body.ml [close]), so
   [closed] is what wakes the sends still waiting. *)
let close t =
  if not (Http_reqd.Body_writer.is_closed t.writer) then Http_reqd.Body_writer.close t.writer;
  ignore (Eio.Promise.try_resolve t.resolve_closed () : bool)
;;

(* A close says the response is complete. A route that fails leaves it
   open, so the request's error handling cuts it (Server_http_ingress). *)
let close_after t f =
  let result = f () in
  close t;
  result
;;

(* Nothing between the write and the flush registration suspends, so a frame
   from another fiber cannot land inside this one. [flush] answers once the
   bytes written so far were handed to the socket ([`Written]), or once the
   body or the connection writer was drained shut ([`Closed]) (httpun body.ml
   [flush] and [transfer_to_writer]). *)
let send t frame =
  if Http_reqd.Body_writer.is_closed t.writer
  then (
    close t;
    Closed)
  else (
    (* The frame counts for the keepalive before its bytes can reach the
       client. The time goes first: a keepalive that sees the new count
       reads this frame's time or a later one. *)
    Atomic.set t.last_written_at (t.now ());
    Atomic.incr t.frames_written;
    Http_reqd.Body_writer.write_string t.writer frame;
    let flushed, resolve = Eio.Promise.create () in
    Http_reqd.Body_writer.flush t.writer (Eio.Promise.resolve resolve);
    let frame_flushed () =
      match Eio.Promise.await flushed with
      | `Written -> Written
      | `Closed -> Closed
    in
    let response_closed () =
      await_closed t;
      Closed
    in
    (* Both ways the response can end without the frame wait on the watcher
       side. A race nested inside the work would raise the outer race's
       cancellation even after the flush answered (eio core fiber.ml
       [any_gen]), and a frame that reached the socket as the time ran out
       would come back [Stalled]. *)
    let outcome =
      match t.stall_bound with
      | Stream_flush_bound -> Watched_work.run ~watcher:response_closed frame_flushed
      | Own_timer { stall; stalled_after_s } ->
        let outcome =
          Watched_work.run
            ~watcher:(fun () ->
              Eio.Fiber.first
                (fun () ->
                   stall ();
                   Stalled)
                response_closed)
            frame_flushed
        in
        (match outcome with
         | Written | Closed -> ()
         | Stalled ->
           Log.Server.warn
             "SSE response for %s closed: a frame did not reach the socket within %.0f seconds"
             (path t)
             stalled_after_s);
        outcome
    in
    (match outcome with
     | Written -> ()
     | Closed | Stalled -> close t);
    outcome)
;;

(* The end of a served response: closed, then the producer's own cleanup.
   On a live switch this is the release hook of a fiber on the server's
   switch, where an exception would fail that switch. Each step is guarded
   by itself: what one raises is logged and the other still runs. A
   cancellation goes on. *)
let end_serving t ~release =
  let guarded step f =
    match f () with
    | () -> ()
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn ->
      Log.Server.warn
        "SSE response for %s: %s failed: %s"
        (path t)
        step
        (Printexc.to_string exn)
  in
  guarded "closing it" (fun () -> close t);
  guarded "the cleanup of its producer" release
;;

(* A producer that raised did not finish its response, and a close would
   tell the client it did. The response is cut the way the request's own
   error handling cuts one whose handler failed
   (Server_http_ingress.handler_failed): [Http_reqd.report_exn] resets the
   HTTP/2 stream or stops the HTTP/1.1 body, and logs the exception. On a
   response that had already ended the report cuts nothing and still logs. *)
let producer_failed t exn = Http_reqd.report_exn t.reqd exn

let keepalive_interval_s = Server_mcp_transport_http_headers.sse_ping_interval_s

(* An HTTP/1.1 response hears that its client left only from a write that is
   not taken (#32910), so a stream that is quiet for long would hold a gone
   client's producer as long. The keepalive is the write that a quiet
   stream lacks.

   It is due once no frame was written for an interval, counted from the
   last frame any fiber handed to [send]. A producer that wakes and writes
   nothing does not put it off, and one that writes often never needs it.
   The count of frames tells a frame written during the sleep from none: a
   wall clock that was set back reads an earlier time after a later frame.
   Each sleep is at most one interval, so a clock set back since the last
   frame delays no keepalive. [Quiet] starts the next interval at the
   answer. *)
let keep_alive t ~sleep ~idle =
  let rec wait ~frames ~from =
    let due_in = from +. keepalive_interval_s -. t.now () in
    sleep (Float.min keepalive_interval_s (Float.max 0.0 due_in));
    let written = Atomic.get t.frames_written in
    if written <> frames
    then wait ~frames:written ~from:(Atomic.get t.last_written_at)
    else (
      match idle () with
      | Keepalive ->
        (match send t keepalive_frame with
         | Written -> after_last_frame ()
         | Closed | Stalled -> ())
      | Quiet -> wait ~frames ~from:(t.now ())
      | Finish -> close t)
  and after_last_frame () =
    let frames = Atomic.get t.frames_written in
    wait ~frames ~from:(Atomic.get t.last_written_at)
  in
  after_last_frame ()
;;

(* The keepalive ends with the response: the race ends it at the close, and
   on HTTP/2 also when the stream ends under the response. An [idle] that
   raises leaves the response cut, as a producer that raises does; the close
   promise wakes the fibers that wait for the end. [sw] is the caller's, so
   nothing raised here may reach it. *)
let respond ~sw ~clock ~stalled_after_s ?flush_headers_immediately ?(idle = fun () -> Keepalive)
    reqd response =
  let t = open_response ~clock ~stalled_after_s ?flush_headers_immediately reqd response in
  (match Eio.Switch.get_error sw with
   | Some (_ : exn) -> ()
   | None ->
     Eio.Fiber.fork_daemon ~sw (fun () ->
       (match
          Eio.Fiber.first
            (fun () -> await_closed t)
            (fun () -> keep_alive t ~sleep:(Eio.Time.sleep clock) ~idle)
        with
        | () -> ()
        | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
        | exception exn ->
          producer_failed t exn;
          ignore (Eio.Promise.try_resolve t.resolve_closed () : bool));
       `Stop_daemon));
  t
;;

(* [Eio.Fiber.fork] runs nothing on a switch that is already off, so the
   response is ended here then. On a live switch the fork runs the fiber at
   once, and its release hook is registered before [sw] can be cancelled:
   a [sw] that is cancelled while the producer runs ends the producer, and
   the hook closes the response and runs the cleanup.
   The hook sits on a switch of the response's own: [sw] lives as long as
   the server and keeps every hook given to it until it ends (eio core
   switch.ml [on_release]). *)
let serve ~sw ?(release = ignore) t produce =
  match Eio.Switch.get_error sw with
  | Some (_ : exn) -> end_serving t ~release
  | None ->
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Switch.run (fun response_sw ->
        Eio.Switch.on_release response_sw (fun () -> end_serving t ~release);
        match Eio.Fiber.first produce (fun () -> await_closed t) with
        | () -> ()
        | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
        | exception exn -> producer_failed t exn))
;;
