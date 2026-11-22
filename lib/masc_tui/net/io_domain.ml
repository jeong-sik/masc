exception Closed

type queued_job = {
  run : unit -> unit;
  on_close : unit -> unit;
}

type t = {
  jobs : queued_job Eio.Stream.t;
  closed : bool Atomic.t;
}

(* Unbounded command queue: callers are bounded UI/hub fibers, so adding a job
   from the UI domain never blocks a render pass. *)
let unbounded = max_int

let rec drain_closed t =
  match Eio.Stream.take_nonblocking t.jobs with
  | None -> ()
  | Some job ->
      job.on_close ();
      drain_closed t

let close_and_drain t =
  Atomic.set t.closed true;
  drain_closed t

let enqueue t job =
  if Atomic.get t.closed then job.on_close ()
  else begin
    Eio.Stream.add t.jobs job;
    (* Close race fence: if [close_and_drain] ran concurrently with [add],
       drain again so the newly enqueued job cannot be stranded. *)
    if Atomic.get t.closed then drain_closed t
  end

let start ~sw ~env =
  Eio.Switch.check sw;
  let t = { jobs = Eio.Stream.create unbounded; closed = Atomic.make false } in
  Eio.Switch.on_release sw (fun () -> close_and_drain t);
  let domain_mgr =
    Domains.domain_mgr_for Domains.Io (Eio.Stdenv.domain_mgr env)
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Domain_manager.run domain_mgr (fun () ->
          Eio.Switch.run (fun io_sw ->
              Eio.Switch.on_release io_sw (fun () -> close_and_drain t);
              Masc_http_client.with_scoped_pool ~sw:io_sw ~env (fun () ->
                  Eio.Switch.run (fun job_sw ->
                      Eio.Switch.on_release job_sw (fun () -> close_and_drain t);
                      while not (Atomic.get t.closed) do
                        let job = Eio.Stream.take t.jobs in
                        if Atomic.get t.closed then job.on_close ()
                        else Eio.Fiber.fork ~sw:job_sw job.run
                      done;
                      `Stop_daemon)))));
  t

type 'a outcome = ('a, exn * Printexc.raw_backtrace) result

let run t work =
  Eio.Fiber.check ();
  if Atomic.get t.closed then raise Closed;
  let (reply : _ outcome Eio.Promise.t), set_reply = Eio.Promise.create () in
  let abandoned, abandon = Eio.Promise.create () in
  let fail_closed () =
    ignore
      (Eio.Promise.try_resolve set_reply
         (Error (Closed, Printexc.get_callstack 0))
       : bool)
  in
  let job_run () =
    if Eio.Promise.is_resolved abandoned then ()
    else
      match
        Eio.Fiber.first
          (fun () ->
            let outcome =
              match work () with
              | value -> Ok value
              | exception (Eio.Cancel.Cancelled _ as cancelled) ->
                  raise cancelled
              | exception failure ->
                  Error (failure, Printexc.get_raw_backtrace ())
            in
            ignore (Eio.Promise.try_resolve set_reply outcome : bool))
          (fun () -> Eio.Promise.await abandoned)
      with
      | () -> ()
      | exception (Eio.Cancel.Cancelled _ as cancelled) ->
          fail_closed ();
          raise cancelled
  in
  enqueue t { run = job_run; on_close = fail_closed };
  match Eio.Promise.await reply with
  | Ok value -> value
  | Error (failure, backtrace) ->
      Printexc.raise_with_backtrace failure backtrace
  | exception (Eio.Cancel.Cancelled _ as cancelled) ->
      ignore (Eio.Promise.try_resolve abandon () : bool);
      raise cancelled

type stream_handle = {
  abandon : unit Eio.Promise.u;
  stopped : unit Eio.Promise.t;
}

let spawn_stream ?on_error t fn =
  let abandoned, abandon = Eio.Promise.create () in
  let stopped, set_stopped = Eio.Promise.create () in
  let mark_stopped () = ignore (Eio.Promise.try_resolve set_stopped () : bool) in
  let job_run () =
    if Eio.Promise.is_resolved abandoned then mark_stopped ()
    else
      match
        Eio.Switch.run (fun stream_sw ->
            Eio.Switch.on_release stream_sw mark_stopped;
            Eio.Fiber.first
              (fun () -> fn ~sw:stream_sw)
              (fun () -> Eio.Promise.await abandoned))
      with
      | () -> mark_stopped ()
      | exception (Eio.Cancel.Cancelled _ as cancelled) ->
          mark_stopped ();
          raise cancelled
      | exception ex ->
          (* Isolate non-cancellation exceptions to this stream fiber so
             [job_sw] and all sibling streams/requests continue undisturbed. *)
          mark_stopped ();
          Option.iter (fun cb -> cb ex) on_error
  in
  enqueue t { run = job_run; on_close = mark_stopped };
  { abandon; stopped }

let cancel_stream handle =
  ignore (Eio.Promise.try_resolve handle.abandon () : bool)

let await_stream_stopped handle = Eio.Promise.await handle.stopped

let is_stream_stopped handle = Eio.Promise.is_resolved handle.stopped
