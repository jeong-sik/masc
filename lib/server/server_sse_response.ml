type t =
  { writer : Http_reqd.Body_writer.t
  ; closed : unit Eio.Promise.t
  ; resolve_closed : unit Eio.Promise.u
  ; stall : unit -> unit
  ; stalled_after_s : float
  ; path : string
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
  { writer = Http_reqd.respond_with_streaming ?flush_headers_immediately reqd response
  ; closed
  ; resolve_closed
  ; stall = (fun () -> Eio.Time.sleep clock stalled_after_s)
  ; stalled_after_s
  ; path = target_path (Http_reqd.request reqd).target
  }
;;

let is_closed t = Http_reqd.Body_writer.is_closed t.writer

(* The transport can end the stream under the response before anything here
   closes it: an h2 peer reset or connection end. httpun reports no such end,
   so an HTTP/1.1 response closes only through [close] or a send that did not
   end [Written]. *)
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
    (* Both ways the response can end without the frame wait on the watcher
       side. A race nested inside the work would raise the outer race's
       cancellation even after the flush answered (eio core fiber.ml
       [any_gen]), and a frame that reached the socket as the time ran out
       would come back [Stalled]. *)
    let outcome =
      Watched_work.run
        ~watcher:(fun () ->
          Eio.Fiber.first
            (fun () ->
               t.stall ();
               Stalled)
            (fun () ->
               await_closed t;
               Closed))
        (fun () ->
           match Eio.Promise.await flushed with
           | `Written -> Written
           | `Closed -> Closed)
    in
    (match outcome with
     | Written -> ()
     | Closed -> close t
     | Stalled ->
       Log.Server.warn
         "SSE response for %s closed: a frame did not reach the socket within %.0f seconds"
         t.path
         t.stalled_after_s;
       close t);
    outcome)
;;
