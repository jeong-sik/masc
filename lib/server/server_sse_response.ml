(* What a response that times its own frames needs: the wait, and what its
   stall line names. *)
type own_timer =
  { stall : unit -> unit
  ; stalled_after_s : float
  ; path : string
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
  { writer : Http_reqd.Body_writer.t
  ; closed : unit Eio.Promise.t
  ; resolve_closed : unit Eio.Promise.u
  ; stall_bound : stall_bound
  }

type outcome =
  | Written
  | Closed
  | Stalled

let target_path target =
  match String.index_opt target '?' with
  | Some idx -> String.sub target 0 idx
  | None -> target

let respond ~clock ~stalled_after_s ?flush_headers_immediately reqd response =
  let closed, resolve_closed = Eio.Promise.create () in
  let writer = Http_reqd.respond_with_streaming ?flush_headers_immediately reqd response in
  (* A writer with a stream end is an HTTP/2 stream's, and every flush of
     such a writer waits under that stream's bound (Http_reqd.of_h2). *)
  let stall_bound =
    match Http_reqd.Body_writer.stream_end writer with
    | Some _ -> Stream_flush_bound
    | None ->
      Own_timer
        { stall = (fun () -> Eio.Time.sleep clock stalled_after_s)
        ; stalled_after_s
        ; path = target_path (Http_reqd.request reqd).target
        }
  in
  { writer; closed; resolve_closed; stall_bound }
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
      | Own_timer { stall; stalled_after_s; path } ->
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
             path
             stalled_after_s);
        outcome
    in
    (match outcome with
     | Written -> ()
     | Closed | Stalled -> close t);
    outcome)
;;
