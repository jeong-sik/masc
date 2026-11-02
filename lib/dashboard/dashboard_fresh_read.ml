type 'a outcome =
  | Published of 'a
  | Failed of exn * Printexc.raw_backtrace
  | Released

type registration = Queued | Registered | Abandoned

type 'a batch = {
  mutable waiters : int;
  mutable finished : bool;
  mutable empty_signalled : bool;
  mutable registration : registration;
  result : 'a outcome Eio.Promise.t;
  resolve : 'a outcome Eio.Promise.u;
  empty : unit Eio.Promise.t;
  signal_empty : unit Eio.Promise.u;
}

type 'a t = { lock : Stdlib.Mutex.t; pending : (string, 'a batch) Hashtbl.t }

let create () = { lock = Stdlib.Mutex.create (); pending = Hashtbl.create 4 }

let run gate ~key work =
  (* Without a server-owned switch there is no safe place to keep a shared
     producer alive after its first caller leaves. Keep those callers separate. *)
  match Eio_guard.execution_context (), Eio_context.get_root_switch_opt () with
  | Eio_guard.Non_eio, _ | Eio_guard.Eio_fiber, None -> Pool_work.submit work
  | Eio_guard.Eio_fiber, Some root ->
    let remove_pending batch =
      match Hashtbl.find_opt gate.pending key with
      | Some current when current == batch -> Hashtbl.remove gate.pending key
      | Some _ | None -> () in
    let finish batch outcome =
      let publish = Stdlib.Mutex.protect gate.lock (fun () ->
        if batch.finished then false
        else begin
          batch.finished <- true;
          remove_pending batch;
          true
        end) in
      if publish then Eio.Promise.resolve batch.resolve outcome in
    let rec read () =
      let batch, start = Stdlib.Mutex.protect gate.lock (fun () ->
        match Hashtbl.find_opt gate.pending key with
        | Some batch -> batch.waiters <- batch.waiters + 1; batch, false
        | None ->
          let result, resolve = Eio.Promise.create () in
          let empty, signal_empty = Eio.Promise.create () in
          let batch = { waiters = 1; finished = false; empty_signalled = false;
                        registration = Queued; result; resolve; empty; signal_empty } in
          Hashtbl.add gate.pending key batch;
          batch, true) in
      let release () =
        let signal = Stdlib.Mutex.protect gate.lock (fun () ->
          batch.waiters <- batch.waiters - 1;
          if batch.waiters = 0 && not batch.finished && not batch.empty_signalled then begin
            batch.empty_signalled <- true;
            remove_pending batch;
            true
          end else false) in
        if signal then Eio.Promise.resolve batch.signal_empty () in
      let register () =
        let register_on_owner () =
          let claim = Stdlib.Mutex.protect gate.lock (fun () ->
            match batch.registration with
            | Queued when not batch.finished && batch.waiters > 0 ->
              batch.registration <- Registered;
              `Start
            | Queued when not batch.finished ->
              batch.registration <- Abandoned;
              `Release
            | Queued | Registered | Abandoned -> `Skip) in
          match claim with
          | `Release -> finish batch Released
          | `Skip -> ()
          | `Start ->
            let execute () =
              let wrapped = Pool_work.wrap work (fun body ->
                (* Only requests already admitted at the first read may use it. *)
                Stdlib.Mutex.protect gate.lock (fun () -> remove_pending batch);
                body ()) in
              let outcome =
                try
                  Eio.Fiber.first
                    (fun () -> Eio.Promise.await batch.empty; Released)
                    (fun () -> Published (Pool_lane.with_read (fun () -> Pool_work.submit wrapped)))
                with exn -> (* cancel-guard-ok: server-owned producer reports its terminal result and then ends *)
                  Failed (exn, Printexc.get_raw_backtrace ()) in
              finish batch outcome in
            match Eio_context.get_root_switch_opt () with
            | Some sw when sw == root ->
              (try
                 let entered = ref false in
                 Eio.Fiber.fork_daemon ~sw (fun () -> entered := true; execute (); `Stop_daemon);
                 if not !entered then
                   finish batch (Failed (Failure "fresh read server switch closed", Printexc.get_callstack 10))
               with exn -> (* cancel-guard-ok: registration reports failure to its waiters *)
                 finish batch (Failed (exn, Printexc.get_raw_backtrace ())))
            | Some _ | None ->
              finish batch (Failed (Failure "fresh read server switch changed", Printexc.get_callstack 10)) in
        match Eio_context.run_on_owner_domain register_on_owner with
        | () -> ()
        | exception exn ->
          let backtrace = Printexc.get_raw_backtrace () in
          let abandon = Stdlib.Mutex.protect gate.lock (fun () ->
            match batch.registration with
            | Queued -> batch.registration <- Abandoned; true
            | Registered | Abandoned -> false) in
          if abandon then finish batch Released;
          Printexc.raise_with_backtrace exn backtrace in
      let outcome = Fun.protect ~finally:release (fun () ->
        if start then register ();
        Eio.Promise.await batch.result) in
      match outcome with
      | Published value -> value
      | Failed (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace
      | Released -> read () in
    read ()
