type t =
  { writer : Httpun.Body.Writer.t
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
  { writer = Httpun.Reqd.respond_with_streaming ?flush_headers_immediately reqd response
  ; closed
  ; resolve_closed
  ; stall = (fun () -> Eio.Time.sleep clock stalled_after_s)
  ; stalled_after_s
  ; path = target_path (Httpun.Reqd.request reqd).target
  }
;;

let is_closed t = Httpun.Body.Writer.is_closed t.writer

(* Closing the body answers no waiting flush (httpun body.ml [close]), so
   [closed] is what wakes the sends still waiting. *)
let close t =
  if not (Httpun.Body.Writer.is_closed t.writer) then Httpun.Body.Writer.close t.writer;
  ignore (Eio.Promise.try_resolve t.resolve_closed () : bool)
;;

(* Nothing between the write and the flush registration suspends, so a frame
   from another fiber cannot land inside this one. [flush] answers once the
   bytes written so far were handed to the socket ([`Written]), or once the
   body or the connection writer was drained shut ([`Closed]) (httpun body.ml
   [flush] and [transfer_to_writer]). *)
let send t frame =
  if Httpun.Body.Writer.is_closed t.writer
  then (
    close t;
    Closed)
  else (
    Httpun.Body.Writer.write_string t.writer frame;
    let flushed, resolve = Eio.Promise.create () in
    Httpun.Body.Writer.flush t.writer (Eio.Promise.resolve resolve);
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
               Eio.Promise.await t.closed;
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
