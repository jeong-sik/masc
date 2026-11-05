type t =
  { writer : Httpun.Body.Writer.t
  ; mutex : Eio.Mutex.t
  ; stall : unit -> unit
  }

type outcome =
  | Written
  | Closed
  | Stalled

let respond ~clock ~stalled_after_s reqd response =
  { writer = Httpun.Reqd.respond_with_streaming reqd response
  ; mutex = Eio.Mutex.create ()
  ; stall = (fun () -> Eio.Time.sleep clock stalled_after_s)
  }
;;

let is_closed t = Httpun.Body.Writer.is_closed t.writer

(* httpun's writer is not domain-safe, so every write, flush registration and
   close takes [mutex]. Nothing waits while holding it. *)
let close t =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    if not (Httpun.Body.Writer.is_closed t.writer)
    then Httpun.Body.Writer.close t.writer)
;;

(* [flush] calls back once the bytes written so far have been handed to the
   socket ([`Written]), or once the connection closed first ([`Closed])
   (httpun body.ml, serialize.ml). *)
let send t frame =
  let flushed, resolve = Eio.Promise.create () in
  let registered =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      if Httpun.Body.Writer.is_closed t.writer
      then false
      else (
        Httpun.Body.Writer.write_string t.writer frame;
        Httpun.Body.Writer.flush t.writer (Eio.Promise.resolve resolve);
        true))
  in
  if not registered
  then Closed
  else (
    let outcome =
      Watched_work.run
        ~watcher:(fun () ->
          t.stall ();
          Stalled)
        (fun () ->
           match Eio.Promise.await flushed with
           | `Written -> Written
           | `Closed -> Closed)
    in
    (match outcome with
     | Stalled -> close t
     | Written | Closed -> ());
    outcome)
;;
