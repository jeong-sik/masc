type worker_entry = Awaiting_worker | Entered_worker | Cancelled_before_entry

(* The raw executor moves work to a pool-owned cancellation context. These
   capabilities belong to one submission, across the caller/worker domains.
   The entry CAS decides whether there is user work whose cleanup to join.
   [name] labels the job in [Pool_wait] and, as an Eio trace span, in the
   runtime-events trace of the worker that runs it (RFC-0474 L4c). *)
let submit pool ~weight ~name f =
  let lane = Pool_lane.current () in
  let in_flight = Pool_wait.in_flight lane in
  let submitted = Mtime_clock.counter () in
  let entry = Atomic.make Awaiting_worker in
  let cancelled,cancel_worker = Eio.Promise.create () in
  let settled,settle_worker = Eio.Promise.create () in
  let await_cancellation () =
    let error,backtrace = Eio.Promise.await cancelled in
    Printexc.raise_with_backtrace error backtrace
  in
  let invoke () =
    Fun.protect ~finally:(fun () -> Eio.Promise.resolve settle_worker ()) (fun () ->
      if Atomic.compare_and_set entry Awaiting_worker Entered_worker then begin
        Pool_wait.record_wait lane ~name ~in_flight (Mtime_clock.count submitted);
        Pool_wait.enter lane ~weight;
        let entered = Mtime_clock.counter () in
        Fun.protect ~finally:(fun () ->
          Pool_wait.leave lane ~weight;
          Pool_wait.record_run lane ~name ~weight (Mtime_clock.count entered))
          (fun () ->
            match Eio.Promise.peek cancelled with
            | Some (error,backtrace) -> Printexc.raise_with_backtrace error backtrace
            | None ->
              Eio.Private.Trace.with_span name (fun () ->
                Eio.Fiber.first await_cancellation f))
      end
      else await_cancellation ())
  in
  match Eio.Executor_pool.submit_exn pool ~weight invoke with
  | value -> value
  | exception (Eio.Cancel.Cancelled _ as error) ->
    let backtrace = Printexc.get_raw_backtrace () in
    Eio.Promise.resolve cancel_worker (error,backtrace);
    if Atomic.compare_and_set entry Awaiting_worker Cancelled_before_entry
    then Pool_wait.record_abandoned lane ~name (Mtime_clock.count submitted)
    else Eio.Cancel.protect (fun () -> Eio.Promise.await settled);
    Printexc.raise_with_backtrace error backtrace
