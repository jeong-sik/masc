type installation =
  { executor : Eio.Executor_pool.t
  ; stopped : exn Eio.Promise.t
  }

let pool : installation option Atomic.t = Atomic.make None

let install ~sw domain_mgr =
  Eio.Switch.check sw;
  (* This resource is independent of the executor that runs owner-lock
     waiters. The worker count affects encoding throughput, not progress. *)
  let executor = Eio.Executor_pool.create ~sw ~domain_count:1 domain_mgr in
  let stopped, stop = Eio.Promise.create () in
  (* A durable writer can mask caller cancellation while waiting to encode.
     Pool workers stop before switch release hooks run, so waiting until
     [on_release] to signal shutdown would strand that writer in submission. *)
  Eio.Fiber.fork_daemon ~sw (fun () ->
    try Eio.Fiber.await_cancel () with
    | Eio.Cancel.Cancelled _ as exn ->
        Eio.Promise.resolve stop exn;
        raise exn);
  Eio.Switch.check sw;
  let installed = Some { executor; stopped } in
  Eio.Switch.on_release sw (fun () ->
    ignore (Atomic.compare_and_set pool installed None : bool));
  Atomic.set pool installed
;;

let encode_state state =
  let run () =
    Keeper_event_queue_state.to_yojson state
    |> Safe_ops.sanitize_json_utf8 |> Yojson.Safe.pretty_to_string
  in
  match Atomic.get pool, Eio_guard.execution_context () with
  | Some { executor; stopped }, Eio_guard.Eio_fiber ->
      (* This race is local to the caller's domain. The stop promise is safe
         to await from shared-pool workers as well as the server fiber. Its
         cancellation exception cancels even a protected caller's blocked
         submission child; the owner's lock can then unwind. *)
      Eio.Fiber.first
        (fun () ->
          Eio.Executor_pool.submit_exn executor ~weight:1.0 (fun () ->
            Domain_pool.tune_minor_heap ();
            run ()))
        (fun () -> raise (Eio.Promise.await stopped))
  | None, (Eio_guard.Eio_fiber | Eio_guard.Non_eio)
  | Some _, Eio_guard.Non_eio -> run ()
;;
